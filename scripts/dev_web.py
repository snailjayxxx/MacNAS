#!/usr/bin/env python3
"""No-dependency N-011 code/model checks. Browser verification is a separate, explicit evidence stage."""
import datetime,hashlib,json,os,plistlib,re,shutil,subprocess,sys,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=ROOT.parent
expected=json.loads((WORK/'Evidence/environment.json').read_text())
actual=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/Volumes/MacNAS-Dev']))
assert actual['VolumeUUID']==expected['volume_uuid'] and actual['FilesystemType']=='apfs' and not actual['Internal']
node=shutil.which('node');assert node,'Existing Node.js required; no automatic installation'
runid=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime('%Y%m%dT%H%M%S')+'-'+uuid.uuid4().hex[:8]
evidence=WORK/'Evidence/web-runs'/runid;evidence.mkdir(parents=True)
paths=sorted([p for p in (ROOT/'web').rglob('*') if p.is_file() and p.suffix in ['.html','.css','.js','.svg','.cjs']]+[ROOT/'scripts'/name for name in ['dev_web.py','preview_web.py','test_web.py','verify_requirements.py','test_requirements.py']])
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
(evidence/'source-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n')
results=[];outcome='PASS'
def run(name,command):
    result=subprocess.run(command,cwd=ROOT,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
    (evidence/(name+'.log')).write_text(result.stdout)
    results.append({'name':name,'command':command,'exit_code':result.returncode,'log':str((evidence/(name+'.log')).relative_to(WORK))})
    print(name+(': PASS' if result.returncode==0 else ': FAIL'),flush=True)
    if result.returncode:print(result.stdout);raise RuntimeError(name)
try:
    for name in ['model.js','recycle-observation.js','bridge-client.js','task-pages.js','notification-view.js','notification-reconciliation.js','directory-view.js','file-browser.js','file-operations.js','sha256.js','file-transfers.js','file-transfer-view.js','file-copies.js','file-copy-fixture.js','file-copy-view.js','i18n.js','desktop.js']:run('syntax-'+name,[node,'--check','web/dist/'+name])
    run('model-tests',[node,'--test','web/tests/model.test.cjs','web/tests/bridge.test.cjs','web/tests/client.test.cjs','web/tests/task-pages.test.cjs','web/tests/notification-view.test.cjs','web/tests/directory-pages.test.cjs','web/tests/directory-view.test.cjs','web/tests/event-consumer-status.test.cjs','web/tests/notification-reconciliation.test.cjs','web/tests/file-browser.test.cjs','web/tests/file-operations.test.cjs','web/tests/file-transfers.test.cjs','web/tests/file-transfer-view.test.cjs','web/tests/file-copy-model.test.cjs','web/tests/file-copies.test.cjs','web/tests/file-copy-view.test.cjs','web/tests/schema4-compatibility.test.cjs','web/tests/recycle-observation.test.cjs','web/tests/recycle-observation-client.test.cjs'])
    run('static-http-policy-tests',['/usr/bin/python3','scripts/test_web.py'])
    run('requirements',['/usr/bin/python3','scripts/verify_requirements.py'])
    run('requirements-negative-tests',['/usr/bin/python3','scripts/test_requirements.py'])
    baseline_path=next(path for path in [ROOT/'docs/evidence/n029-c3a-2026-10-17.json',ROOT/'docs/evidence/n029-c2-2026-10-16.json',ROOT/'docs/evidence/n029-b2-2026-10-16.json',ROOT/'docs/evidence/n029-b-2026-10-16.json',ROOT/'docs/evidence/n029-a-2026-10-16.json',ROOT/'docs/evidence/n027-2026-10-16.json',ROOT/'docs/evidence/n025-n026-2026-10-16.json',ROOT/'docs/evidence/n024-2026-10-16.json',ROOT/'docs/evidence/n022-2026-10-16.json',ROOT/'docs/evidence/n021-2026-10-15.json',ROOT/'docs/evidence/n020-2026-10-15.json',ROOT/'docs/evidence/n019-2026-10-15.json',ROOT/'docs/evidence/n016-2026-10-15.json',ROOT/'docs/evidence/n015-2026-10-15.json',ROOT/'docs/evidence/n014-2026-10-15.json',ROOT/'docs/evidence/n012-n013-2026-10-15.json',ROOT/'docs/evidence/n010-2026-10-15.json'] if path.exists())
    baseline_report=json.loads(baseline_path.read_text())
    baseline=baseline_report['source_sha256']
    core={name:digest for name,digest in baseline.items() if name=='Package.swift' or name.startswith(('Sources/','Tests/','database/'))}
    actual_core={'Package.swift'}|{str(p.relative_to(ROOT)) for folder in ['Sources','Tests','database'] for p in (ROOT/folder).rglob('*') if p.is_file() and p.suffix in ['.swift','.sql']}
    assert actual_core==set(core),'Core source set changed; latest full regression receipt is required'
    assert core and all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in core.items()),'Core or tests changed; latest full regression receipt is required'
    dependencies=baseline_report.get('core_full_regression',{}).get('embedded_node_pipe_dependencies',{})
    if baseline_report.get('task')=='N-019':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','scripts/test_directory_bridge.cjs'},'Embedded pipe dependency receipt is required'
    if baseline_report.get('task')=='N-020':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','web/dist/directory-view.js','scripts/test_directory_bridge.cjs'},'All refreshed embedded pipe dependencies are required'
        prior=json.loads((ROOT/'docs/evidence/n019-2026-10-15.json').read_text())
        assert core=={name:digest for name,digest in prior['source_sha256'].items() if name=='Package.swift' or name.startswith(('Sources/','Tests/','database/'))},'Composite regression requires the exact unchanged native baseline'
        regression=baseline_report['core_full_regression']
        assert regression['composition']=={'unchanged_native_tests':204,'refreshed_embedded_pipe_tests':1,'covered_total':205} and regression['new_unfiltered_execution'] is False,'Composite and full executions must remain distinct'
        refresh=baseline_report['directory_pipe_regression']
        assert refresh['status']=='PASS' and refresh['test_filter']=='DirectoryPagePipeTests' and refresh['swift_tests_executed']==1,'Fresh embedded scenario must pass before composite reuse'
    if baseline_report.get('task')=='N-021':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','web/dist/directory-view.js','scripts/test_directory_bridge.cjs'},'Complete embedded pipe dependency receipt is required'
        regression=baseline_report['core_full_regression']
        assert regression['unfiltered'] is True and regression['new_unfiltered_execution'] is True and regression['reused_prior_suite'] is False and regression['swift_tests']==217,'A new complete regression must replace the earlier composite evidence'
    if baseline_report.get('task')=='N-022':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','web/dist/directory-view.js','scripts/test_directory_bridge.cjs'},'Complete embedded pipe dependency receipt is required'
        regression=baseline_report['core_full_regression']
        assert regression['unfiltered'] is True and regression['new_unfiltered_execution'] is True and regression['reused_prior_suite'] is False and regression['swift_tests']==224,'A new complete source-context regression is required'
    if baseline_report.get('task')=='N-024':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','web/dist/directory-view.js','web/dist/file-operations.js','scripts/test_directory_bridge.cjs','scripts/test_file_operations_bridge.cjs'},'Both embedded pipe scenarios and all transitive file-operation dependencies are required'
        regression=baseline_report['core_full_regression']
        assert regression['unfiltered'] is True and regression['new_unfiltered_execution'] is True and regression['reused_prior_suite'] is False and regression['swift_tests']==239,'A fresh complete file-operation regression is required'
    assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in dependencies.items()),'Embedded Node/Swift pipe dependencies changed; rerun that scenario and reconcile the full baseline before reuse'
    if baseline_report.get('task')=='N-025/N-026':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','web/dist/directory-view.js','web/dist/file-operations.js','web/dist/file-transfers.js','web/dist/sha256.js','scripts/test_directory_bridge.cjs','scripts/test_file_operations_bridge.cjs','scripts/test_file_transfers_bridge.cjs'},'All three embedded scenarios and transitive transfer dependencies are required'
        regression=baseline_report['core_full_regression']
        assert regression['unfiltered'] is True and regression['new_unfiltered_execution'] is True and regression['reused_prior_suite'] is False and regression['swift_tests']==253,'A fresh complete transfer regression is required'
    if baseline_report.get('task') in ['N-027','N-029 A','N-029 B','N-029 B2','N-029 C2','N-029 C3A']:
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','web/dist/directory-view.js','web/dist/file-operations.js','web/dist/file-transfers.js','web/dist/sha256.js','web/dist/file-copies.js','web/dist/file-copy-fixture.js','scripts/test_directory_bridge.cjs','scripts/test_file_operations_bridge.cjs','scripts/test_file_transfers_bridge.cjs','scripts/test_file_copy_bridge.cjs'}|({'web/dist/recycle-observation.js','scripts/test_recycle_observation_bridge.cjs'} if baseline_report.get('task') in ['N-029 C2','N-029 C3A'] else set()),'Complete embedded scenarios and all transitive dependencies are required'
        regression=baseline_report['core_full_regression']
        assert regression['unfiltered'] is True and regression['new_unfiltered_execution'] is True and regression['reused_prior_suite'] is False and regression['swift_tests']>253,'Fresh complete copy regression is required'
        run_id=regression['run_id']
        assert len(run_id)==24 and all(c in '0123456789Tabcdef-' for c in run_id),'Invalid run receipt ID'
        receipt_path=WORK/'Evidence/runs'/run_id
        receipt=json.loads((receipt_path/'summary.json').read_text())
        receipt_hashes=json.loads((receipt_path/'source-sha256.json').read_text())
        assert receipt['status']=='PASS' and receipt['test_filter'] is None and receipt['sources_unchanged'] is True,'Raw unfiltered run receipt required'
        assert all(receipt_hashes.get(name)==digest for name,digest in {**core,**dependencies}.items()),'Raw receipts do not match the reported sources'
        test_log=(receipt_path/'swift-tests.log').read_text()
        assert ('Executed '+str(regression['swift_tests'])+' tests, with 0 failures') in test_log,'Reported test total must match raw XCTest output'
        assert any(r['name']=='postgres-stop' and r['exit_code']==0 for r in receipt['results']),'Successful database cleanup receipt required'
        if baseline_report.get('task') in ['N-029 A','N-029 B','N-029 B2','N-029 C2','N-029 C3A']:
            assert regression['swift_tests']>271,'Fresh complete Schema4 journal regression is required'
            if baseline_report.get('task') in ['N-029 B','N-029 B2','N-029 C2','N-029 C3A']:
                assert regression['swift_tests']>323,'Fresh complete recycle executor regression is required'
                assert len(re.findall(r'^Recycle crash proof: ',test_log,re.M))==3,'Three actual recycle SIGKILL scenarios are required'
                if baseline_report.get('task') in ['N-029 B2','N-029 C2','N-029 C3A']:
                    assert regression['swift_tests']>355,'Fresh complete restore regression is required'
                    assert len(re.findall(r'^Restore crash proof: ',test_log,re.M))==3,'Three actual restore SIGKILL scenarios are required'
                    if baseline_report.get('task') in ['N-029 C2','N-029 C3A']:
                        assert regression['swift_tests']>374,'New full observation-bridge regression required'
                        if baseline_report.get('task')=='N-029 C3A': assert regression['swift_tests']>391,'Fresh capacity regression required'
                        assert len(re.findall(r'^Recycle observation pipe proof: ',test_log,re.M))==3,'Three actual empty/small/exact-limit observation pipe proofs required'
            assert regression['complete_core_file_count']==len(core) and regression['source_receipt_count']==len(receipt_hashes),'Complete current raw source coverage required'
            independent=regression.get('independent_cli_pipe_dependencies',{})
            assert set(independent)=={'scripts/test_desktop_bridge.cjs','web/dist/task-pages.js','web/dist/notification-view.js','web/dist/notification-reconciliation.js'},'Schema4 independent typed-reader pipe dependencies required'
            assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest and receipt_hashes.get(name)==digest for name,digest in independent.items()),'Independent Schema4 pipe sources must match the raw full receipt'
            assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest and receipt_hashes.get(name)==digest for name,digest in baseline.items() if name!='scripts/dev_web.py' and (name=='Package.swift' or name.startswith(('Sources/','Tests/','database/','scripts/')))),'All native, SQL, tests and runner sources must match the raw full receipt'
except Exception as error:outcome='FAILED';print(str(error),flush=True)
unchanged=all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items())
if not unchanged:outcome='FAILED'
summary={'run_id':runid,'automated_checks_status':outcome,'browser_verification':'NOT_EXECUTED_SEPARATE_CUA_VERIFICATION_REQUIRED','sources_unchanged':unchanged,'source_receipt':'source-sha256.json','existing_node':subprocess.check_output([node,'--version'],text=True).strip(),'no_listener_started':True,'no_dependencies_installed':True,'synthetic_data':True,'core_regression_evidence':str(baseline_path.relative_to(ROOT)) if 'baseline_path' in globals() else None,'results':results}
(evidence/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print('SUMMARY:',evidence/'summary.json',flush=True)
sys.exit(0 if outcome=='PASS' else 1)
