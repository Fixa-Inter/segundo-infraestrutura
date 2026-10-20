# Auditoria e plano de ação — FIXA

**Atualização posterior — Firebase em S3:** consulte FIREBASE.md. Os trechos da auditoria inicial abaixo sobre obrigatoriedade de FIREBASE_CREDENTIALS_JSON foram substituídos: a implementação atual usa env/firebase.json no S3 privado, FIREBASE_CREDENTIALS_PATH no contêiner e download no runtime. Novos testes constam ao final.

Revisão de 19/10/2026 (São Paulo). Base: ZIP recebido e leitura dos quatro repositórios públicos na branch main. Nenhuma alteração foi enviada aos repositórios, à AWS ou à Hostinger.

## O que realmente havia no ZIP

O ZIP já continha Terraform modular para quatro APIs, scripts de deploy/destroy, sincronização Git, build de imagens, ativação e checagem superficial de `.env`. **Não continha** os quatro `.env`, apps clonados, State da infraestrutura antiga nem `scripts/sync-secrets.py`. O README ainda descrevia um template genérico. Portanto, a afirmação do contexto de que os novos `.env` foram adicionados não pôde ser confirmada no anexo.

Os módulos já tinham boas decisões que foram preservadas: digest ECR na task, Security Group exclusivo com entrada somente do ALB, Fargate com saída pública sem NAT, logs por API e circuit breaker com rollback.

## Problemas encontrados e tratamento

| Prioridade | Evidência no original | Tratamento nesta entrega |
|---|---|---|
| P0 | `backend "local" {}` fora de `terraform {}` em versions.tf | Movido para o bloco correto |
| P0 | terraform.tfvars habilitava APIs e HTTPS no primeiro apply | Arquivo neutralizado; fases persistidas por conta/região |
| P0 | setup-env.sh chamava sync-secrets.py inexistente | Implementado parser/validador/sincronizador sem dependências externas |
| P0 | activate-apis.sh calculava IMAGE_TAGS mas não o passava; não ativava variáveis Terraform | Ativação grava runtime explícito com APIs, HTTPS e tags |
| P0 | Falta de manifestos era ocultada por `try(..., "[]")`/string vazia | APIs habilitadas exigem manifestos JSON presentes |
| P1 | Nomes SSM eram reconstruídos usando lowercase/substituição, sem sincronizador correspondente | Terraform consome mapa exato nome→ARN produzido pela sincronização; preserva case |
| P1 | Reexecutar deploy com flags transitórias poderia desativar recursos | Runtime persistido; deploy recusa delete/replacement de infraestrutura (permite revisão de Task Definition) |
| P1 | Seleção das duas primeiras subnets por ID não assegurava AZs distintas nem rota pública | Uma subnet por AZ; preflight confere IGW ativo |
| P1 | Risco de colidir com recursos antigos ao usar novo State | Preflight bloqueia implantação inicial quando encontra recursos FIXA existentes |
| P1 | State separado só por conta; região AWS CLI inconsistente entre comandos | Diretório conta/us-east-1, região comum, checagem de outputs/ARNs e allowed_account_ids |
| P1 | ECR force_delete=true incondicional | false; limpeza de imagens exige --delete-images e confirmação do destroy |
| P1 | Limpeza SSM varria todo /fixa/; modo --legacy poderia atingir outro projeto | Limpeza restrita a manifestos da conta; --legacy removido |
| P1 | Ativação apenas listava contagens ECS | Novo verificador de rollout exato, Target Group e TLS/SNI no ALB novo |
| P1 | Nenhuma integração Hostinger | Cliente GET/PUT com plano, escopo de registros, backup e verificação de concorrência |
| P2 | setup.sh dependia de .terraform-version inexistente | Arquivo 1.10.5 adicionado |
| P2 | Shebangs com linha vazia anterior e CRLF | Scripts operacionais normalizados para Linux e executáveis |
| P2 | Tag v1 reutilizada sem relação com commit | Versão explícita; recibos locais de commit/digest impedem reutilização silenciosa com outro fonte |
| P2 | README genérico | Guia operacional completo, contratos e diagnóstico |

A migração DNS de tráfego permanece uma etapa explícita após a saúde do ALB. Isso preserva o requisito de manter o ambiente antigo funcionando durante o desenvolvimento. A validação ACM pode ser integrada ao deploy quando o token Hostinger é fornecido privadamente.

## Evidências nos backends

| API | Commit consultado | Porta | Saúde |
|---|---|---|---|
| Mobile | 740b7a864025e9a1580bc9fa90d3cdcd3978b305 | 8080 | /actuator/health |
| Web | f73cad25c4d9ddd2ca58432c72d2e5e82a6144fa | 8080 | /actuator/health |
| NoSQL | 5917cb6e5914c61456a1f99a172243e007318a7e | 8080 | /actuator/health |
| IA | a82a01a5dedd6e31cf6937b68fa3068c8d573b35 | 8000 | /api/v1/health |

