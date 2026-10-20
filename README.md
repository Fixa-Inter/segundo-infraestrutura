# FIXA — instalador AWS Academy

Infraestrutura Terraform para quatro APIs, ECS Fargate, um ALB, ECR, ACM e SSM em **us-east-1**. DNS permanece na Hostinger. PostgreSQL, Redis, Firebase, MongoDB e Qdrant continuam externos.

**Status:** código revisado e testes locais disponíveis. Nenhum deploy, Docker build ou chamada autenticada à Hostinger foi executado durante a revisão. Faça o primeiro teste integrado em uma conta nova, sem a infraestrutura antiga. Veja `AUDITORIA.md` para evidências, contratos dos backends e pendências.

## Firebase em arquivo (atualização)

O Mobile agora usa **env/firebase.json → S3 privado → /app/secrets/firebase.json**. Configure FIREBASE_CREDENTIALS_PATH com esse caminho e remova FIREBASE_CREDENTIALS_JSON. O deploy cria o bucket e envia o arquivo automaticamente; a imagem Mobile baixa e valida a credencial antes do Java. Siga [FIREBASE.md](FIREBASE.md) para os comandos completos e a lista de arquivos alterados.

## Preparação

No CloudShell com credenciais ativas do Learner Lab, instale Git, AWS CLI, Docker, Python 3.10+, curl, flock e Terraform **1.10.5**. O AWS provider está fixado em **6.0.0**, com lock file. `scripts/setup.sh` instala o Terraform via tfenv; ele precisa de acesso ao GitHub e aos downloads HashiCorp. Docker deve estar funcionando. Não são necessárias bibliotecas Python externas.

```bash
bash scripts/setup.sh
chmod +x deploy.sh destroy.sh scripts/*.sh
mkdir -p env
chmod 700 env
```

Envie privadamente os quatro arquivos para `env/mobile.env`, `env/web.env`, `env/nosql.env` e `env/ia.env`, além da conta de serviço `env/firebase.json`. Não cadastre segredos no Console e não cole seus valores em chats, issues ou comandos. Arquivos devem estar em UTF-8. Nunca execute `source env/*.env`.

Para integração opcional com DNS, envie um arquivo privado `env/hostinger.token` contendo apenas o token da sua conta Hostinger. Sem esse arquivo, o deploy informa os CNAMEs do ACM para configuração manual. O token não é enviado ao SSM nem ao Terraform.

```bash
./scripts/check-env.sh
./deploy.sh entrega-01
```

Use uma nova versão para cada atualização, por exemplo `entrega-02`. Imagens usam tags imutáveis. O build atualiza os repositórios na branch main, exige árvore limpa e não descarta alterações locais. Uma tag já publicada só é reutilizada se o comprovante local em `.states/` corresponder ao commit e digest atuais. Sem esse comprovante, ou com outro commit, o comando pede uma nova versão. **A tag não é sobrescrita.** Para retomar a mesma implantação, use a mesma tag; para incorporar novos commits, sempre use outra tag. O Terraform resolve a tag para digest SHA256.

## Contratos de configuração

Os nomes e aliases ficam em `config/backends.json`, baseados nos fontes consultados. A validação rejeita variáveis obrigatórias vazias, duplicatas, expansões shell, URLs locais, portas incompatíveis e valores maiores que 4096 bytes UTF-8. URLs são verificadas sintaticamente; isso não comprova que os serviços externos estão acessíveis.

- **Mobile:** DB_URL, DB_USERNAME, DB_PASSWORD, REDIS_HOST, REDIS_PASSWORD, JWT_SECRET, MAIL_HOST, MAIL_USERNAME, MAIL_PASSWORD e FIREBASE_CREDENTIALS_PATH=/app/secrets/firebase.json. O arquivo env/firebase.json é enviado ao S3 e baixado pelo inicializador da imagem. FIREBASE_PROJECT_ID é derivado/verificado com o arquivo.
- **NoSQL:** DB_URL, DB_USERNAME, DB_PASSWORD, REDIS_HOST, REDIS_PASSWORD, JWT_SECRET e MONGODB_URI.
- **Web:** SPRING_DATASOURCE_*, SPRING_DATA_REDIS_*, SPRING_MAIL_* e SECURITY_JWT_SECRET/SECURITY_JWT_EXPIRATIONSECONDS. Os aliases DB_*, REDIS_*, MAIL_* e JWT_SECRET são traduzidos explicitamente. JWT_SECRET da Web deve estar em Base64 e conter ao menos 32 bytes após decodificação. O contrato exige Redis/SMTP para os fluxos de recuperação de senha; ajuste deliberadamente se esses fluxos forem desativados no código.
- **IA:** GEMINI_API_KEY, GROQ_API_KEY, OPENAI_API_KEY, DATABASE_URL_SOLICITANTE, DATABASE_URL_TECNICO, DATABASE_URL_GESTOR, **MONGO_URI**, QDRANT_API_KEY, QDRANT_URL e FIXA_API_BASE_URL. O código lê MONGO_URI, embora uma mensagem interna o chame MONGODB_URI. FIXA_API_BASE_URL usa HTTPS e deve apontar para o backend correto para os endpoints consumidos.

