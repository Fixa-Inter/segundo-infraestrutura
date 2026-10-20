# Firebase JSON privado no S3 — como aplicar

Esta versão usa o projeto completo revisado. Não misture o `sync-secrets.py` antigo anexado com estes manifestos: o sincronizador atualizado trabalha junto com `env_config.py`, `firebase_config.py`, os scripts de upload e o Terraform deste pacote.

## 1. Prepare os arquivos locais

Mantenha os quatro `.env` em `env/` e envie a credencial com o nome exato **env/firebase.json**. É o JSON de conta de serviço do Firebase, não o google-services.json do Android. Não coloque a credencial no repositório nem na imagem Docker.

No **env/mobile.env**, mantenha suas variáveis existentes e defina:

```dotenv
FIREBASE_CREDENTIALS_PATH=/app/secrets/firebase.json
```

Remova FIREBASE_CREDENTIALS_JSON. FIREBASE_PROJECT_ID é opcional: o sincronizador o obtém do JSON. Se você o fornecer, precisa corresponder ao project_id do arquivo.

Esse caminho pertence ao contêiner. No CloudShell, o arquivo continua em env/firebase.json. Não coloque URI s3:// ou conteúdo JSON na variável PATH. As demais variáveis DB_*, JWT_SECRET, MAIL_* e REDIS_* permanecem com seus valores reais.

```bash
chmod +x deploy.sh destroy.sh scripts/*.sh
chmod 700 env
chmod 600 env/mobile.env env/firebase.json
./scripts/upload-firebase.sh --check
./scripts/check-env.sh
```

--check faz somente validação local; não chama AWS. A validação é estrutural e não autentica a chave no Google.

## 2. Execute o deploy integrado

Use uma **nova tag**, pois a imagem Mobile mudou para incluir o download do Firebase:

```bash
./deploy.sh firebase-01
```

O comando valida os arquivos, identifica a conta em us-east-1, verifica/aplica o plano Terraform e cria automaticamente um bucket com nome:

```text
fixa-secrets-<ID_DA_CONTA>-us-east-1
```

Depois chama o uploader, compila as imagens, sincroniza os demais segredos no SSM e continua ACM/HTTPS/ECS. O arquivo é enviado para firebase/<SHA256>.json. Reexecutar com o mesmo conteúdo verifica o objeto existente e não faz novo upload. Credencial diferente produz outra chave, mantendo a versão anterior para tasks antigas/rollback.

