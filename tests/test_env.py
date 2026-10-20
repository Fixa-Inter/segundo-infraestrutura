import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from env_config import ConfigError, parse_env, validate
spec=importlib.util.spec_from_file_location('sync_secrets',ROOT/'scripts/sync-secrets.py')
sync=importlib.util.module_from_spec(spec);spec.loader.exec_module(sync)

class EnvTests(unittest.TestCase):
    def test_literal_values_no_shell_execution(self):
        self.assertEqual(parse_env('export A="a=b # c"\nB=literal # comment\nC=abc#def'),{'A':'a=b # c','B':'literal','C':'abc#def'})
        for bad in ['A=$(touch /tmp/never)','A=${B}','A=`echo secret`']:
            with self.assertRaises(ConfigError): parse_env(bad)

    def test_json_formats(self):
        obj={'private_key':'line1\nline2','project_id':'x'}
        for text in ['A='+json.dumps(obj,indent=2), "A='"+json.dumps(obj,indent=2)+"'"]:
            self.assertEqual(json.loads(parse_env(text)['A']),obj)
        self.assertEqual(parse_env('A="one\\ntwo"')['A'],'one\ntwo')

    def test_invalid_no_values_in_errors(self):
        for bad in ['A=SECRET\nA=SECRET','A="SECRET','malformed SECRET']:
            with self.assertRaises(ConfigError) as err: parse_env(bad)
            self.assertNotIn('SECRET',str(err.exception))

    def test_byte_limit_and_local_host(self):
        for values in [{'KEY':'é'*2049},{'DATABASE_URL_GESTOR':'postgresql://user:SECRET@localhost/db'}]:
            with self.assertRaises(ConfigError) as err: validate('ia',values,{'required':[]})
            self.assertNotIn('SECRET',str(err.exception))
        self.assertEqual(validate('ia',{'KEY':'é'*2048},{'required':[]})['KEY'],'é'*2048)

    def test_required_aliases(self):
        c={'required':['SPRING_DATASOURCE_URL'],'aliases':{'DB_URL':'SPRING_DATASOURCE_URL'}}
        self.assertIn('SPRING_DATASOURCE_URL',validate('web',{'DB_URL':'jdbc:postgresql://db.example/db'},c))
        with self.assertRaises(ConfigError): validate('web',{'DB_URL':'x','SPRING_DATASOURCE_URL':'y'},c)
        with self.assertRaises(ConfigError): validate('web',{},c)

    def test_mobile_path_is_not_json(self):
        with self.assertRaises(ConfigError): validate('mobile',{'FIREBASE_CREDENTIALS_PATH':'{}'},{'required':[]})
        v=validate('mobile',{'FIREBASE_CREDENTIALS_PATH':'/app/secrets/firebase.json'},{'required':[]})
        self.assertEqual(v['FIREBASE_CREDENTIALS_PATH'],'/app/secrets/firebase.json')
        with self.assertRaises(ConfigError):
            validate('mobile',{'FIREBASE_CREDENTIALS_PATH':'/app/secrets/firebase.json','FIREBASE_CREDENTIALS_JSON':'{}'},{'required':[]})

    def test_sync_only_refs_and_unchanged_is_idempotent(self):
        secret='SENTINEL_NOT_FOR_MANIFEST'
        calls=[]
        def fake_aws(*args,payload=None):
            calls.append((args,payload))
            if args[0]=='sts': return {'Account':'123456789012'}
            if args[1]=='get-parameter': return {'Parameter':{'Value':secret,'Version':7,'Type':'SecureString'}}
            self.fail('Unnecessary write to SSM')
        with tempfile.TemporaryDirectory() as d, patch.object(sync,'ROOT',Path(d)), patch.object(sync,'aws',fake_aws), patch.object(sync,'load_all',return_value={'ia':{'API_KEY':secret}}), patch.object(sys,'argv',['sync-secrets.py','ia']):
            sync.main()
            files=list(Path(d).rglob('*.json'))
            self.assertEqual(len(files),3)
            for f in files:
                self.assertNotIn(secret,f.read_text())
                self.assertEqual(f.stat().st_mode & 0o777,0o600)
            refs=json.loads(next(Path(d).rglob('ia.secrets.json')).read_text())
            self.assertEqual(refs['API_KEY'],'arn:aws:ssm:us-east-1:123456789012:parameter/fixa/ia/API_KEY')

    def test_mobile_path_and_project_are_public_not_ssm(self):
        values={'FIREBASE_CREDENTIALS_PATH':'/app/secrets/firebase.json','FIREBASE_PROJECT_ID':'test-project','DB_PASSWORD':'SENTINEL'}
        queried=[]
        def aws(*args,payload=None):
            if args[0]=='sts': return {'Account':'123456789012'}
            queried.append(args)
            return {'Parameter':{'Value':'SENTINEL','Type':'SecureString','Version':1}}
        with tempfile.TemporaryDirectory() as d,patch.object(sync,'ROOT',Path(d)),patch.object(sync,'aws',aws),patch.object(sync,'load_all',return_value={'mobile':values}),patch.object(sys,'argv',['sync-secrets.py','mobile']):
            sync.main()
            p=Path(d)/'.states/123456789012/us-east-1/env'
            public=json.loads((p/'mobile.public.json').read_text())
            self.assertEqual(public['FIREBASE_CREDENTIALS_PATH'],'/app/secrets/firebase.json')
            refs=json.loads((p/'mobile.secrets.json').read_text())
            self.assertEqual(set(refs),{'DB_PASSWORD'})
            self.assertEqual(len(queried),1)
            for f in p.iterdir():
                self.assertNotIn('SENTINEL',f.read_text())

    def test_aws_errors_do_not_echo_payload(self):
        from subprocess import CompletedProcess
        with patch.object(sync.subprocess,'run',return_value=CompletedProcess([],1,'','An error occurred (AccessDeniedException): SECRET')):
            with self.assertRaises(ConfigError) as err: sync.aws('ssm','put-parameter',payload={'Value':'SECRET'})
            self.assertNotIn('SECRET',str(err.exception))

if __name__=='__main__': unittest.main()
