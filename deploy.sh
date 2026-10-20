#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

[[ -s "$ROOT/env/hostinger.token" ]] ||
  fail "Arquivo env/hostinger.token ausente ou vazio"

chmod 600 "$ROOT/env/hostinger.token"

# Funções compartilhadas:
# identificação da conta, State isolado, lock e plano com confirmação.
source "$ROOT/scripts/common.sh"

VERSION="${1:-}"

if [[ "$#" != 1 || ! "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  fail "Uso: bash deploy.sh firebase-01"
fi

step() {
  echo
  echo "[$1/9] $2"
}

install_terraform() {
  local wanted current tfenv_dir

  [[ -f "$ROOT/.terraform-version" ]] ||
    fail "Arquivo .terraform-version ausente"

  wanted=$(tr -d '[:space:]' < "$ROOT/.terraform-version")

  [[ "$wanted" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail "Versao Terraform invalida"

  current=""

  # Reutiliza o Terraform instalado quando a versão corresponde ao projeto.
  if command -v terraform >/dev/null 2>&1; then
    if current=$(
      terraform version -json 2>/dev/null |
        python3 -c '
import json
import sys
print(json.load(sys.stdin)["terraform_version"])
'
    ); then
      :
    else
      current=""
    fi
  fi

  if [[ "$current" == "$wanted" ]]; then
    echo "Terraform $wanted ja disponivel."
    return
  fi

  # Instala o gerenciador de versões quando necessário.
  tfenv_dir="$HOME/.tfenv"

  if [[ ! -e "$tfenv_dir" ]]; then
    git clone --depth=1 \
      https://github.com/tfutils/tfenv.git \
      "$tfenv_dir"
  fi

  [[ -x "$tfenv_dir/bin/tfenv" ]] ||
    fail "Instalacao tfenv incompleta em $tfenv_dir"

  export PATH="$tfenv_dir/bin:$PATH"

  tfenv install "$wanted"
  tfenv use "$wanted"

  current=$(
    terraform version -json |
      python3 -c '
import json
import sys
print(json.load(sys.stdin)["terraform_version"])
'
  )

  [[ "$current" == "$wanted" ]] ||
    fail "Terraform selecionado nao corresponde ao projeto"
}

step 1 "Verificando ferramentas e arquivos"

# Terraform será instalado automaticamente.
# As demais ferramentas precisam estar disponíveis no CloudShell.
for cmd in aws git docker python3 curl unzip flock; do
  command -v "$cmd" >/dev/null 2>&1 ||
    fail "Dependencia ausente: $cmd"
done

for file in \
  terraform/firebase.tf \
  scripts/upload-firebase.py \
  scripts/activation.sh \
  runtime/mobile/Dockerfile \
  runtime/mobile/entrypoint.py
do
  [[ -f "$ROOT/$file" ]] ||
    fail "Arquivo ausente: $file. Use o projeto atualizado completo."
done

chmod +x "$ROOT"/scripts/*.sh

docker info >/dev/null 2>&1 ||
  fail "Docker indisponivel; inicie o Docker antes de continuar"

step 2 "Validando os quatro .env e env/firebase.json"

# Somente validação local; não envia segredos nesta etapa.
python3 "$ROOT/scripts/sync-secrets.py" all --check

step 3 "Preparando o Terraform"

install_terraform

step 4 "Identificando conta e inicializando o State"

# Obtém a conta por STS e configura:
# .states/<conta>/us-east-1/
init_context

echo "Conta: $ACCOUNT_ID | Regiao: $REGION"

terraform -chdir="$TF_DIR" validate

# Confere conflitos com recursos existentes e rotas das subnets.
python3 "$ROOT/scripts/preflight.py" \
  "$STATE_DIR/terraform.tfstate"

step 5 "Criando infraestrutura e bucket privado"

# firebase.tf cria o bucket dentro do mesmo State.
# O plano é mostrado e exige confirmação antes do apply.
plan_apply infraestrutura

step 6 "Enviando env/firebase.json ao S3"

# Valida o arquivo, verifica proteção do bucket,
# envia o objeto e confere o checksum.
python3 "$ROOT/scripts/upload-firebase.py" \
  --state-dir "$STATE_DIR"

step 7 "Sincronizando fontes e publicando imagens"

# Esse script já sincroniza os repositórios antes do build.
# O Mobile recebe o inicializador que baixa o Firebase antes do Java.
bash "$ROOT/scripts/build-images.sh" all "$VERSION"

step 8 "Sincronizando configuracoes e segredos SSM"

python3 "$ROOT/scripts/sync-secrets.py" \
  all \
  --region "$REGION"

step 9 "Validando certificado, ativando APIs e verificando saude"

source "$ROOT/scripts/activation.sh"

# Publica os CNAMEs de validacao ACM quando necessario,
# aguarda o certificado, ativa as APIs e verifica sua saude.
activate "$VERSION"

echo
echo "Publicando os CNAMEs das APIs na Hostinger..."

# Usa o contexto e o lock ja adquiridos pelo deploy.
# O modo traffic verifica novamente as APIs antes de alterar o DNS.
python3 "$ROOT/scripts/hostinger-dns.py" \
  traffic \
  "$STATE_DIR" \
  --apply

echo
echo "Deploy concluido; registros conferidos na API Hostinger."

terraform -chdir="$TF_DIR" output api_hostnames

echo
echo "A propagacao publica do DNS ainda pode levar algum tempo."