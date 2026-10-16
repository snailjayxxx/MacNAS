#!/usr/bin/env python3
"""Guarded, isolated development build/test. Only synthetic data; no TCP or system services."""
import base64, datetime, hashlib, json, os, plistlib, re, shutil, signal, subprocess, sys, tempfile, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=ROOT.parent
expected=json.loads((WORK/'Evidence/environment.json').read_text())
actual=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/Volumes/MacNAS-Dev']))
assert actual['VolumeUUID']==expected['volume_uuid'] and actual['MountPoint']=='/Volumes/MacNAS-Dev' and actual['FilesystemType']=='apfs' and not actual['Internal'], 'BLOCKED: development volume identity changed'
assert ROOT.is_relative_to(Path('/Volumes/MacNAS-Dev')) and ROOT.resolve()==ROOT, 'BLOCKED: unsafe project path'
dev_build_namespace=os.environ.get('MACNAS_DEV_BUILD_NAMESPACE','')
assert dev_build_namespace in ['', 'n029-c2', 'n029-c3b'], 'Unknown development build namespace'
def dev_build_dir(name): return WORK/'Build'/(name+('-'+dev_build_namespace if dev_build_namespace else ''))
runid=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9))).strftime('%Y%m%dT%H%M%S')+'-'+uuid.uuid4().hex[:8]
evidence=WORK/'Evidence/runs'/runid; evidence.mkdir(parents=True)
lab=WORK/'TestLab'/runid;lab.mkdir()
demo=WORK/'DeploySandbox'/runid;demo.mkdir()
pgbin=WORK/'Build/postgresql/install-18.6-macos15/bin';assert (pgbin/'postgres').is_file(),'PostgreSQL 18.6 build missing'
socket=Path(tempfile.mkdtemp(prefix='macnas-pg-',dir='/private/tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('PG')}
env.update({'MACNAS_TESTLAB':str(lab),'MACNAS_PG_BIN':str(pgbin),'MACNAS_PG_SOCKET':str(socket),
 'CLANG_MODULE_CACHE_PATH':str(dev_build_dir('clang-module-cache')),'SWIFTPM_MODULECACHE_OVERRIDE':str(dev_build_dir('swift-module-cache')),
 'LC_ALL':'C','LANG':'C','HOME':str(socket)})
node=shutil.which('node');assert node,'Existing Node.js required; no automatic installation'
env['MACNAS_NODE_BINARY']=node
flags=['--scratch-path',str(dev_build_dir('swift')),'--cache-path',str(dev_build_dir('swift-cache')),'--config-path',str(dev_build_dir('swift-config')),'--security-path',str(dev_build_dir('swift-security'))]
tracked_sources=[ROOT/'Package.swift',ROOT/'web/dist/model.js',ROOT/'web/dist/recycle-observation.js',ROOT/'web/dist/bridge-client.js',ROOT/'web/dist/task-pages.js',ROOT/'web/dist/notification-view.js',ROOT/'web/dist/notification-reconciliation.js',ROOT/'web/dist/directory-view.js',ROOT/'web/dist/file-operations.js',ROOT/'web/dist/file-transfers.js',ROOT/'web/dist/sha256.js',ROOT/'web/dist/file-copies.js',ROOT/'web/dist/file-copy-fixture.js']+[p for folder in ['Sources','Tests','database','scripts'] for p in (ROOT/folder).rglob('*') if p.is_file() and p.suffix in ['.swift','.sql','.py','.cjs']]
source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(tracked_sources)}
(evidence/'source-sha256.json').write_text(json.dumps(source_hashes,indent=2)+'\n')
git_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
git_branch=subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip()
git_status=subprocess.check_output(['git','status','--porcelain=v1'],cwd=ROOT,text=True)
results=[];started=False

def run(name,command,input=None,check=True,expected_exit=0):
    log=evidence/(name+'.log')
    print(name+': running',flush=True)
    with log.open('w') as output:
        process=subprocess.Popen([str(c) for c in command],cwd=ROOT,env=env,stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,text=True,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        # C2 full measured5589.763s plus C3A new31 measured641.912s.
        # New physical native30 measured3061.190s; focused new cases/Schema6
        # add further bounded work. Bound456 tests to180 minutes with I/O margin.
        # Product/SQL/client/CLI and individual functional deadlines are unchanged.
        try:process.communicate(input=input,timeout=10800 if name=='swift-tests' else 420)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGTERM)
            try:process.communicate(timeout=5)
            except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.communicate()
            raise RuntimeError(name+' timed out; test process group terminated')
        result=process
    text=log.read_text(errors='replace')
    results.append({'name':name,'command':[str(c) for c in command],'exit_code':result.returncode,'expected_exit':expected_exit,'log':str(log.relative_to(WORK))})
    print(name+(': PASS' if result.returncode==expected_exit else ': FAIL'),flush=True)
    if result.returncode!=expected_exit:
        print('\n'.join(text.splitlines()[-30:]),flush=True)
        if check:raise RuntimeError(name+' failed')
    return text
try:
    run('requirements',['/usr/bin/python3','scripts/verify_requirements.py'])
    run('requirements-negative-tests',['/usr/bin/python3','scripts/test_requirements.py'])
    run('swift-build',['/usr/bin/swift','build']+flags)
    binary=Path(subprocess.check_output(['/usr/bin/swift','build']+flags+['--show-bin-path'],cwd=ROOT,env=env,text=True).strip());env['MACNAS_BINARY_DIR']=str(binary)
    keys=json.loads(subprocess.check_output([str(binary/'macnas'),'fixture','signing-key'],env=env,text=True))
    env['MACNAS_TEST_EXPORT_SIGNING_KEY']=keys['private'];env['MACNAS_TRUSTED_EXPORT_PUBLIC_KEY']=keys['public']
    (evidence/'synthetic-export-public-key.txt').write_text(keys['public']+'\n')
    cluster=lab/'postgresql'
    run('postgres-initdb',[pgbin/'initdb','-D',cluster,'--username=macnas_test_admin','--encoding=UTF8','--locale=C','--auth-local=trust','--auth-host=reject'])
    # The only listener is a private, short Unix socket path. TCP listen_addresses is empty.
    options="-k "+str(socket)+" -p 55432 -c listen_addresses='' -c max_connections=20 -c shared_buffers=32MB -c unix_socket_permissions=0700"
    run('postgres-start',[pgbin/'pg_ctl','-D',cluster,'--wait','--timeout=20','-l',evidence/'postgres-server.log','-o',options,'start']);started=True
    psql=[pgbin/'psql','-X','--host',socket,'--port','55432','--username','macnas_test_admin','--dbname','postgres','--set','ON_ERROR_STOP=1']
    run('postgres-test-role',psql,input='CREATE ROLE macnas_test_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;\n')
    run('postgres-runtime',psql,input="SELECT version(); SHOW listen_addresses; SHOW unix_socket_directories;\n")
    test_filter=env.get('MACNAS_TEST_FILTER')
    run('swift-tests',['/usr/bin/swift','test']+flags+(['--filter',test_filter] if test_filter else []))
    run('capabilities',[binary/'macnas','capabilities'])
    source=demo/'源实例';export=demo/'portable-export';target=demo/'移動後の实例'
    run('demo-create',[binary/'macnas','fixture','create','--dest',source])
    run('demo-preview',[binary/'macnas','migrate','preview','--source',source])
    run('demo-export',[binary/'macnas','migrate','export','--source',source,'--dest',export])
    run('demo-doctor',[binary/'macnas','doctor','--portable',export])
    run('demo-restore-preview',[binary/'macnas','migrate','restore','--source',export,'--dest',target])
    assert not target.exists(),'preview unexpectedly created destination'
    run('demo-restore',[binary/'macnas','migrate','restore','--source',export,'--dest',target,'--confirm-create','--host-id','mock-new-mac'])
    run('demo-idempotent-retry',[binary/'macnas','migrate','restore','--source',export,'--dest',target,'--confirm-create','--host-id','mock-new-mac'])
    run('demo-journal-status',[binary/'macnas','migrate','status','--dest',target])
    upgraded=demo/'Schema2-只读实例'
    run('demo-upgrade-preview',[binary/'macnas','migrate','upgrade','--source',source,'--dest',upgraded])
    assert not upgraded.exists(),'upgrade preview unexpectedly created destination'
    run('demo-upgrade',[binary/'macnas','migrate','upgrade','--source',source,'--dest',upgraded,'--confirm-create','--host-id','mock-upgrade-mac'])
    run('demo-upgrade-doctor',[binary/'macnas','doctor','--portable',upgraded])
    run('demo-upgrade-retry',[binary/'macnas','migrate','upgrade','--source',source,'--dest',upgraded,'--confirm-create','--host-id','mock-upgrade-mac'])
    run('demo-rollback-preview',[binary/'macnas','migrate','rollback','--dest',upgraded])
    run('demo-rollback',[binary/'macnas','migrate','rollback','--dest',upgraded,'--confirm'])
    upgraded3=demo/'Schema3-readonly'
    run('demo-schema3-upgrade',[binary/'macnas','migrate','upgrade','--source',upgraded,'--dest',upgraded3,'--target-schema','3','--confirm-create','--host-id','mock-schema3'])
    upgraded4=demo/'Schema4-readonly'
    run('demo-schema4-upgrade',[binary/'macnas','migrate','upgrade','--source',upgraded3,'--dest',upgraded4,'--target-schema','4','--confirm-create','--host-id','mock-schema4'])
    run('demo-schema4-doctor',[binary/'macnas','doctor','--portable',upgraded4])
    run('demo-schema4-retry',[binary/'macnas','migrate','upgrade','--source',upgraded3,'--dest',upgraded4,'--target-schema','4','--confirm-create','--host-id','mock-schema4'])
    run('demo-schema4-rollback',[binary/'macnas','migrate','rollback','--dest',upgraded4,'--confirm'])
    jobs4=demo/'schema4-durable-jobs'
    run('demo-schema4-create',[binary/'macnas','fixture','create','--dest',jobs4,'--schema','4'])
    run('demo-schema4-jobs',[binary/'macnas','jobs','demo','--source',jobs4])
    jobs4_export=demo/'schema4-jobs-export';jobs4_restore=demo/'schema4-jobs-restore'
    run('demo-schema4-export',[binary/'macnas','migrate','export','--source',jobs4,'--dest',jobs4_export])
    run('demo-schema4-restore',[binary/'macnas','migrate','restore','--source',jobs4_export,'--dest',jobs4_restore,'--confirm-create','--host-id','mock-schema4-restore'])
    denied_worker4=run('schema4-readonly-worker-refusal',[binary/'macnas','jobs','work-once','--source',jobs4_restore],expected_exit=1)
    assert 'denied' in denied_worker4,'restored Schema4 worker should refuse'
    upgraded5=demo/'Schema5-readonly'
    run('demo-schema5-upgrade',[binary/'macnas','migrate','upgrade','--source',upgraded4,'--dest',upgraded5,'--target-schema','5','--confirm-create','--host-id','mock-schema5'])
    run('demo-schema5-doctor',[binary/'macnas','doctor','--portable',upgraded5])
    run('demo-schema5-retry',[binary/'macnas','migrate','upgrade','--source',upgraded4,'--dest',upgraded5,'--target-schema','5','--confirm-create','--host-id','mock-schema5'])
    run('demo-schema5-rollback',[binary/'macnas','migrate','rollback','--dest',upgraded5,'--confirm'])
    jobs5=demo/'schema5-durable-jobs'
    run('demo-schema5-create',[binary/'macnas','fixture','create','--dest',jobs5,'--schema','5'])
    run('demo-schema5-jobs',[binary/'macnas','jobs','demo','--source',jobs5])
    jobs5_export=demo/'schema5-jobs-export';jobs5_restore=demo/'schema5-jobs-restore'
    run('demo-schema5-export',[binary/'macnas','migrate','export','--source',jobs5,'--dest',jobs5_export])
    run('demo-schema5-restore',[binary/'macnas','migrate','restore','--source',jobs5_export,'--dest',jobs5_restore,'--confirm-create','--host-id','mock-schema5-restore'])
    denied_worker5=run('schema5-readonly-worker-refusal',[binary/'macnas','jobs','work-once','--source',jobs5_restore],expected_exit=1)
    assert 'denied' in denied_worker5,'restored Schema5 worker should refuse'
    upgraded6=demo/'Schema6-readonly'
    run('demo-schema6-upgrade',[binary/'macnas','migrate','upgrade','--source',upgraded5,'--dest',upgraded6,'--target-schema','6','--confirm-create','--host-id','mock-schema6'])
    run('demo-schema6-doctor',[binary/'macnas','doctor','--portable',upgraded6])
    run('demo-schema6-retry',[binary/'macnas','migrate','upgrade','--source',upgraded5,'--dest',upgraded6,'--target-schema','6','--confirm-create','--host-id','mock-schema6'])
    run('demo-schema6-rollback',[binary/'macnas','migrate','rollback','--dest',upgraded6,'--confirm'])
    jobs6=demo/'schema6-durable-jobs'
    run('demo-schema6-create',[binary/'macnas','fixture','create','--dest',jobs6,'--schema','6'])
    run('demo-schema6-jobs',[binary/'macnas','jobs','demo','--source',jobs6])
    jobs6_export=demo/'schema6-jobs-export';jobs6_restore=demo/'schema6-jobs-restore'
    run('demo-schema6-export',[binary/'macnas','migrate','export','--source',jobs6,'--dest',jobs6_export])
    run('demo-schema6-restore',[binary/'macnas','migrate','restore','--source',jobs6_export,'--dest',jobs6_restore,'--confirm-create','--host-id','mock-schema6-restore'])
    denied_worker5=run('schema6-readonly-worker-refusal',[binary/'macnas','jobs','work-once','--source',jobs6_restore],expected_exit=1)
    assert 'denied' in denied_worker5,'restored Schema6 worker should refuse'
    jobs=demo/'durable-jobs'
    run('demo-jobs-create',[binary/'macnas','fixture','create','--dest',jobs,'--schema','3'])
    run('demo-jobs-work-and-ack',[binary/'macnas','jobs','demo','--source',jobs])
    run('demo-jobs-idempotent',[binary/'macnas','jobs','demo','--source',jobs])
    run('demo-jobs-idle',[binary/'macnas','jobs','work-once','--source',jobs])
    jobs_export=demo/'jobs-export';jobs_restore=demo/'jobs-restore'
    run('demo-jobs-export',[binary/'macnas','migrate','export','--source',jobs,'--dest',jobs_export])
    run('demo-jobs-restore',[binary/'macnas','migrate','restore','--source',jobs_export,'--dest',jobs_restore,'--confirm-create','--host-id','mock-jobs-restore'])
    denied_worker=run('readonly-worker-refusal',[binary/'macnas','jobs','work-once','--source',jobs_restore],expected_exit=1)
    assert 'denied' in denied_worker,'restored worker should refuse'
    storage_demo=json.loads(run('storage-and-file-synthetic-demo',[binary/'macnas','storage','demo','--source',jobs]))
    assert storage_demo['source']=='synthetic' and storage_demo['relativeFiles']==['README.txt']
    assert storage_demo['boundState']=='readyReadOnly' and storage_demo['readerDeniedBeforeGrant'] and storage_demo['missingAfterDisconnect'] and storage_demo['rebindRequiredAfterReturn']
    refused_storage=run('readonly-storage-binding-refusal',[binary/'macnas','storage','demo','--source',jobs_restore],expected_exit=1)
    assert 'denied' in refused_storage
    assert not (jobs_restore/'host-binding/fixtures').exists(),'read-only demo must not create fixture directories'
    node=shutil.which('node');assert node,'Existing Node.js required; no automatic installation'
    env['MACNAS_BRIDGE_TEST_ROOT']=str(demo/'bridge-protocol');env['MACNAS_BRIDGE_READONLY_ROOT']=str(jobs_restore)
    run('desktop-bridge-pipe-integration',[node,'--test','scripts/test_desktop_bridge.cjs'])
    run('photo-synthetic-smoke',[binary/'macnas','photo-smoke','--dest',demo/'synthetic-photo-smoke'],check=False)
    denied=run('cutover-refusal',[binary/'macnas','migrate','cutover'],expected_exit=1)
    assert 'unsupported' in denied,'cutover should refuse'
    outcome='PASS'
except Exception as error:
    outcome='FAILED';print(str(error),flush=True)
finally:
    if started:
        try:run('postgres-stop',[pgbin/'pg_ctl','-D',cluster,'--wait','--timeout=20','--mode=fast','stop'])
        except Exception as error:outcome='FAILED';print('PostgreSQL cleanup failed: '+str(error),flush=True)
    if not started or not (lab/'postgresql/postmaster.pid').exists():shutil.rmtree(socket)
    summary={'run_id':runid,'status':outcome,'os':expected['os'],'architecture':'arm64','build_namespace':dev_build_namespace,'swift_scratch':str(dev_build_dir('swift')),'database':'PostgreSQL 18.6','database_transport':'private Unix socket only; TCP disabled','synthetic_data':True,'cross_mac':'NOT_EXECUTED','physical_pool':'BLOCKED_NO_DESTROYABLE_TEST_DISKS','macOS15_runtime':'NOT_EXECUTED','source_base':git_head,'bootstrap_lineage':'e05b3d7e3acbeb447f10c2f5f27a64be332be6f5','branch':git_branch,'working_tree_status_at_start':git_status,'commit':git_head,'test_filter':env.get('MACNAS_TEST_FILTER'),'source_receipt':'source-sha256.json','sources_unchanged':all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in source_hashes.items()),'results':results}
    (evidence/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print('SUMMARY:',evidence/'summary.json',flush=True)
    print('STATUS:',outcome,flush=True)
if outcome!='PASS':sys.exit(1)
