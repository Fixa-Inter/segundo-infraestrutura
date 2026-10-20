#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"
DELETE_SECRETS=false
DELETE_IMAGES=false
DELETE_FIREBASE=false
for arg in "$@"; do
  case "$arg" in
    --delete-secrets) DELETE_SECRETS=true ;;
    --delete-images) DELETE_IMAGES=true ;;
    --delete-firebase) DELETE_FIREBASE=true ;;
    *) fail "Uso: ./destroy.sh [--delete-images] [--delete-secrets] [--delete-firebase]. Modo legacy removido." ;;
  esac
done
init_context
[[ -s "$STATE_DIR/terraform.tfstate" ]] || fail "Sem State da conta/regiao; nenhuma destruicao autorizada"
if [[ "$DELETE_FIREBASE" == false ]]; then
  python3 "$ROOT/scripts/cleanup-firebase.py" --state-dir "$STATE_DIR"
fi
PLAN_FILE="$STATE_DIR/destroy.tfplan"
# Nao atualiza DNS, nao toca VPC padrao nem servicos externos.
terraform -chdir="$TF_DIR" plan -input=false -destroy -var-file="$RUNTIME" \
  -out="$PLAN_FILE"
echo "Apagara os recursos do plano. ECR com imagens: $DELETE_IMAGES. SSM: $DELETE_SECRETS. Arquivos Firebase no S3: $DELETE_FIREBASE."
read -r -p "Digite DESTRUIR-$ACCOUNT_ID para executar: " confirmation
[[ "$confirmation" == "DESTRUIR-$ACCOUNT_ID" ]] || fail "Operacao cancelada"
if [[ "$DELETE_FIREBASE" == true ]]; then
  python3 "$ROOT/scripts/cleanup-firebase.py" --state-dir "$STATE_DIR" --delete
fi
if [[ "$DELETE_IMAGES" == true ]]; then
  # O provider usa o force_delete salvo no State durante destroy. Esvaziamos
  # explicitamente somente os ECRs gerenciados, sem alterar o State do plano.
  python3 - "$STATE_DIR/terraform.tfstate" <<'PYCODE'
import json,subprocess,sys
state=json.load(open(sys.argv[1]))
for r in state.get('resources',[]):
    if r.get('mode')!='managed' or r['type']!='aws_ecr_repository':
        continue
    for instance in r['instances']:
        name=instance['attributes']['name']
        ids=json.loads(subprocess.check_output(['aws','ecr','list-images','--region','us-east-1','--repository-name',name,'--output','json']))['imageIds']
        ids=[{'imageDigest':d} for d in sorted({i['imageDigest'] for i in ids})]
        for start in range(0,len(ids),100):
            payload={'repositoryName':name,'imageIds':ids[start:start+100]}
            out=subprocess.run(['aws','ecr','batch-delete-image','--region','us-east-1','--cli-input-json','file:///dev/stdin','--output','json'],input=json.dumps(payload),text=True,capture_output=True,check=True)
            if json.loads(out.stdout).get('failures'):
                sys.exit('Falha ao esvaziar ECR; destroy nao aplicado.')
PYCODE
fi
terraform -chdir="$TF_DIR" apply -input=false "$PLAN_FILE"
rm -f "$PLAN_FILE"
if [[ "$DELETE_SECRETS" == true ]]; then
  # Somente parametros registrados nos manifestos desta conta/regiao.
  python3 - "$STATE_DIR/env" <<'PY'
import json,sys,subprocess
from pathlib import Path
p=Path(sys.argv[1]); names=set()
for f in p.glob('*.secrets.json'):
    for arn in json.loads(f.read_text()).values():
        name=arn.split(':parameter',1)[1]
        if not name.startswith('/fixa/'):
            sys.exit('Manifesto contem prefixo inesperado; limpeza interrompida')
        names.add(name)
for name in sorted(names):
    subprocess.run(['aws','ssm','delete-parameter','--region','us-east-1','--name',name,'--no-cli-pager'],check=True)
print('[OK] Limpeza limitada aos parametros dos manifestos locais.')
PY
fi
# Reinicia as fases apenas depois de um destroy bem sucedido; preserva .env e state backup.
printf '%s\n' '{"enable_https":false,"enabled_apis":[]}' > "$RUNTIME"
echo "Recursos do plano removidos. Dominio, DNS e bancos externos preservados."
