import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('checker',Path(__file__).resolve().parents[1]/'scripts/check-deployment.py')
checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)

class DeploymentTests(unittest.TestCase):
    def run_check(self, rollback=False,tls=0):
        apis=['mobile','web','nosql','ia']
        outputs={'aws_account_id':'123456789012','aws_region':'us-east-1','ecs_cluster_arn':'cluster','alb_dns':'new-alb',
                 'api_services':{a:{'service':a,'host':a+'.fixa.solutions','target_group':a} for a in apis}}
        def aws(*args):
            if args[0]=='sts': return {'Account':'123456789012'}
            if args[0]=='elbv2': return {'TargetHealthDescriptions':[{'TargetHealth':{'State':'healthy'}}]}
            a=args[-1]
            return {'services':[{'desiredCount':1,'runningCount':1,'pendingCount':0,'deployments':[
                {'taskDefinition':('old' if rollback else a),'rolloutState':'COMPLETED'}]}]}
        def run(args,**kwargs):
            if args[0]=='terraform':
                return subprocess.CompletedProcess(args,0,json.dumps({k:{'value':v} for k,v in outputs.items()}),'')
            self.assertIn('--connect-to',args)
            self.assertNotIn('-k',args)
            return subprocess.CompletedProcess(args,tls,'200' if tls==0 else '000','')
        with tempfile.TemporaryDirectory() as d:
            Path(d,'terraform.tfstate').write_text(json.dumps({'resources':[
                {'type':'aws_ecs_task_definition','instances':[{'attributes':{'family':f'fixa-{a}-api','arn':a}}]} for a in apis]}))
            with patch.object(checker,'aws',aws),patch.object(checker.subprocess,'run',run):
                return checker.check(d,timeout=0)
    def test_healthy_new_tasks_and_tls(self):
        self.assertEqual(len(self.run_check()['api_services']),4)
    def test_rollback_to_old_tasks_is_failure(self):
        with self.assertRaises(RuntimeError): self.run_check(rollback=True)
    def test_tls_error_blocks_success(self):
        with self.assertRaises(RuntimeError): self.run_check(tls=60)

if __name__=='__main__': unittest.main()
