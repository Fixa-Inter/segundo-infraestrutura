"""Baixa a credencial privada para disco efemero antes de iniciar o Java."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

CREDENTIAL_PATH = '/app/secrets/firebase.json'
MAX_BYTES = 128 * 1024


def prepare_firebase(env, s3):
    path = env.get('FIREBASE_CREDENTIALS_PATH')
    if path != CREDENTIAL_PATH or env.get('FIREBASE_CREDENTIALS_JSON'):
        raise RuntimeError('Configuracao Firebase incompativel')
    owner = env.get('FIREBASE_S3_BUCKET_OWNER', '')
    digest = env.get('FIREBASE_CREDENTIALS_SHA256', '')
    if not re.fullmatch(r'[0-9]{12}', owner) or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise RuntimeError('Identidade/checksum Firebase invalidos')
    bucket = env.get('FIREBASE_S3_BUCKET')
    key = env.get('FIREBASE_S3_KEY')
    if bucket != f'fixa-secrets-{owner}-us-east-1' or key != f'firebase/{digest}.json':
        raise RuntimeError('Destino Firebase inesperado')
    response = s3.get_object(Bucket=bucket, Key=key, ExpectedBucketOwner=owner)
    body = response['Body']
    try:
        raw = body.read(MAX_BYTES + 1)
    finally:
        body.close()
    if len(raw) > MAX_BYTES or hashlib.sha256(raw).hexdigest() != digest:
        raise RuntimeError('Integridade da credencial Firebase nao confirmada')
    data = json.loads(raw.decode('utf-8-sig'))
    if not isinstance(data,dict) or data.get('type') != 'service_account':
        raise RuntimeError('Credencial Firebase invalida')
    for key in ('project_id','client_email','private_key'):
        if not isinstance(data.get(key),str) or not data[key].strip():
            raise RuntimeError('Credencial Firebase incompleta')
    if data['project_id'] != env.get('FIREBASE_PROJECT_ID'):
        raise RuntimeError('Projeto Firebase divergente')
    if '-----BEGIN PRIVATE KEY-----' not in data['private_key'] or '-----END PRIVATE KEY-----' not in data['private_key']:
        raise RuntimeError('Formato da credencial Firebase invalido')
    target = Path(path)
    target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    target.parent.chmod(0o700)
    fd, temp = tempfile.mkstemp(dir=target.parent)
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(raw)
        os.replace(temp,target)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    os.umask(0o077)
    import boto3
    s3 = boto3.client('s3',region_name='us-east-1')
    prepare_firebase(os.environ,s3)
    print('[OK] Credencial Firebase preparada; iniciando Mobile.',flush=True)
    if len(sys.argv) < 2:
        raise RuntimeError('Comando Java ausente')
    os.execvp(sys.argv[1],sys.argv[1:])

if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Nem resposta S3, nem arquivo, nem excecoes do SDK sao enviados ao log.
        print('[ERRO] Nao foi possivel preparar Firebase. Verifique arquivo, checksum e permissoes S3 da Task Role. Mobile nao iniciado.',file=sys.stderr)
        sys.exit(1)
