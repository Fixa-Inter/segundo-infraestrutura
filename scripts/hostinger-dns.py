#!/usr/bin/env python3
"""Alteracoes DNS restritas: validacao ACM ou quatro CNAMEs de trafego."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request
import importlib.util
spec=importlib.util.spec_from_file_location('deployment',Path(__file__).with_name('check-deployment.py'))
deployment=importlib.util.module_from_spec(spec);spec.loader.exec_module(deployment)


DOMAIN='fixa.solutions'

def relative(name):
    name=name.rstrip('.').lower()
    if not name.endswith('.'+DOMAIN):
        raise RuntimeError('Registro fora do dominio permitido')
    return name[:-len(DOMAIN)-1]


def build_zone(outputs,mode,current):
    wanted={}
    if mode=='validation':
        for r in outputs['acm_validation_records']:
            name=relative(r['name'])
            if r['type']!='CNAME' or not name.startswith('_') or not r['value'].rstrip('.').endswith('.acm-validations.aws'):
                raise RuntimeError('Registro de validacao ACM inesperado')
            if name in wanted and wanted[name]!=r['value']:
                raise RuntimeError('Registros de validacao conflitantes')
            wanted[name]=r['value']
    else:
        for api in ('mobile','web','nosql','ia'):
            host=outputs['api_hostnames'][api]
            if host!=f'{api}-api.{DOMAIN}':
                raise RuntimeError('Hostname de trafego inesperado')
            wanted[relative(host)]=outputs['alb_dns']
    zone=[]
    for name,target in sorted(wanted.items()):
        matching=[r for r in current if r['name'].rstrip('.').lower() in (name,name+'.'+DOMAIN)]
        if any(r['type']!='CNAME' for r in matching):
            raise RuntimeError(f'{name}: conflito com outro tipo DNS; revise antes de automatizar')
        same=matching and len(matching)==1 and [r['content'].rstrip('.').lower() for r in matching[0]['records']]==[target.rstrip('.').lower()]
        if same:
            continue
        if mode=='validation' and matching:
            raise RuntimeError(f'{name}: CNAME existente diverge; nao sera sobrescrito automaticamente')
        zone.append({'name':name,'type':'CNAME','ttl':300,'records':[{'content':target}]})
    return zone


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('mode',choices=['validation','traffic'])
    parser.add_argument('state_dir',type=Path)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    os.umask(0o077)
    root=Path(__file__).resolve().parents[1]
    token_file=root/'env/hostinger.token'
    if not token_file.is_file():
        raise RuntimeError('env/hostinger.token ausente; use configuracao DNS manual')
    token_file.chmod(0o600)
    token=token_file.read_text().strip()
    if not token or '\n' in token or '\r' in token:
        raise RuntimeError('Formato invalido de env/hostinger.token')
    def request(method,body=None):
        req=urllib.request.Request(f'https://developers.hostinger.com/api/dns/v1/zones/{DOMAIN}',
            data=json.dumps(body).encode() if body is not None else None,
            headers={'Authorization':'Bearer '+token,'Content-Type':'application/json','Accept':'application/json'},method=method)
        try:
            with urllib.request.urlopen(req,timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f'Hostinger HTTP {e.code}; verifique permissao/token sem publica-lo') from None
        except (urllib.error.URLError,json.JSONDecodeError):
            raise RuntimeError('Hostinger: falha de rede/resposta; nenhuma repeticao de escrita automatica') from None
    if args.mode=='traffic':
        outputs=deployment.check(args.state_dir)
    else:
        env=dict(os.environ,TF_DATA_DIR=str(args.state_dir/'.terraform'),TF_WORKSPACE='default')
        out=subprocess.run(['terraform',f'-chdir={root}/terraform','output','-json'],capture_output=True,text=True,env=env,check=True)
        outputs={k:v['value'] for k,v in json.loads(out.stdout).items()}
        account=deployment.aws('sts','get-caller-identity')['Account']
        if outputs['aws_account_id']!=account or outputs['aws_region']!='us-east-1':
            raise RuntimeError('State diverge da identidade/regiao')
    current=request('GET')
    if not isinstance(current,list):
        raise RuntimeError('Hostinger: formato inesperado da zona; operacao bloqueada')
    zone=build_zone(outputs,args.mode,current)
    if not zone:
        print('[OK] Registros ja correspondem ao destino esperado')
        return
    print(json.dumps({'overwrite':True,'zone':zone},indent=2))
    print('Somente os pares nome/tipo acima serao substituidos; demais registros preservados.')
    if not args.apply:
        print('Simulacao concluida. Use --apply para revisar e confirmar a escrita.')
        return
    if input(f'Digite ATUALIZAR-{args.mode.upper()} para aplicar: ')!=f'ATUALIZAR-{args.mode.upper()}':
        raise RuntimeError('Operacao cancelada')
    if request('GET')!=current:
        raise RuntimeError('Zona mudou durante a revisao; gere novo plano')
    backup=args.state_dir/f'dns-backup-{datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")}.json'
    backup.write_text(json.dumps(current,indent=2))
    # OpenAPI: overwrite afeta somente RRs com mesmo name/type enviados.
    request('PUT',{'overwrite':True,'zone':zone})
    after=request('GET')
    if build_zone(outputs,args.mode,after):
        raise RuntimeError('Hostinger nao refletiu os destinos; confira registros antes de repetir')
    affected={r['name'] for r in zone}
    def unrelated(records):
        return sorted(json.dumps(r,sort_keys=True) for r in records if r['name'].rstrip('.').lower() not in affected and r['name'].rstrip('.').lower() not in {n+'.'+DOMAIN for n in affected})
    if unrelated(current)!=unrelated(after):
        raise RuntimeError('Outros registros mudaram; backup preservado. Revise concorrencia/DNS no painel.')
    print('[OK] Atualizacao recebida e conferida na API; propagacao DNS pode levar tempo.')

if __name__=='__main__':
    try:
        main()
    except (RuntimeError,OSError,subprocess.CalledProcessError,EOFError,KeyError) as e:
        print('[ERRO] '+str(e),file=sys.stderr)
        sys.exit(1)