- Dockerfiles Java usam `${PORT:-8080}`; o da IA fixa uvicorn em 8000. Validador impede PORT/SERVER_PORT divergente para Java.
- Os três SecurityConfig Java permitem /actuator/health. A IA registra /health sob o prefixo /api/v1.
- Mobile: application.yaml usa DB_*, REDIS_*, MAIL_*, JWT_SECRET e Firebase. FirebaseTokenVerifier escolhe credentialsJson primeiro; credentialsPath é aberto com FileInputStream. O instalador aceita JSON no SSM e rejeita caminho porque não cria montagem de arquivo.
- Web: application.properties tem apenas nome e exposição de actuator. Datasource, Redis e SMTP precisam de propriedades nativas do Spring; DB_URL sozinho não é consumido. JwtConfig lê security.jwt.secret e decodifica Base64. JwtService exige security.jwt.expiration-seconds. Aliases e validação refletem essas diferenças.
- NoSQL: application.yaml usa PostgreSQL, Redis e **MONGODB_URI**. Esse nome difere da IA.
- IA: configuracao.py lê **MONGO_URI** para a variável Python MONGODB_URI. A lista de erros interna usa o rótulo MONGODB_URI, mas esse não é o nome efetivamente lido do ambiente. Mantivemos MONGO_URI no contrato. FIXA_API_BASE_URL é necessário aos fluxos de integração, mesmo não constando na lista OBRIGATORIAS daquele arquivo.

Os contratos distinguem variáveis com defaults no código de requisitos de operação completa. Por exemplo, exigir SMTP/Redis na Web é uma escolha do perfil completo do FIXA, não prova de que todo campo individual é obrigatório para o processo iniciar. Não foram examinados valores reais dos `.env`, porque não foram enviados. `main` pode mudar: revise os contratos se a aplicação alterar sua configuração.

## Configuração e segredos

Todas as configurações não vazias são SecureString por padrão. Isso evita falsos negativos de um classificador por nomes, sobretudo em URLs que carregam usuário/senha. `.public.json` contém apenas marcador de versão de configuração; `.public.env` fica vazio por compatibilidade. `.secrets.json` contém mapa de ARNs, sem valores. Terraform não cria recursos aws_ssm_parameter com valores no State.

O parser suporta strings com igual, aspas, comentários e JSON multilinha. Não interpreta shell. Checa limite em bytes UTF-8 antes de qualquer escrita. Todos os `.env` são validados antes de sincronizar o primeiro backend. Erros AWS são resumidos por código para não ecoar payloads. Escritas SSM são retomáveis, mas não transacionais: uma falha no meio pode deixar parâmetros parcialmente atualizados. Reexecute após corrigir a causa.

Parâmetros sem mudança não geram novas versões. Os números de versão compõem um marcador da task, fazendo a alteração do segredo produzir novo deployment. Variáveis removidas do `.env` deixam de ser injetadas; o parâmetro antigo não é apagado automaticamente.

Permissões reais da execution role ainda precisam ser verificadas no Learner Lab. O fato de o operador poder gravar SSM não significa que a LabRole pode ler os mesmos parâmetros. Não alteramos a política ou trust da LabRole às cegas.

## Verificações realizadas

- **19 testes automatizados passaram:** parser/JSON, duplicatas, rejeição de shell, erros sem valores, limite UTF-8, host local, aliases, Firebase, SSM idempotente e manifestos sem segredo; registros ACM e tráfego DNS; tag/commit; saúde ECS/TLS e rejeição de rollback antigo; bloqueio de substituição de infraestrutura e permissão para nova revisão de task.
- `bash -n` passou em todos os scripts shell.
- Compilação sintática Python passou nos scripts e testes.
- `terraform fmt -check` passou na raiz Terraform e módulo.
- `terraform init -backend=false` obteve provider e lock. A validação semântica **não passou**: o CLI retornou divergência entre checksum do provider extraído e lock neste ambiente. O arquivo ZIP oficial do provider 6.0.0 foi baixado separadamente, seu SHA256 correspondeu ao checksum `4cd447b5c24f14553bd6e1a0e4fea3c7d7b218cbb2316a3d93f1c5cb562c181b` e seus binários foram comparados aos extraídos. Mesmo assim, `terraform validate` continuou bloqueado. Não foi desabilitada a checagem de integridade. A tentativa de mirror local foi descartada da entrega e o lock mantém os hashes oficiais obtidos pelo registry.

O provider foi fixado em 6.0.0 para tornar a revisão reprodutível após o mesmo problema aparecer na resolução automática 6.69.1. Isso não resolveu o problema de checksum do executor. O pacote não inclui binários, mirrors ou caches. Rode init/validate no CloudShell antes de qualquer apply; se falhar, pare e investigue a integridade/cache. Formatação aprovada não substitui validate.

Nenhuma destas verificações comprova saúde real da AWS. Não foram executados builds Docker, push ECR, chamadas autenticadas SSM/Hostinger, emissão ACM, Terraform plan/apply/destroy nem testes reais de negócio.

## Plano de ação restante, na ordem

