from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
BASH=shutil.which('bash')
if os.name == 'nt' and shutil.which('git'):
    git_bash=Path(shutil.which('git')).parent.parent/'bin/bash.exe'
    if git_bash.is_file(): BASH=str(git_bash)

def shell_path(path):
    path=Path(path)
    if os.name == 'nt':
        return '/'+path.drive[0].lower()+path.as_posix()[2:]
    return str(path)

@unittest.skipUnless(BASH, 'Build simulado requer Bash')
class BuildTests(unittest.TestCase):
    def test_resume_same_commit_and_refuse_changed_recipe(self):
        for api in ('mobile','web','nosql'):
            with self.subTest(api=api):
                self.check_build(api)

    def test_vfs_cleans_between_stages_and_after_verified_push(self):
        for api in ('mobile','web','nosql','ia'):
            with self.subTest(api=api):
                self.check_build(api,driver='vfs')

    def test_failed_push_preserves_local_images_and_has_no_receipt(self):
        self.check_build('nosql',driver='vfs',fail_push=True)

    def check_build(self,api,driver='overlay2',fail_push=False):
        with tempfile.TemporaryDirectory() as d:
            r=Path(d);(r/'scripts').mkdir();(r/'bin').mkdir();(r/'apps'/api).mkdir(parents=True)
            (r/'apps'/api/'Dockerfile').write_text('FROM scratch\n')
            shutil.copytree(ROOT/'runtime/mobile',r/'runtime/mobile',ignore=shutil.ignore_patterns('__pycache__'))
            shutil.copy(ROOT/'scripts/build-images.sh',r/'scripts/build-images.sh')
            (r/'scripts/sync-repos.sh').write_text('#!/bin/bash\nexit 0\n',newline='\n');(r/'scripts/sync-repos.sh').chmod(0o755)
            programs={
                'git':'echo "${FAKE_COMMIT:-abc}"',
                'docker':'''echo "$*" >> "$CALLS"
case "$1 $2" in
"info --format") echo "$FAKE_DRIVER" ;;
"image rm") [[ -f "$RECEIPT" ]] || exit 90 ;;
esac
if [[ "$1" == push ]]; then
  [[ "${FAKE_PUSH_FAIL:-0}" == 0 ]] || exit 42
  touch "$IMAGE_EXISTS"
fi
cat >/dev/null''',
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
            }
            if os.name == 'nt':
                programs['python3']='exec "'+shell_path(sys.executable)+'" "$@"'
            for name,body in programs.items():
                p=r/'bin'/name;p.write_text('#!/bin/bash\n'+body+'\n',newline='\n');p.chmod(0o755)
            receipt=r/'.states/123456789012/us-east-1/images'/f'{api}-test.json'
            env=dict(os.environ,CALLS=shell_path(r/'calls'),IMAGE_EXISTS=shell_path(r/'image-exists'),
                RECEIPT=shell_path(receipt),FAKE_DRIVER=driver,FAKE_PUSH_FAIL='1' if fail_push else '0')
            def build():
                return subprocess.run([BASH,'-c','export PATH="$1:$PATH"; exec bash "$2" "$3" test',
                    '_',shell_path(r/'bin'),shell_path(r/'scripts/build-images.sh'),api],env=env,capture_output=True,text=True)
            result=build()
            calls=(r/'calls').read_text()
            if fail_push:
                self.assertNotEqual(result.returncode,0)
                self.assertNotIn('image rm',calls)
                self.assertFalse(receipt.exists())
                return
            self.assertEqual(result.returncode,0,result.stderr)
            builds=1 if api=='ia' else 2
            self.assertEqual(calls.count('build --platform'),builds)
            if api!='ia': self.assertIn(shell_path(r/'runtime/mobile'),calls)
            self.assertNotIn(shell_path(r/'env'),calls)
            if driver=='vfs':
                stages=calls.splitlines()
                build_indexes=[i for i,line in enumerate(stages) if line.startswith('build --platform')]
                if api!='ia':
                    self.assertIn('builder prune --all --force',stages[build_indexes[0]+1:build_indexes[1]])
                removals=[line for line in stages if line.startswith('image rm ')]
                self.assertEqual(len(removals),builds)
                self.assertIn('image rm 123456789012.dkr.ecr.us-east-1.amazonaws.com/fixa/'+api+'-api:test',removals)
                if api!='ia': self.assertIn(f'image rm fixa-{api}-build:test',removals)
                self.assertGreater(stages.index(removals[0]),next(i for i,line in enumerate(stages) if line.startswith('push ')))
                self.assertEqual(stages[-1],'builder prune --all --force')
            else:
                self.assertNotIn('image rm',calls)
                self.assertNotIn('builder prune',calls)
            result=build();self.assertEqual(result.returncode,0,result.stderr)
            resumed=(r/'calls').read_text()
            self.assertEqual(resumed.count('build --platform'),builds)
            if driver=='vfs': self.assertGreater(resumed.count('image rm'),calls.count('image rm'))
            env['FAKE_COMMIT']='new'
            self.assertNotEqual(build().returncode,0)
            env.pop('FAKE_COMMIT')
            with (r/'runtime/mobile/entrypoint.py').open('a') as f: f.write('\n# nova receita\n')
            self.assertEqual(build().returncode,0 if api=='ia' else 1)
            self.assertEqual((r/'calls').read_text().count('build --platform'),builds)

if __name__=='__main__': unittest.main()