Variáveis opcionais vazias são omitidas porque o SSM não aceita valor vazio. As configurações que restarem são tratadas como SecureString, exceto o caminho local/project_id do Firebase. O conteúdo do arquivo Firebase é tratado separadamente no S3. Não há classificação por substring nem valores de `.env` enviados ao State. Um `FIXA_CONFIG_REVISION` não secreto força nova task quando uma versão SSM muda. Isso também reinicia tasks se os ARNs permanecerem iguais.

Formatos aceitos: `CHAVE=valor`, `export CHAVE=valor`, aspas simples ou duplas, comentários, JSON multilinha sem aspas externas ou dentro de aspas simples. Aspas duplas interpretam escapes \n, \r, \t, \" e \\. Para JSON de credenciais, prefira aspas simples externas para preservar os escapes do JSON. Não há expansão de `$VAR`, `${VAR}` nem comandos shell. JSON acima de 4096 bytes é compactado quando possível; se continuar grande, a sincronização interrompe sem contratar tier pago. Não existe divisão automática de credenciais em vários parâmetros.

## Fases e retomada

1. Validação dos quatro `.env`, ferramentas e Docker.
2. Identificação STS e State local separado em `.states/<conta>/us-east-1/`.
3. Verificação de conflitos e rotas das subnets; criação da base e ECR.
4. Upload de env/firebase.json ao bucket privado; checkout dos quatro repositórios, builds linux/amd64 e publicação. Mobile recebe uma camada de inicialização para baixar o arquivo do S3.
5. Sincronização SSM e manifestos de ARNs por conta/região.
6. ACM: com token, plano e confirmação dos registros de validação; espera até cinco minutos. Sem token ou com propagação pendente, encerra com código 2 e instruções para retomar.
7. Após ACM ISSUED, habilita HTTPS e as quatro APIs em um plano revisável.
8. Aguarda deployments solicitados, targets saudáveis e HTTP 200 sobre TLS no ALB novo usando curl --connect-to. Não usa `-k` nem altera DNS para testar.

```bash
# Retomar apenas a ativação depois de emitir o certificado:
./scripts/activate-apis.sh entrega-01
# Revalidar os serviços e o novo ALB:
./scripts/check-deployment.sh
```

Cada plano pede confirmação antes de aplicar. O deploy recusa exclusões/substituições de infraestrutura; a substituição normal de revisão de Task Definition é permitida. Uma reexecução conserva a fase ativa no runtime.tfvars.json da conta, em vez de voltar enabled_apis para vazio. O lock local evita deploy/destroy concorrentes pelo instalador; execute comandos de sincronização avulsos somente sem outro deploy em andamento.

## Migração DNS Hostinger

A validação ACM e a migração do tráfego são comandos distintos. A integração usa a API oficial GET/PUT `/api/dns/v1/zones/fixa.solutions`. Conforme o schema oficial, `overwrite=true` substitui os pares nome/tipo enviados; a requisição contém apenas os registros selecionados. Outros registros não são enviados para substituição. Conflitos com A/AAAA/ALIAS ou outro tipo interrompem a automação para revisão, sem apagá-los.

```bash
# Consultar e mostrar o plano dos CNAMEs ACM:
./scripts/hostinger-dns.sh validation
# Revisar e aplicar somente validação ACM:
./scripts/hostinger-dns.sh validation --apply
# Testar as APIs no ALB novo e mostrar plano de tráfego:
./scripts/hostinger-dns.sh traffic
# Testar novamente, revisar e confirmar a migração:
./scripts/hostinger-dns.sh traffic --apply
```

