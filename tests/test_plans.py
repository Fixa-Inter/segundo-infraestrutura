import json
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]

class PlanTests(unittest.TestCase):
    def run_plan(self, resource_type, actions):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'scripts').mkdir();(p/'bin').mkdir()
            shutil.copy(ROOT/'scripts/common.sh',p/'scripts/common.sh')
            tool=p/'bin/terraform';tool.write_text('''#!/bin/bash
case "$*" in
*"show -json"*) echo "$PLAN_JSON" ;;
*"apply -input"*) touch "$APPLIED" ;;
esac
''');tool.chmod(0o755)
            env=dict(os.environ,PATH=str(p/'bin')+':'+os.environ['PATH'],APPLIED=str(p/'applied'),
                     PLAN_JSON=json.dumps({'resource_changes':[{'type':resource_type,'change':{'actions':actions}}]}))
            run=subprocess.run(['bash','-c',f'source "{p}/scripts/common.sh"; STATE_DIR="{p}"; RUNTIME="{p}/runtime"; ACCOUNT_ID=123456789012; plan_apply test'],input='sim\n',text=True,capture_output=True,env=env)
            return run.returncode,(p/'applied').exists()
    def test_infrastructure_replacement_is_blocked(self):
        code,applied=self.run_plan('aws_lb',['delete','create'])
        self.assertNotEqual(code,0);self.assertFalse(applied)
    def test_task_revision_is_allowed(self):
        code,applied=self.run_plan('aws_ecs_task_definition',['create','delete'])
        self.assertEqual(code,0);self.assertTrue(applied)

if __name__=='__main__': unittest.main()
