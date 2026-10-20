#!/usr/bin/env python3
"""Valida env/firebase.json e envia ao bucket privado criado pelo Terraform."""
import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from env_config import ConfigError, parse_env
from firebase_config import mobile_firebase

spec = importlib.util.spec_from_file_location('sync_secrets', Path(__file__).with_name('sync-secrets.py'))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
ROOT = Path(__file__).resolve().parents[1]
REGION = 'us-east-1'


def local_config():
    p = ROOT/'env/mobile.env'
    if not p.is_file():
        raise ConfigError('env/mobile.env: arquivo ausente')
    return mobile_firebase(parse_env(p.read_text(encoding='utf-8-sig')), ROOT/'env/firebase.json')


def outputs(state_dir):
    p = subprocess.run(['terraform', f'-chdir={ROOT}/terraform', 'output', '-json'],
        env=dict(os.environ, TF_DATA_DIR=str(state_dir/'.terraform'), TF_WORKSPACE='default'),
        text=True, capture_output=True)
    if p.returncode:
        raise ConfigError('Nao foi possivel ler outputs; aplique primeiro a infraestrutura com firebase.tf')
    return {k: v['value'] for k, v in json.loads(p.stdout).items()}


def upload(state_dir, raw, project, digest):
    out = outputs(state_dir)
    account = sync.aws('sts', 'get-caller-identity')['Account']
    if out['aws_account_id'] != account or out['aws_region'] != REGION:
        raise ConfigError('State e credenciais pertencem a conta/regiao diferentes')
    if state_dir.resolve() != (ROOT/'.states'/account/REGION).resolve():
        raise ConfigError('Diretorio de State inesperado para esta conta/regiao')
    bucket = out.get('firebase_bucket')
    if bucket != f'fixa-secrets-{account}-{REGION}':
        raise ConfigError('Bucket ausente ou inesperado: use o bucket FIXA criado por firebase.tf')
    common = ('--region', REGION, '--bucket', bucket, '--expected-bucket-owner', account)
    block = sync.aws('s3api', 'get-public-access-block', *common)['PublicAccessBlockConfiguration']
    if not all(block.get(k) is True for k in ('BlockPublicAcls','BlockPublicPolicy','IgnorePublicAcls','RestrictPublicBuckets')):
        raise ConfigError('Bucket sem bloqueio completo de acesso publico; upload interrompido')
    enc = sync.aws('s3api', 'get-bucket-encryption', *common)['ServerSideEncryptionConfiguration']['Rules']
    if not any(r.get('ApplyServerSideEncryptionByDefault',{}).get('SSEAlgorithm')=='AES256' for r in enc):
        raise ConfigError('Bucket sem criptografia AES256 configurada')
    key = f'firebase/{digest}.json'
    checksum = base64.b64encode(bytes.fromhex(digest)).decode('ascii')
    try:
        head = sync.aws('s3api', 'head-object', *common, '--key', key, '--checksum-mode', 'ENABLED')
    except ConfigError as e:
        if str(e) not in ('AWS: 404', 'AWS: NoSuchKey', 'AWS: NotFound'):
            raise
        head = None
    if head is not None:
        if head.get('ChecksumSHA256') != checksum or head.get('ContentLength') != len(raw):
            raise ConfigError('Objeto existente nao corresponde ao checksum local; nao sera sobrescrito')
    else:
        # Snapshot privado: evita mudar arquivo entre validacao e leitura pelo AWS CLI.
        fd, temp = tempfile.mkstemp()
        try:
            with os.fdopen(fd,'wb') as f:
                f.write(raw)
            sync.aws('s3api', 'put-object', *common, '--key', key, '--body', temp,
                '--server-side-encryption','AES256','--content-type','application/json',
                '--checksum-sha256',checksum,'--if-none-match','*')
        finally:
            os.unlink(temp)
        head = sync.aws('s3api', 'head-object', *common, '--key',key,'--checksum-mode','ENABLED')
        if head.get('ChecksumSHA256') != checksum or head.get('ContentLength') != len(raw):
            raise ConfigError('S3 nao confirmou checksum/tamanho; manifestos nao foram atualizados')
    manifest = {
        'FIREBASE_S3_BUCKET': bucket,
        'FIREBASE_S3_KEY': key,
        'FIREBASE_S3_BUCKET_OWNER': account,
        'FIREBASE_CREDENTIALS_SHA256': digest,
        'FIREBASE_PROJECT_ID': project,
        'AWS_DEFAULT_REGION': REGION,
    }
    sync.private_json(state_dir/'env/mobile.firebase.json', manifest)
    print('[OK] Firebase enviado/conferido no S3 privado; manifesto Mobile atualizado. Conteudo omitido.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--state-dir', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    raw, project, digest = local_config()
    if args.check:
        print('[OK] env/firebase.json e caminho do Mobile validados; nenhuma chamada AWS realizada.')
        return
    if not args.state_dir:
        raise ConfigError('Use ./scripts/upload-firebase.sh para selecionar a conta/regiao automaticamente')
    upload(args.state_dir, raw, project, digest)

if __name__ == '__main__':
    try:
        main()
    except (ConfigError, OSError, ValueError, KeyError):
        e = sys.exc_info()[1]
        print('[ERRO] ' + (str(e) if isinstance(e,ConfigError) else 'Falha ao preparar Firebase; valores omitidos'), file=sys.stderr)
        sys.exit(1)
