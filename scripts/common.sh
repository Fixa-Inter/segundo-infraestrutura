#!/usr/bin/env bash
# Carregado pelos comandos operacionais; nao executar diretamente.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform"
REGION=us-east-1
export AWS_DEFAULT_REGION="$REGION" AWS_PAGER="" TF_IN_AUTOMATION=1
fail() { echo "[ERRO] $*" >&2; exit 1; }
init_context() {
  for cmd in aws terraform python3 flock; do
    command -v "$cmd" >/dev/null || fail "Dependencia ausente: $cmd"
  done
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "Identidade AWS invalida"
  STATE_DIR="$ROOT/.states/$ACCOUNT_ID/$REGION"
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  # Lock comum impede deploy, sync e destroy simultaneos pelo instalador.
  exec 9>"$STATE_DIR/operation.lock"
  flock -n 9 || fail "Outra operacao esta em andamento nesta conta/regiao"
  export TF_DATA_DIR="$STATE_DIR/.terraform" TF_WORKSPACE=default
  export TF_VAR_expected_account_id="$ACCOUNT_ID" TF_VAR_aws_region="$REGION"
  export TF_VAR_manifest_dir="$STATE_DIR/env"
  RUNTIME="$STATE_DIR/runtime.tfvars.json"
  if [[ ! -f "$RUNTIME" ]]; then
    printf '%s\n' '{"enable_https":false,"enabled_apis":[]}' > "$RUNTIME"
  fi
  terraform -chdir="$TF_DIR" init -reconfigure -input=false \
    -backend-config="path=$STATE_DIR/terraform.tfstate"
  if [[ -s "$STATE_DIR/terraform.tfstate" ]]; then
    # Um apply parcial pode ter recursos mas ainda nao ter outputs.
    python3 - "$STATE_DIR/terraform.tfstate" "$ACCOUNT_ID" "$REGION" <<'PYCODE'
import json,sys
state=json.load(open(sys.argv[1])); account,region=sys.argv[2:]
outputs=state.get('outputs',{})
for key,expected in [('aws_account_id',account),('aws_region',region)]:
    if key in outputs and outputs[key]['value']!=expected:
        sys.exit('State nao corresponde a conta/regiao atual')
for resource in state.get('resources',[]):
    if resource.get('mode')!='managed':
        continue
    for instance in resource.get('instances',[]):
        arn=instance.get('attributes',{}).get('arn','')
        if arn.startswith('arn:'):
            parts=arn.split(':',5)
            if (parts[4] and parts[4]!=account) or (parts[3] and parts[3]!=region):
                sys.exit('ARN de recurso no State pertence a outra conta/regiao')
PYCODE
  fi
}
plan_apply() {
  local phase="$1"
  local plan="$STATE_DIR/$phase.tfplan"
  terraform -chdir="$TF_DIR" plan -input=false -var-file="$RUNTIME" -out="$plan"
  # Alteracoes que removem recursos devem ser revisadas fora do deploy.
  terraform -chdir="$TF_DIR" show -json "$plan" | python3 -c '
import json,sys
x=json.load(sys.stdin)
def unsafe(r):
 actions=r["change"]["actions"]
 expected_revision=(r.get("type")=="aws_ecs_task_definition" and "create" in actions and "delete" in actions)
 return "delete" in actions and not expected_revision
if any(unsafe(r) for r in x.get("resource_changes",[])):
 sys.exit("Plano contem exclusao/substituicao. Deploy interrompido; revise o plano.")'
  # Mantem revisao concreta solicitada no contexto; nao usa auto-approve.
  local confirm
  read -r -p "Aplicar plano $phase na conta $ACCOUNT_ID? (sim/nao): " confirm
  [[ "$confirm" == sim ]] || fail "Operacao cancelada; nada aplicado nesta fase"
  terraform -chdir="$TF_DIR" apply -input=false "$plan"
  rm -f "$plan"
}