A escrita exige confirmação específica, reconsulta a zona para detectar mudanças concorrentes e grava backup privado antes do PUT. Depois confere os destinos e se os demais registros permaneceram iguais. O DNS de tráfego **não é atualizado automaticamente pelo deploy**. Isso mantém a mudança para o ambiente novo como etapa explícita após a verificação. Propagação pública e caches DNS podem atrasar a migração. A integração foi testada com dados simulados; acesso real da conta à API permanece pendente.

## Diagnóstico

- Certificado PENDING_VALIDATION: confirme nameservers autoritativos na Hostinger e CNAMEs apresentados; aguarde propagação e retome ativação.
- ResourceInitializationError/AccessDenied no ECS: a **execution role** LabRole precisa de `ssm:GetParameters`, além de ECR e CloudWatch Logs. Para chave KMS própria, também `kms:Decrypt`. O instalador não altera políticas/trust da LabRole. A concessão efetiva precisa ser validada no Learner Lab.
- API Web não inicia: confira aliases do Spring, JWT Base64 e tempo de expiração. DB_URL isolado não configura datasource no application.properties atual.
- IA não inicia: confira MONGO_URI, Qdrant e acesso às dependências usadas na inicialização. `health` não prova todos os fluxos de negócio/modelos.
- Target unhealthy: consulte ECS → Service → Events e logs `/ecs/fixa-<api>-api`. O verificador não despeja logs da aplicação automaticamente, pois eles podem conter credenciais.
- Conflito com recursos antigos: não faça imports nem apague o State. Use uma conta nova ou recupere o State correto e planeje a migração separadamente.
- Terraform detecta exclusão: deploy interrompido. Revise drift/configuração; nunca remova a proteção apenas para forçar o apply.

```bash
aws ecs describe-services --region us-east-1 --cluster cluster-fixa \
  --services fixa-mobile-api-service fixa-web-api-service fixa-nosql-api-service fixa-ia-api-service
```

O nome com sufixo `fixa-mobile-api-service-3t7sc4xo` pertence ao ambiente antigo; este projeto não o importa automaticamente.

## Destruição e economia

```bash
./destroy.sh
# Autorizar explicitamente apagar também imagens dos ECRs gerenciados:
./destroy.sh --delete-images
# Autorizar também os parâmetros registrados nos manifestos desta conta:
./destroy.sh --delete-images --delete-secrets --delete-firebase
```

O comando mostra o plano e exige DESTRUIR-<ID_DA_CONTA>. ECR permanece com force_delete=false; --delete-images esvazia somente os repositórios do State após a confirmação. Sem a opção, repositórios não vazios impedem a conclusão do destroy. A limpeza SSM alcança apenas parâmetros nos manifestos locais; versões antigas removidas dos manifestos não são localizadas automaticamente. Não existe opção --legacy. Para remover o bucket com arquivos, --delete-firebase também é obrigatório: a limpeza verifica State/conta e apaga somente objetos Firebase reconhecidos. O arquivo local é preservado.

A VPC/subnets padrão, domínio, DNS e serviços externos não são destruídos. Os arquivos `.env`, `env/firebase.json`, backups e State permanecem locais. O DNS pode continuar apontando para um ALB destruído: migre antes o tráfego quando necessário. ALB, Fargate, logs e IPv4 públicos geram custos; sem NAT Gateway não significa ambiente gratuito.

## Nova conta e preservação

Guarde privadamente os `.env` e backups da pasta `.states/` fora das contas temporárias. State local não é backup remoto nem compartilhamento de equipe. Nunca copie o State de uma conta para dentro do diretório de outra e nunca permita dois States gerenciarem os mesmos recursos.

Em uma conta nova: copie o projeto, forneça os `.env`, ative o Lab, execute ./deploy.sh <nova-versao>, valide certificado e saúde, e somente então migre o DNS. O identificador da conta é obtido por STS e o provider restringe a execução àquela conta.

## Verificações locais

```bash
python3 -m unittest discover -s tests -v
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;
terraform -chdir=terraform fmt -check
terraform -chdir=modules fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

Não execute `apply` diretamente sem apontar o backend e runtime da conta; use os scripts. O lock file deve ser versionado. O ZIP de entrega não inclui `.git`, credenciais, apps clonados, caches nem State.
