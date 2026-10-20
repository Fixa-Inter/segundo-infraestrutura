#!/usr/bin/env bash
activate() {
  local version="$1" cert status
  cert=$(terraform -chdir="$TF_DIR" output -raw acm_certificate_arn)
  status=$(aws acm describe-certificate --certificate-arn "$cert" --query Certificate.Status --output text)
  if [[ "$status" != ISSUED && -f "$ROOT/env/hostinger.token" ]]; then
    python3 "$ROOT/scripts/hostinger-dns.py" validation "$STATE_DIR" --apply
    echo "Aguardando ACM por ate cinco minutos; se pendente, a fase pode ser retomada."
    for ((attempt=0; attempt<30; attempt++)); do
      status=$(aws acm describe-certificate --certificate-arn "$cert" --query Certificate.Status --output text)
      [[ "$status" == ISSUED ]] && break
      [[ "$status" == PENDING_VALIDATION ]] || fail "Certificado ACM em estado $status"
      sleep 10
    done
  fi
  if [[ "$status" != ISSUED ]]; then
    echo "Certificado: $status. Cadastre SOMENTE os CNAMEs de validacao abaixo na Hostinger."
    terraform -chdir="$TF_DIR" output acm_validation_records
    echo "DNS de trafego preservado. Apos emissao, retome: ./scripts/activate-apis.sh $version"
    return 2
  fi
  for api in mobile web nosql ia; do
    aws ecr describe-images --repository-name "fixa/$api-api" --image-ids "imageTag=$version" >/dev/null
    [[ -s "$STATE_DIR/env/$api.secrets.json" ]] || fail "Manifesto ausente para $api na conta/regiao atual"
  done
  [[ -s "$STATE_DIR/env/mobile.firebase.json" ]] || fail "Execute ./scripts/upload-firebase.sh antes de ativar Mobile"
  # Versoes SSM entram como marcador nao secreto para reiniciar tasks quando houver alteracao.
  python3 - "$STATE_DIR" "$version" <<'PY'
import json,sys,hashlib
from pathlib import Path
p=Path(sys.argv[1]); apis=['mobile','web','nosql','ia']
for api in apis:
    versions=(p/'env'/f'{api}.versions.json').read_bytes()
    marker=hashlib.sha256(versions).hexdigest()
    file=p/'env'/f'{api}.public.json'
    public=json.loads(file.read_text())
    public['FIXA_CONFIG_REVISION']=marker
    file.write_text(json.dumps(public))
(p/'runtime.tfvars.json').write_text(json.dumps({'enable_https':True,'enabled_apis':apis,'image_tags':{a:sys.argv[2] for a in apis}}))
PY
  plan_apply ativacao
  python3 "$ROOT/scripts/check-deployment.py" "$STATE_DIR"
}
