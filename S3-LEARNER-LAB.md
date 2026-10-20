# Migracao do bucket Firebase no Learner Lab

A SCP desta conta nega s3:GetBucketObjectLockConfiguration. O recurso aws_s3_bucket do provider 6.0.0 consulta essa API no refresh mesmo sem Object Lock configurado. Definir object_lock_enabled=false ou ignore_changes nao impede essa leitura. Uma permissao IAM Allow nao supera a SCP.

Esta correcao usa terraform_data.firebase_bucket e scripts/firebase-bucket.sh para criar/reutilizar e excluir o bucket comum com STS, HeadBucket, CreateBucket e DeleteBucket. As protecoes de acesso publico, ownership, criptografia e bucket policy continuam em recursos Terraform separados. Nenhuma configuracao de Object Lock e consultada ou alterada. As demais permissoes S3 continuam necessarias.

Arquivos atualizados: terraform/firebase.tf, scripts/firebase-bucket.sh, scripts/preflight.py e scripts/cleanup-firebase.py. A limpeza --delete-firebase reconhece o registro novo e o antigo. O restante do projeto, inclusive validacao dos .env, esta preservado.

## Conta em que o apply ja falhou

Copie os arquivos corrigidos para a pasta de trabalho atual **sem substituir/remover .states/**. Nao rode cleanup-manual para esta migracao: o apply pode ter criado outros recursos validos.

Na raiz do projeto, execute UMA VEZ:

```bash
export PATH="$HOME/.tfenv/bin:$PATH"
(
  source scripts/common.sh
  init_context

  terraform -chdir="$TF_DIR" state pull \
    > "$STATE_DIR/before-s3-migration-$(date +%Y%m%dT%H%M%S).tfstate"

  if terraform -chdir="$TF_DIR" state list | grep -Fxq 'aws_s3_bucket.firebase'; then
    terraform -chdir="$TF_DIR" state rm 'aws_s3_bucket.firebase'
  fi

  plan_apply migracao-s3
)
```

O comando state rm esquece somente o registro antigo do bucket, sem apagar o bucket ou seus arquivos. A copia de seguranca e gravada antes. O plano seguinte introduz o novo controlador e pede confirmacao; revise-o. O uso de subshell libera o lock antes de executar novamente o deploy.

Depois, repita o deploy com a mesma versao utilizada antes da falha. Ele continua a partir dos recursos existentes. O novo preflight reconhece terraform_data.firebase_bucket e mantem o bloqueio para buckets desconhecidos em outros States.

## Limites

O bucket continua privado. A criacao/exclusao e feita por provisioners; terraform_data nao consulta por conta propria se o bucket foi apagado manualmente. Nao remova o bucket por fora do fluxo gerenciado. O script delete nao usa --force: arquivos remanescentes impedem a exclusao. Para limpar os objetos e destruir pelo Terraform, use o destroy-terraform.sh existente com --delete-firebase, alem das outras opcoes desejadas.

Essa migracao resolve a chamada desnecessaria a Object Lock, nao libera outras acoes negadas pela SCP. Se aparecer outro AccessDenied, a acao especifica precisa ser analisada separadamente.

Foram executadas verificacoes locais e simulacoes, sem chamadas AWS e sem migracao real do seu State.
