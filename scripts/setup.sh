#!/usr/bin/env bash
set -euo pipefail

echo "================================"
echo " Preparando ambiente Terraform "
echo "================================"

# Diretório raiz do repositório
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 1. Instalar o tfenv, caso ainda não exista
if [ ! -d "$HOME/.tfenv" ]; then
    echo "Instalando tfenv..."
    git clone --depth=1 \
        https://github.com/tfutils/tfenv.git \
        "$HOME/.tfenv"
else
    echo "tfenv ja esta instalado."
fi

# 2. Disponibilizar tfenv e Terraform no PATH
export PATH="$HOME/.tfenv/bin:$PATH"

# Persistir essa configuracao para futuros terminais Bash
if ! grep -Fq 'export PATH="$HOME/.tfenv/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> "$HOME/.bashrc"
fi

# 3. Instalar a versao definida pelo projeto
echo "Instalando a versao do Terraform definida em .terraform-version..."
tfenv install

# 4. Selecionar a versao
tfenv use

# 5. Validar a instalacao
echo "Terraform instalado:"
terraform version

# 6. Conferir a identidade AWS
echo "Identidade AWS atual:"
aws sts get-caller-identity

echo "Ambiente preparado com sucesso!"