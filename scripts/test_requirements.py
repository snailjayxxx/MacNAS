import copy, json, unittest
from verify_requirements import ROOT, validate_ledger, validate_index, validate_additions
class RequirementGuardTests(unittest.TestCase):
    def setUp(self):
        self.ledger=json.loads((ROOT/'docs/planning/v0.6/data/需求总账_v0.6.json').read_text())
        self.index=json.loads((ROOT/'requirements/index.json').read_text())
        self.additions=json.loads((ROOT/'requirements/user-additions.json').read_text())
    def test_priority_reduction_rejected(self):
        self.ledger['features'][0]['effective_priority']='后续需要'
        with self.assertRaises(AssertionError): validate_ledger(self.ledger)
    def test_duplicate_parent_rejected(self):
        self.ledger['features'][1]['id']=self.ledger['features'][0]['id']
        with self.assertRaises(AssertionError): validate_ledger(self.ledger)
    def test_missing_parent_rejected(self):
        self.index['parents'].pop()
        with self.assertRaises(AssertionError):validate_index(self.index,self.ledger)
    def test_missing_status_rejected(self):
        self.index['parents'][0]['children'][0]['status']=''
        with self.assertRaises(AssertionError):validate_index(self.index,self.ledger)
    def test_compound_photo_direction_cannot_disappear(self):
        p=next(p for p in self.index['parents'] if p['id']=='PHO-10');p['children']=[c for c in p['children'] if not c['id'].endswith('.same_person_grouping')]
        with self.assertRaises(AssertionError):validate_index(self.index,self.ledger)
    def test_user_addition_cannot_overwrite_a_baseline_parent(self):
        self.additions['parents'][0]['id']='SYS-01'
        with self.assertRaises(AssertionError):validate_additions(self.additions,self.index)
    def test_user_addition_cannot_disappear_or_lose_provenance(self):
        missing=copy.deepcopy(self.additions);missing['parents']=[]
        with self.assertRaises(AssertionError):validate_additions(missing,self.index)
        self.additions['parents'][0]['user_request']=''
        with self.assertRaises(AssertionError):validate_additions(self.additions,self.index)
    def test_remote_control_cannot_be_promoted_from_the_user_requested_late_phase(self):
        for key,value in [('priority','首版需要'),('schedule','CURRENT'),('phases',['P03'])]:
            changed=copy.deepcopy(self.additions);changed['parents'][0][key]=value
            with self.subTest(key=key),self.assertRaises(AssertionError):validate_additions(changed,self.index)
    def test_added_verification_stages_cannot_be_duplicated_or_removed(self):
        changed=copy.deepcopy(self.additions);changed['parents'][0]['children'][1]=copy.deepcopy(changed['parents'][0]['children'][0])
        with self.assertRaises(AssertionError):validate_additions(changed,self.index)
        self.additions['parents'][0]['children'].pop()
        with self.assertRaises(AssertionError):validate_additions(self.additions,self.index)
if __name__=='__main__':unittest.main()
