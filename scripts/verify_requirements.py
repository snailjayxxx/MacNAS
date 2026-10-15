#!/usr/bin/env python3
"""Verify immutable planning provenance and the full 111-parent execution index."""
import collections, csv, hashlib, json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {'首版需要': 97, '后续需要': 13, '暂不需要': 1}
STATUSES = {'NOT_STARTED','IN_PROGRESS','MOCK_PASS','LOCAL_MAC_PASS','CROSS_MAC_PASS','PHYSICAL_POOL_PASS','BLOCKED','FAILED','ACCEPTED'}
def validate_ledger(ledger):
    features = ledger['features']
    assert len(features) == 111, 'parent count must remain 111'
    assert len({x['id'] for x in features}) == 111, 'duplicate parent ID'
    assert dict(collections.Counter(x['effective_priority'] for x in features)) == EXPECTED, '97/13/1 priorities changed'
    assert next(x for x in features if x['id']=='MIG-05')['effective_priority']=='首版需要', 'MIG-05 missing'
def validate_index(index, ledger):
    parents = index['parents']; source = {x['id']:x for x in ledger['features']}
    assert len(parents)==111 and {x['id'] for x in parents}==set(source), 'execution index parent coverage mismatch'
    ids=set()
    for p in parents:
        assert p['priority']==source[p['id']]['effective_priority'], p['id']+' priority mismatch'
        assert p['status'] in STATUSES, p['id']+' missing status'
        assert p['phases'], p['id']+' missing phase'
        assert len(p['children'])>=7, p['id']+' missing verification stages'
        for child in p['children']:
            assert child['id'].startswith(p['id']+'.') and child['id'] not in ids, 'invalid/duplicate child '+child['id']
            ids.add(child['id'])
            assert child['status'] in STATUSES and isinstance(child['evidence'],list), child['id']+' missing state/evidence'
    for parent, suffixes in {'PHO-10':['visual_similarity','same_person_grouping','OCR','natural_language_image_retrieval'], 'MED-06':['download_application','camera_recording_playback','home_and_file_automation']}.items():
        assert all(parent+'.'+s in ids for s in suffixes), parent+' compound requirement lost'
def validate_additions(additions,index):
    assert additions['schema']=='macnas-user-requirement-additions/v1' and additions['baseline']=='v0.6' and additions['baseline_parent_count']==111, 'addition provenance mismatch'
    parents=additions['parents'];seen={p['id'] for p in index['parents']};children=set()
    assert isinstance(parents,list), 'additions must be a list'
    for p in parents:
        assert re.fullmatch(r'[A-Z]{3}-[0-9]{2}',p['id']) and p['id'] not in seen, 'duplicate or invalid added parent ID'
        seen.add(p['id'])
        assert p['priority'] in EXPECTED and p['status'] in STATUSES, 'addition priority/status missing'
        assert p['phases'] and all(isinstance(x,str) and x for x in p['phases']), 'addition phase missing'
        assert all(isinstance(p.get(k),str) and p[k].strip() for k in ['name','requested_on','request_source','user_request','user_priority_instruction','scope','schedule']), 'explicit user provenance missing'
        assert re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}',p['requested_on']), 'addition request date missing'
        assert isinstance(p['evidence'],list) and p['evidence'], 'addition plan missing'
        assert len(p['children'])>=7, 'addition verification stages missing'
        for child in p['children']:
            assert child['id'].startswith(p['id']+'.') and child['id'] not in children, 'invalid/duplicate added child'
            children.add(child['id'])
            assert child['status'] in STATUSES and isinstance(child['evidence'],list), 'addition child state/evidence missing'
        assert all(p['id']+'.'+suffix in children for suffix in ['design','implementation','automated_tests','owner_acceptance']), 'addition verification coverage missing'
        if p['id']=='SYS-09':
            assert p['priority']=='后续需要' and p['schedule']=='VERY_LATE' and p['phases']==['FUTURE'], 'user remote-control requirement must remain very late'
    assert 'SYS-09' in {p['id'] for p in parents}, 'user remote-control addition lost'
def verify(root=ROOT):
    plan=root/'docs/planning/v0.6'
    sums=json.loads((plan/'CHECKSUMS.json').read_text())
    for item in sums['files']:
        content=(plan/item['path']).read_bytes()
        assert len(content)==item['size_bytes'] and hashlib.sha256(content).hexdigest()==item['sha256'], 'original changed: '+item['path']
    ledger=json.loads((plan/'data/需求总账_v0.6.json').read_text());validate_ledger(ledger)
    for name,digest in ledger['source_uploads'].items():
        assert hashlib.sha256((plan/'sources/originals'/name).read_bytes()).hexdigest()==digest, 'source hash mismatch: '+name
    with (plan/'data/需求追踪_v0.6.csv').open(encoding='utf-8-sig',newline='') as file: rows=list(csv.DictReader(file))
    assert len(rows)==111 and {x['requirement_id'] for x in rows}=={x['id'] for x in ledger['features']}, 'CSV coverage mismatch'
    byid={x['id']:x['effective_priority'] for x in ledger['features']}
    assert all(x['user_priority']==byid[x['requirement_id']] for x in rows), 'CSV priority mismatch'
    index=json.loads((root/'requirements/index.json').read_text());validate_index(index,ledger)
    additions=json.loads((root/'requirements/user-additions.json').read_text());validate_additions(additions,index)
    for parent in additions['parents']:
        for reference in parent['evidence']:
            path=Path(reference)
            assert not path.is_absolute() and '..' not in path.parts and (root/path).is_file(), 'addition plan reference missing or unsafe'
    # Live sources must not link or implement the explicitly rejected database engine.
    forbidden=('CSQLite','import SQLite','sqlite3_','.sqlite')
    for file in list((root/'Sources').rglob('*'))+[root/'Package.swift']:
        if file.is_file():
            text=file.read_text()
            assert not any(marker in text for marker in forbidden), 'rejected database runtime in '+str(file.relative_to(root))
    effective=collections.Counter(EXPECTED);effective.update(p['priority'] for p in additions['parents'])
    return {'status':'PASS','original_files_verified':len(sums['files']),'original_sources_verified':len(ledger['source_uploads']),'parent_count':111,'priority_counts':EXPECTED,'child_count':sum(len(x['children']) for x in index['parents']),'additional_parent_count':len(additions['parents']),'effective_parent_count':111+len(additions['parents']),'effective_priority_counts':dict(effective),'additional_child_count':sum(len(p['children']) for p in additions['parents']),'database':'PostgreSQL 18, no fallback'}
if __name__=='__main__':
    try: print(json.dumps(verify(),ensure_ascii=False,indent=2))
    except (AssertionError,KeyError,ValueError,OSError) as error:
        print('FAIL: '+str(error),file=sys.stderr);sys.exit(1)
