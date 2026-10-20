import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from env_config import ConfigError
from firebase_config import mobile_firebase,read_firebase

def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
    return m
uploader=module('uploader',ROOT/'scripts/upload-firebase.py')
entry=module('entry',ROOT/'runtime/mobile/entrypoint.py')
cleanup=module('cleanup',ROOT/'scripts/cleanup-firebase.py')


def fixture():
    return json.dumps({'type':'service_account','project_id':'test-project','client_email':'test@example.invalid',
        'private_key':'-----BEGIN PRIVATE KEY-----\nTEST_SENTINEL\n-----END PRIVATE KEY-----'}).encode()

class FirebaseTests(unittest.TestCase):
    def test_local_file_and_project(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'firebase.json';p.write_bytes(fixture())
            raw,project,digest=mobile_firebase({'FIREBASE_CREDENTIALS_PATH':'/app/secrets/firebase.json'},p)
            self.assertEqual(project,'test-project')
            self.assertEqual(digest,hashlib.sha256(raw).hexdigest())
            self.assertEqual(p.stat().st_mode&0o777,0o600)
            with self.assertRaises(ConfigError):
                mobile_firebase({'FIREBASE_CREDENTIALS_PATH':'/app/secrets/firebase.json','FIREBASE_PROJECT_ID':'other'},p)
    def test_missing_file_and_invalid_json_hide_contents(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'firebase.json'
            with self.assertRaises(ConfigError): read_firebase(p)
            p.write_text('TEST_SENTINEL')
            with self.assertRaises(ConfigError) as e: read_firebase(p)
            self.assertNotIn('TEST_SENTINEL',str(e.exception))
    def upload_fake(self,public=True,existing=False):
        import base64
        raw=fixture();digest=hashlib.sha256(raw).hexdigest();calls=[]
        check=base64.b64encode(bytes.fromhex(digest)).decode()
        uploaded=[existing]
        def aws(*args,payload=None):
            calls.append(args)
            if args[0]=='sts': return {'Account':'123456789012'}
            op=args[1]
            if op=='get-public-access-block':
                return {'PublicAccessBlockConfiguration':{k:public for k in ['BlockPublicAcls','BlockPublicPolicy','IgnorePublicAcls','RestrictPublicBuckets']}}
            if op=='get-bucket-encryption': return {'ServerSideEncryptionConfiguration':{'Rules':[{'ApplyServerSideEncryptionByDefault':{'SSEAlgorithm':'AES256'}}]}}
            if op=='head-object':
                if not uploaded[0]: raise ConfigError('AWS: 404')
                return {'ChecksumSHA256':check,'ContentLength':len(raw)}
            if op=='put-object':
                p=Path(args[args.index('--body')+1]);self.assertEqual(p.read_bytes(),raw)
                self.assertEqual(p.stat().st_mode&0o777,0o600)
                self.assertIn('--if-none-match',args)
                uploaded[0]=True
                return {}
            self.fail('Unexpected operation '+op)
        with tempfile.TemporaryDirectory() as d,patch.object(uploader,'ROOT',Path(d)),patch.object(uploader.sync,'aws',aws):
            state=Path(d)/'.states/123456789012/us-east-1';state.mkdir(parents=True)
            out={'aws_account_id':'123456789012','aws_region':'us-east-1','firebase_bucket':'fixa-secrets-123456789012-us-east-1'}
            with patch.object(uploader,'outputs',return_value=out):
                if not public:
                    with self.assertRaises(ConfigError): uploader.upload(state,raw,'test-project',digest)
                    self.assertFalse(any(c[1]=='put-object' for c in calls if len(c)>1))
                    return
                uploader.upload(state,raw,'test-project',digest)
                text=(state/'env/mobile.firebase.json').read_text()
                self.assertNotIn('TEST_SENTINEL',text)
                self.assertIn('FIREBASE_S3_BUCKET',text)
        return calls
    def test_upload_validates_privacy_and_checksum(self): self.upload_fake()
    def test_existing_object_is_not_uploaded_again(self):
        calls=self.upload_fake(existing=True)
        self.assertFalse(any(c[1]=='put-object' for c in calls if len(c)>1))
    def test_public_bucket_blocks_upload(self): self.upload_fake(public=False)
    def test_runtime_downloads_private_file(self):
        raw=fixture();digest=hashlib.sha256(raw).hexdigest()
        class S3:
            def get_object(inner,**kwargs):
                self.assertEqual(kwargs['ExpectedBucketOwner'],'123456789012')
                return {'Body':io.BytesIO(raw)}
        with tempfile.TemporaryDirectory() as d:
            target=str(Path(d)/'secrets/firebase.json')
            env={'FIREBASE_CREDENTIALS_PATH':target,'FIREBASE_S3_BUCKET_OWNER':'123456789012','FIREBASE_CREDENTIALS_SHA256':digest,
                'FIREBASE_S3_BUCKET':'fixa-secrets-123456789012-us-east-1','FIREBASE_S3_KEY':f'firebase/{digest}.json','FIREBASE_PROJECT_ID':'test-project'}
            with patch.object(entry,'CREDENTIAL_PATH',target): entry.prepare_firebase(env,S3())
            self.assertEqual(Path(target).read_bytes(),raw)
            self.assertEqual(Path(target).stat().st_mode&0o777,0o600)
            env['FIREBASE_CREDENTIALS_SHA256']='b'*64;env['FIREBASE_S3_KEY']='firebase/'+'b'*64+'.json'
            with patch.object(entry,'CREDENTIAL_PATH',target),self.assertRaises(RuntimeError): entry.prepare_firebase(env,S3())
    def test_cleanup_requires_explicit_flag_and_rejects_other_files(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'terraform.tfstate').write_text(json.dumps({'resources':[{'mode':'managed','type':'aws_s3_bucket','name':'firebase','instances':[{'attributes':{'bucket':'fixa-secrets-123456789012-us-east-1'}}]}]}))
            calls=[]
            def aws(*args,payload=None):
                calls.append(args)
                if args[0]=='sts': return {'Account':'123456789012'}
                if args[1]=='list-object-versions': return {'Versions':[{'Key':'unexpected.txt','VersionId':'null'}]}
                self.fail('Deletion must not happen')
            with patch.object(cleanup.sync,'aws',aws):
                with self.assertRaises(ConfigError): cleanup.clean(p,False)
                with self.assertRaises(ConfigError): cleanup.clean(p,True)

if __name__=='__main__': unittest.main()
