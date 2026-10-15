#!/usr/bin/env python3
"""No-dependency N-011 code/model checks. Browser verification is a separate, explicit evidence stage."""
import datetime,hashlib,json,os,plistlib,shutil,subprocess,sys,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=ROOT.parent
expected=json.loads((WORK/'Evidence/environment.json').read_text())
actual=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/Volumes/MacNAS-Dev']))
assert actual['VolumeUUID']==expected['volume_uuid'] and actual['FilesystemType']=='apfs' and not actual['Internal']
node=shutil.which('node');assert node,'Existing Node.js required; no automatic installation'
runid=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime('%Y%m%dT%H%M%S')+'-'+uuid.uuid4().hex[:8]
evidence=WORK/'Evidence/web-runs'/runid;evidence.mkdir(parents=True)
paths=sorted([p for p in (ROOT/'web').rglob('*') if p.is_file() and p.suffix in ['.html','.css','.js','.svg','.cjs']]+[ROOT/'scripts'/name for name in ['dev_web.py','preview_web.py','test_web.py']])
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
    for name in ['model.js','bridge-client.js','task-pages.js','notification-view.js','i18n.js','desktop.js']:run('syntax-'+name,[node,'--check','web/dist/'+name])
    run('model-tests',[node,'--test','web/tests/model.test.cjs','web/tests/bridge.test.cjs','web/tests/client.test.cjs','web/tests/task-pages.test.cjs','web/tests/notification-view.test.cjs','web/tests/directory-pages.test.cjs'])
    run('static-http-policy-tests',['/usr/bin/python3','scripts/test_web.py'])
    run('requirements',['/usr/bin/python3','scripts/verify_requirements.py'])
    run('requirements-negative-tests',['/usr/bin/python3','scripts/test_requirements.py'])
    baseline_path=next(path for path in [ROOT/'docs/evidence/n019-2026-10-15.json',ROOT/'docs/evidence/n016-2026-10-15.json',ROOT/'docs/evidence/n015-2026-10-15.json',ROOT/'docs/evidence/n014-2026-10-15.json',ROOT/'docs/evidence/n012-n013-2026-10-15.json',ROOT/'docs/evidence/n010-2026-10-15.json'] if path.exists())
    baseline_report=json.loads(baseline_path.read_text())
    baseline=baseline_report['source_sha256']
    core={name:digest for name,digest in baseline.items() if name=='Package.swift' or name.startswith(('Sources/','Tests/','database/'))}
    actual_core={'Package.swift'}|{str(p.relative_to(ROOT)) for folder in ['Sources','Tests','database'] for p in (ROOT/folder).rglob('*') if p.is_file() and p.suffix in ['.swift','.sql']}
    assert actual_core==set(core),'Core source set changed; latest full regression receipt is required'
    assert core and all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in core.items()),'Core or tests changed; latest full regression receipt is required'
    dependencies=baseline_report.get('core_full_regression',{}).get('embedded_node_pipe_dependencies',{})
    if baseline_report.get('task')=='N-019':
        assert set(dependencies)=={'web/dist/model.js','web/dist/bridge-client.js','scripts/test_directory_bridge.cjs'},'Embedded pipe dependency receipt is required'
    assert all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in dependencies.items()),'Embedded Node/Swift pipe dependencies changed; rerun that scenario and reconcile the full baseline before reuse'
except Exception as error:outcome='FAILED';print(str(error),flush=True)
unchanged=all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in hashes.items())
if not unchanged:outcome='FAILED'
summary={'run_id':runid,'automated_checks_status':outcome,'browser_verification':'NOT_EXECUTED_SEPARATE_CUA_VERIFICATION_REQUIRED','sources_unchanged':unchanged,'source_receipt':'source-sha256.json','existing_node':subprocess.check_output([node,'--version'],text=True).strip(),'no_listener_started':True,'no_dependencies_installed':True,'synthetic_data':True,'core_regression_evidence':str(baseline_path.relative_to(ROOT)) if 'baseline_path' in globals() else None,'results':results}
(evidence/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print('SUMMARY:',evidence/'summary.json',flush=True)
sys.exit(0 if outcome=='PASS' else 1)
