#!/usr/bin/env python3
"""Espera o deployment solicitado e testa TLS/SNI no novo ALB sem trocar DNS."""
import json
from pathlib import Path
import subprocess
import sys
import time


def aws(*args):
    r = subprocess.run(['aws', *args, '--region','us-east-1','--output','json','--no-cli-pager'], capture_output=True,text=True)
    if r.returncode:
        raise RuntimeError('Consulta AWS falhou: '+' '.join(args[:2]))
    return json.loads(r.stdout)


def check(directory, timeout=900):
    directory = Path(directory)
    root = Path(__file__).resolve().parents[1]
    import os
    env = dict(os.environ, TF_DATA_DIR=str(directory/'.terraform'), TF_WORKSPACE='default')
    p = subprocess.run(['terraform',f'-chdir={root}/terraform','output','-json'], env=env,capture_output=True,text=True)
    if p.returncode:
        raise RuntimeError('Nao foi possivel ler outputs do State')
    outputs = {k:v['value'] for k,v in json.loads(p.stdout).items()}
    account = aws('sts','get-caller-identity')['Account']
    if outputs['aws_account_id'] != account or outputs['aws_region'] != 'us-east-1':
        raise RuntimeError('State/identidade divergentes')
    services = outputs['api_services']
    if set(services) != {'mobile','web','nosql','ia'}:
        raise RuntimeError('As quatro APIs precisam estar habilitadas')
    cluster = outputs['ecs_cluster_arn']
    # Task desejada vem do Terraform; rollback para versao antiga nao conta como sucesso.
    state = json.loads((directory/'terraform.tfstate').read_text())
    tasks = {}
    for resource in state['resources']:
        if resource['type'] == 'aws_ecs_task_definition':
            for item in resource['instances']:
                attrs=item['attributes']
                tasks[attrs['family']] = attrs['arn']
    deadline=time.monotonic()+timeout
    pending=set(services)
    while pending:
        for api in list(pending):
            config=services[api]
            result=aws('ecs','describe-services','--cluster',cluster,'--services',config['service'])
            if result.get('failures') or not result.get('services'):
                raise RuntimeError(f'{api}: ECS Service nao encontrado')
            s=result['services'][0]
            expected=tasks.get(f'fixa-{api}-api')
            ds=s.get('deployments',[])
            if any(d['taskDefinition']==expected and d.get('rolloutState')=='FAILED' for d in ds):
                raise RuntimeError(f'{api}: deployment solicitado falhou; consulte eventos ECS e /ecs/fixa-{api}-api')
            ready=(s['desiredCount']>0 and s['runningCount']==s['desiredCount'] and s['pendingCount']==0
                   and len(ds)==1 and ds[0]['taskDefinition']==expected
                   and ds[0].get('rolloutState')=='COMPLETED')
            if ready:
                targets=aws('elbv2','describe-target-health','--target-group-arn',config['target_group'])['TargetHealthDescriptions']
                ready=bool(targets) and all(t['TargetHealth']['State']=='healthy' for t in targets)
            if ready:
                path='/api/v1/health' if api=='ia' else '/actuator/health'
                # --connect-to muda somente destino TCP; URL preserva Host, SNI e verificacao TLS.
                curl=subprocess.run(['curl','--silent','--show-error','--noproxy','*','--connect-timeout','10',
                    '--max-time','20','--output','/dev/null','--write-out','%{http_code}',
                    '--connect-to',f"{config['host']}:443:{outputs['alb_dns']}:443",f"https://{config['host']}{path}"],capture_output=True,text=True)
                if curl.returncode==0 and curl.stdout=='200':
                    print(f'[OK] {api}: ECS + Target Group + HTTPS no novo ALB',flush=True)
                    pending.remove(api)
        if pending:
            if time.monotonic()>=deadline:
                raise RuntimeError('Timeout aguardando: '+', '.join(sorted(pending))+'. Consulte eventos ECS e logs CloudWatch; valores de logs nao sao impressos automaticamente.')
            print('Aguardando: '+', '.join(sorted(pending)),flush=True)
            time.sleep(15)
    return outputs

if __name__=='__main__':
    try:
        check(sys.argv[1])
    except (RuntimeError, KeyError, OSError) as e:
        print('[ERRO] '+str(e),file=sys.stderr)
        sys.exit(1)
