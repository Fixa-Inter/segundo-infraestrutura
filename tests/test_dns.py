import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('dns',Path(__file__).resolve().parents[1]/'scripts/hostinger-dns.py')
dns=importlib.util.module_from_spec(spec);spec.loader.exec_module(dns)

class DnsTests(unittest.TestCase):
    def outputs(self):
        return {'api_hostnames':{a:f'{a}-api.fixa.solutions' for a in ['mobile','web','nosql','ia']},'alb_dns':'new.elb.amazonaws.com',
        'acm_validation_records':[{'name':'_token.fixa.solutions.','type':'CNAME','value':'_value.acm-validations.aws.'}]*2}
    def test_validation_deduplicates_wildcard(self):
        zone=dns.build_zone(self.outputs(),'validation',[])
        self.assertEqual(len(zone),1)
        self.assertEqual(zone[0]['name'],'_token')
    def test_traffic_plan_contains_only_api_cnames(self):
        current=[{'name':'@','type':'MX','records':[{'content':'mail.example'}]}]
        zone=dns.build_zone(self.outputs(),'traffic',current)
        self.assertEqual(len(zone),4)
        self.assertTrue(all(r['type']=='CNAME' and r['name'].endswith('-api') for r in zone))
        self.assertEqual(current[0]['type'],'MX')
    def test_conflicting_type_fails(self):
        with self.assertRaises(RuntimeError):
            dns.build_zone(self.outputs(),'traffic',[{'name':'web-api','type':'A','records':[{'content':'1.2.3.4'}]}])
    def test_idempotence(self):
        zone=dns.build_zone(self.outputs(),'traffic',[])
        self.assertEqual(dns.build_zone(self.outputs(),'traffic',zone),[])
    def test_no_overwrite_different_acm(self):
        current=[{'name':'_token','type':'CNAME','records':[{'content':'old.acm-validations.aws.'}]}]
        with self.assertRaises(RuntimeError): dns.build_zone(self.outputs(),'validation',current)

if __name__=='__main__': unittest.main()
