import copy, json, unittest
from verify_requirements import ROOT, validate_ledger, validate_index
class RequirementGuardTests(unittest.TestCase):
    def setUp(self):
        self.ledger=json.loads((ROOT/'docs/planning/v0.6/data/需求总账_v0.6.json').read_text())
        self.index=json.loads((ROOT/'requirements/index.json').read_text())
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
if __name__=='__main__':unittest.main()
