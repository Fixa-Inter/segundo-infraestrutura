#!/usr/bin/env python3
"""Limpa apenas objetos Firebase no bucket deste State apos confirmacao no destroy."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys
spec = importlib.util.spec_from_file_location('sync_secrets',Path(__file__).with_name('sync-secrets.py'))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
from env_config import ConfigError


def clean(state_dir, delete):
    state=json.loads((state_dir/'terraform.tfstate').read_text())
    buckets=[i['attributes']['bucket'] for r in state.get('resources',[]) if r.get('mode')=='managed' and r.get('type')=='aws_s3_bucket' and r.get('name')=='firebase' for i in r.get('instances',[])]
    if not buckets:
        return
    account=sync.aws('sts','get-caller-identity')['Account']
    if buckets != [f'fixa-secrets-{account}-us-east-1']:
        raise ConfigError('Bucket Firebase do State nao corresponde a conta atual')
    common=('--bucket',buckets[0],'--region','us-east-1','--expected-bucket-owner',account)
    listing=sync.aws('s3api','list-object-versions',*common)
    objects=[{'Key':o['Key'],'VersionId':o['VersionId']} for group in ('Versions','DeleteMarkers') for o in listing.get(group,[])]
    if not objects:
        return
    if not delete:
        raise ConfigError('Bucket Firebase contem arquivos. Para destruir tudo, use --delete-firebase explicitamente.')
    if any(not re.fullmatch(r'firebase/[a-f0-9]{64}\.json',o['Key']) for o in objects):
        raise ConfigError('Bucket contem arquivos fora do padrao Firebase; limpeza automatica interrompida')
    for index in range(0,len(objects),1000):
        response=sync.aws('s3api','delete-objects','--region','us-east-1','--cli-input-json','file:///dev/stdin',payload={
            'Bucket':buckets[0],'ExpectedBucketOwner':account,'Delete':{'Objects':objects[index:index+1000],'Quiet':True}})
        if response.get('Errors'):
            raise ConfigError('S3 nao confirmou exclusao de todos os objetos; destroy interrompido')
    print('[OK] Objetos Firebase removidos do bucket gerenciado; arquivo env/firebase.json local preservado.')

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--state-dir',required=True,type=Path)
    parser.add_argument('--delete',action='store_true')
    args=parser.parse_args()
    try:
        clean(args.state_dir,args.delete)
    except (ConfigError,OSError,ValueError,KeyError) as e:
        print('[ERRO] '+(str(e) if isinstance(e,ConfigError) else 'Falha na limpeza Firebase'),file=sys.stderr)
        sys.exit(1)
