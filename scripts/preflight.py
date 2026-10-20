#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

def aws(*args):
    r = subprocess.run(['aws', *args, '--region', 'us-east-1', '--output', 'json', '--no-cli-pager'], capture_output=True, text=True)
    if r.returncode:
        sys.exit('Preflight: consulta AWS falhou; confira permissoes e conectividade (' + ' '.join(args[:2]) + ')')
    return json.loads(r.stdout)

state = Path(sys.argv[1])
resources = json.loads(state.read_text()).get('resources', []) if state.exists() else []
if not any(x.get('mode') == 'managed' for x in resources):
    lbs = aws('elbv2','describe-load-balancers')['LoadBalancers']
    ecr = aws('ecr','describe-repositories')['repositories']
    clusters = aws('ecs','list-clusters')['clusterArns']
    groups = aws('ec2','describe-security-groups')['SecurityGroups']
    logs = aws('logs','describe-log-groups','--log-group-name-prefix','/ecs/fixa-')['logGroups']
    if any(x['LoadBalancerName']=='fixa-alb' for x in lbs) or any(x['repositoryName'].startswith('fixa/') for x in ecr) or any(x.endswith('/cluster-fixa') for x in clusters) or any(x['GroupName'] in ['fixa-alb', *['fixa-'+a+'-api' for a in ('mobile','web','nosql','ia')]] for x in groups) or logs:
        sys.exit('Recursos FIXA existentes sem State correspondente. Nenhum import automatico. Use outra conta ou recupere o State correto.')
# Evita adotar por engano um bucket de outro State, inclusive em apply parcial.
if not any(r.get('mode')=='managed' and (r.get('type'), r.get('name')) in {('aws_s3_bucket','firebase'),('terraform_data','firebase_bucket')} for r in resources):
    account=aws('sts','get-caller-identity')['Account']
    probe=subprocess.run(['aws','s3api','head-bucket','--bucket',f'fixa-secrets-{account}-us-east-1','--expected-bucket-owner',account,'--region','us-east-1','--no-cli-pager'],capture_output=True,text=True)
    if probe.returncode==0:
        sys.exit('Bucket Firebase ja existe sem ser gerenciado por este State; recupere o State correto.')
    if '(404)' not in probe.stderr and '(NotFound)' not in probe.stderr and '(NoSuchBucket)' not in probe.stderr:
        sys.exit('Nao foi possivel comprovar ausencia do bucket Firebase; confira permissao S3/rede antes do deploy.')
vpcs = aws('ec2','describe-vpcs','--filters','Name=is-default,Values=true')['Vpcs']
if len(vpcs) != 1:
    sys.exit('VPC padrao ausente; crie/defina a rede antes do deploy.')
vpc = vpcs[0]['VpcId']
subnets = aws('ec2','describe-subnets','--filters','Name=vpc-id,Values='+vpc)['Subnets']
by_az = {}
for s in subnets:
    by_az.setdefault(s['AvailabilityZone'], []).append(s['SubnetId'])
if len(by_az) < 2:
    sys.exit('Necessario ao menos duas AZs.')
tables = aws('ec2','describe-route-tables','--filters','Name=vpc-id,Values='+vpc)['RouteTables']
for az in sorted(by_az)[:2]:
    subnet = sorted(by_az[az])[0]
    explicit = [t for t in tables if any(a.get('SubnetId')==subnet for a in t['Associations'])]
    table = explicit or [t for t in tables if any(a.get('Main') for a in t['Associations'])]
    if not table or not any(r.get('DestinationCidrBlock')=='0.0.0.0/0' and r.get('GatewayId','').startswith('igw-') and r.get('State')=='active' for r in table[0]['Routes']):
        sys.exit('Subnet selecionada sem rota ativa para Internet Gateway: '+subnet)
print('[OK] Sem conflitos novos; subnets selecionadas com rota publica.')