O bucket tem bloqueio de acesso público, propriedade do dono do bucket, criptografia AES256 e política exigindo HTTPS. A bucket policy permite leitura do prefixo firebase/* pela LabRole usada como Task Role. Não altera a política IAM da LabRole. Restrições explícitas do Learner Lab, permissions boundary ou SCP ainda podem negar operações; a política do bucket não as supera.

O uploader confere conta, nome/dono do bucket, bloqueio público, criptografia e checksum retornado pelo S3. Nenhum valor do JSON é impresso ou enviado ao Terraform/SSM. O SHA256 e a localização do objeto são metadados não secretos utilizados pela task.

**Validação pendente:** execute init/validate no CloudShell antes de aprovar qualquer plano. O executor desta revisão continua apresentando a divergência de checksum do provider registrada em AUDITORIA.md. AWS, Docker e credencial real não foram executados/testados nesta revisão.

## 3. Como o Mobile recebe o arquivo

O build primeiro compila o Dockerfile original da API. Em seguida cria uma camada de runtime a partir de runtime/mobile/Dockerfile, que instala Python/boto3 e o inicializador, usando um contexto de build que contém apenas esses arquivos — nunca env/firebase.json.

O inicializador:

1. Usa automaticamente as credenciais da Task Role do ECS.
2. Baixa o objeto privado usando bucket/key definidos pelo manifesto do upload.
3. Confere SHA256, estrutura da conta de serviço e project_id.
4. Grava /app/secrets/firebase.json com permissão 600, em diretório 700, como usuário sem privilégios.
5. Inicia o Java somente depois do sucesso. Falha de download/validação encerra a task sem imprimir a credencial.

O Java existente já suporta FIREBASE_CREDENTIALS_PATH. Não é necessário mudar FirebaseTokenVerifier. O arquivo local do contêiner é efêmero: cada task nova baixa novamente o objeto. O objeto anterior no S3 não é apagado durante uma atualização.

## 4. Rodar somente o upload

Depois que o bucket tiver sido criado pelo Terraform deste projeto:

```bash
./scripts/upload-firebase.sh
```

O comando escolhe automaticamente a conta/região e escreve apenas o manifesto da localização do Firebase. Ele **não cria o bucket por fora do State, não inicia o Java e não atualiza tasks já rodando**.

Para aplicar uma credencial nova em todo o fluxo:

```bash
./deploy.sh firebase-02
```

Se o certificado já foi emitido e você está retomando uma ativação com imagem já publicada e configurações sincronizadas:

```bash
./scripts/activate-apis.sh firebase-01
```

O manifesto S3 é mesclado nas variáveis da task. Trocar o arquivo muda seu SHA256/key e produz nova revisão da Task Definition no próximo apply.

## 5. Arquivos que mudaram

| Arquivo | Mudança |
|---|---|
| config/backends.json | Mobile exige FIREBASE_CREDENTIALS_PATH; não exige JSON na variável |
| scripts/env_config.py | Valida caminho interno e rejeita JSON/envs S3 definidos manualmente |
| scripts/firebase_config.py | Valida env/firebase.json e correspondência de projeto |
| scripts/sync-secrets.py | Caminho/project_id viram configuração comum; senhas continuam SSM |
| terraform/firebase.tf | Bucket, bloqueio público, criptografia, ownership e política de leitura |
| scripts/upload-firebase.sh / .py | Upload integrado com detecção de conta, checksum e manifesto |
| deploy.sh | Chama upload após criar a infraestrutura e antes de ativar APIs |
| terraform/apis.tf | Injeta bucket/key/owner/checksum nas variáveis Mobile |
| scripts/activation.sh | Preserva configuração comum ao adicionar marcador SSM |
| runtime/mobile/Dockerfile e entrypoint.py | Preparam arquivo privado antes de iniciar Java |
| scripts/build-images.sh | Monta imagem Mobile com runtime; recibo inclui receita da imagem |
| scripts/preflight.py | Bloqueia adoção acidental de bucket existente fora deste State |
| destroy.sh / scripts/cleanup-firebase.py | Exclusão opcional e explícita dos arquivos S3 gerenciados |

O JSON não passa pelo aws_s3_object do Terraform, por isso seu conteúdo não entra no State. O .gitignore já ignora toda a pasta env/, exceto .gitkeep.

## 6. Remover o ambiente de teste

Para apagar também os arquivos Firebase e permitir remover o bucket:

```bash
./destroy.sh --delete-images --delete-secrets --delete-firebase
```

Ainda é necessário revisar o plano e digitar a confirmação da conta. Sem --delete-firebase, se houver arquivos no bucket, o script interrompe antes do destroy. A limpeza alcança somente o bucket gerenciado pelo State e objetos no formato firebase/<SHA256>.json, incluindo versões/deletion markers quando existirem. Arquivos fora desse padrão interrompem a limpeza para revisão.

O env/firebase.json local é preservado. O domínio, DNS e bancos externos permanecem fora da destruição. Armazene a credencial em local privado fora do laboratório para reutilizar em outra conta.

## Permissões necessárias

- Operador de deploy: criar/configurar bucket/policy/public-access-block/ownership/encryption, consultar objetos e fazer PutObject. HeadObject de arquivo ausente pode exigir ListBucket para retornar 404 em vez de 403. Exclusão opcional precisa ListBucketVersions e DeleteObject/DeleteObjectVersion.
- Task Role da API: s3:GetObject no prefixo Firebase; fornecido pela bucket policy criada. Explicit deny ou limites do Lab ainda prevalecem.
- Execution Role: continua precisando ECR, logs e leitura SSM para os outros segredos.

Não coloque AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY no .env para este fluxo. O CloudShell usa a sessão do laboratório e o contêiner usa a Task Role.

Parâmetros SSM de Firebase criados por versões antigas não são apagados automaticamente por esta atualização. Eles deixam de ser referenciados pela task; revise a limpeza dos parâmetros antigos separadamente depois da migração.

Validação local desta entrega: 27 testes passaram, além de sintaxe Bash/Python e formatação Terraform. Os testes S3 são simulados, sem uso de credencial real.