1. **Validar Terraform no CloudShell:** init e validate com lock versionado; resolver a divergência de checksum antes de criar recursos. Fazer isso em cópia de trabalho sem State antigo.
2. **Conferir os quatro `.env` privadamente:** executar check-env.sh. Revisar nomes específicos Web, Base64, Firebase JSON ≤4 KB e MONGO_URI da IA. Não enviar credenciais pelo chat. Os arquivos não estavam no anexo.
3. **Testar conta nova no Learner Lab:** conferir permissões LabRole (ECR, CloudWatch, ssm:GetParameters), VPC padrão/subnets/rotas e recursos disponíveis. Executar primeiro plano revisável. Uma VPC própria como fallback ainda não foi implementada.
4. **Validar runtime:** construir as quatro imagens reais, sincronizar parâmetros, emitir ACM, ativar serviços e executar check-deployment.sh. Ajustar CPU/memória/grace period se o comportamento real exigir; 512 CPU/1024 MiB foram preservados como base.
5. **Homologar Hostinger:** confirmar que a conta tem API, token e DNS autoritativo acessíveis. Primeiro testar registros de validação; depois planejar tráfego. O cliente foi baseado no OpenAPI oficial e testado com dados simulados, mas não com a conta real.
6. **Testar negócio e migração:** saúde do ALB não prova login/Firebase, SMTP, consultas a bancos, funções IA e integrações. Validar esses fluxos antes do corte DNS; então revisar/aplicar traffic --apply. Conferir propagação pública e clientes.
7. **Ensaio de desmontagem/retomada:** confirmar destruição com imagens e limpeza opcional de parâmetros na conta de teste. Conferir custos remanescentes, guardar .env/.states privadamente e ensaiar nova conta.

## Limites operacionais conhecidos

- State local depende de backup privado externo. Não há backend remoto nem lock distribuído entre computadores.
- O instalador pressupõe uma VPC padrão com duas subnets públicas válidas; falha claramente se a premissa não for satisfeita.
- Chamadas remotas podem sofrer falhas transitórias e quotas; não há garantia de atomicidade entre AWS, builds e DNS.
- Se o push terminar mas o processo morrer antes do recibo de imagem, a retomada exigirá nova versão para não confiar numa imagem sem proveniência local.
- Confirmações de apply e corte DNS são intencionais. Não é uma implantação inteiramente sem supervisão.
- Sem rollback DNS automático: o backup registra a zona anterior para revisão. Não restaurar a zona inteira cegamente, pois outros registros podem mudar.
- Segredos maiores que 4 KB não têm caminho alternativo automático. Será preciso decidir entre ajuste do formato, arquivo externo ou outro serviço, com avaliação de custo.
- O domínio e bancos externos nunca são gerenciados por este Terraform. A infraestrutura antiga não foi importada nem modificada.

## Documentação primária consultada

- https://developer.hashicorp.com/terraform/language/backend
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-ssm-paramstore.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
- https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-advanced-parameters.html
- https://docs.hostinger.com/api-reference/overview
- https://docs.hostinger.com/api-reference/endpoints/dns/zone/update-dns-records.md
- https://developers.hostinger.com/openapi/openapi.json

O schema OpenAPI esclarece que overwrite=true substitui RRs correspondentes ao nome/tipo enviado. overwrite=false acrescenta registros e atualiza TTL; por isso não serviria para substituir com segurança o CNAME antigo de tráfego. A requisição desta implementação limita-se aos nomes selecionados, sem enviar a zona toda.

## Atualização implementada: arquivo Firebase no S3

- Criados firebase.tf, uploader, validador de arquivo, inicializador da imagem Mobile e limpeza opcional.
- O bucket é privado, criptografado, exige HTTPS e concede leitura à Task Role LabRole por bucket policy; políticas IAM da role não são alteradas.
- Uploads usam objetos separados por SHA256 e checksum S3. Nenhum conteúdo da credencial entra no State, SSM, imagem ou logs.
- O `.env` mantém apenas o caminho /app/secrets/firebase.json. O projeto é extraído do arquivo local.
- A nova imagem baixa e confere o JSON antes de iniciar o Java como usuário sem privilégios.
- Imagens antigas sem essa camada exigem uma nova tag; recibos verificam fonte e receita da imagem.
- O destroy exige --delete-firebase para remover objetos e bucket, mantendo o arquivo local.
- A validação real de IAM, API S3, build Alpine e inicialização Firebase continua pendente no laboratório. Nenhuma credencial real foi fornecida e nenhum upload AWS foi realizado.

Referências adicionais: https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html e https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html

Verificação local desta atualização: **27 testes passaram**, incluindo os casos novos de Firebase/S3, configuração pública de caminho/projeto, download/checagem do arquivo e invalidação de recibo quando a receita Docker muda. Bash, compilação Python e terraform fmt -check também passaram. terraform validate foi tentado novamente e permaneceu bloqueado pelo checksum do provider. Sem chamadas autenticadas reais à AWS ou build Docker.
