from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
class BuildTests(unittest.TestCase):
    def test_resume_same_commit_and_refuse_changed_recipe(self):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);(r/'scripts').mkdir();(r/'bin').mkdir();(r/'apps/mobile').mkdir(parents=True)
            (r/'apps/mobile/Dockerfile').write_text('FROM scratch\n')
            shutil.copytree(ROOT/'runtime/mobile',r/'runtime/mobile',ignore=shutil.ignore_patterns('__pycache__'))
            shutil.copy(ROOT/'scripts/build-images.sh',r/'scripts/build-images.sh')
            (r/'scripts/sync-repos.sh').write_text('#!/bin/bash\nexit 0\n');(r/'scripts/sync-repos.sh').chmod(0o755)
            for name,body in {
                'git':'echo "${FAKE_COMMIT:-abc}"',
                'docker':'echo "$*" >> "$CALLS"\ncase "$1" in push) touch "$IMAGE_EXISTS";; esac\ncat >/dev/null',
                'aws':'''case "$1 $2" in
"sts get-caller-identity") echo 123456789012 ;;
"ecr get-login-password") echo test ;;
"ecr describe-repositories") echo '{}' ;;
"ecr describe-images")
 if [[ -f "$IMAGE_EXISTS" ]]; then
   echo "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
 else
   echo 'An error occurred (ImageNotFoundException)' >&2
   exit 254
 fi ;;
*) exit 1 ;;
esac'''
            }.items():
                p=r/'bin'/name;p.write_text('#!/bin/bash\n'+body+'\n');p.chmod(0o755)
            env=dict(os.environ,PATH=str(r/'bin')+':'+os.environ['PATH'],CALLS=str(r/'calls'),IMAGE_EXISTS=str(r/'image-exists'))
            def build():
                return subprocess.run(['bash',str(r/'scripts/build-images.sh'),'mobile','test'],env=env,capture_output=True,text=True)
            result=build();self.assertEqual(result.returncode,0,result.stderr)
            calls=(r/'calls').read_text()
            self.assertEqual(calls.count('build --platform'),2)
            self.assertIn(str(r/'runtime/mobile'),calls)
            self.assertNotIn(str(r/'env'),calls)
            result=build();self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((r/'calls').read_text().count('build --platform'),2)
            env['FAKE_COMMIT']='new'
            self.assertNotEqual(build().returncode,0)
            env.pop('FAKE_COMMIT')
            with (r/'runtime/mobile/entrypoint.py').open('a') as f: f.write('\n# nova receita\n')
            self.assertNotEqual(build().returncode,0)
            self.assertEqual((r/'calls').read_text().count('build --platform'),2)

if __name__=='__main__': unittest.main()
