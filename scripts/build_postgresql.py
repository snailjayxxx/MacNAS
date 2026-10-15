#!/usr/bin/env python3
"""Reproduce the user-approved PostgreSQL 18 development build inside the verified SSD."""
import hashlib,json,os,plistlib,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=ROOT.parent
expected=json.loads((WORK/'Evidence/environment.json').read_text())
actual=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/Volumes/MacNAS-Dev']))
assert actual['VolumeUUID']==expected['volume_uuid'] and actual['FilesystemType']=='apfs' and not actual['Internal'],'BLOCKED: wrong development volume'
assert ROOT.resolve()==ROOT and ROOT.is_relative_to(Path('/Volumes/MacNAS-Dev'))
VERSION='18.6';DIGEST='555610c24d53e4316da5b7d3fc25c279d96856d5e0e23ee308c328c5fa881d9f'
parent=WORK/'Build/postgresql';parent.mkdir(parents=True,exist_ok=True)
archive=parent/f'postgresql-{VERSION}.tar.bz2'
base=f'https://ftp.postgresql.org/pub/source/v{VERSION}/'
if not archive.exists():subprocess.run(['/usr/bin/curl','--fail','--location','--proto','=https','--tlsv1.2','--output',archive,base+archive.name],check=True)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==DIGEST,'official source digest mismatch'
prefix=parent/f'install-{VERSION}-macos15';source_parent=parent/'macos15-source';source=source_parent/f'postgresql-{VERSION}';build=parent/'build-macos15'
if not source.exists():
    source_parent.mkdir(exist_ok=True)
    with tarfile.open(archive) as stream:
        for item in stream.getmembers():assert not Path(item.name).is_absolute() and '..' not in Path(item.name).parts and (item.isfile() or item.isdir())
        stream.extractall(source_parent)
build.mkdir(exist_ok=True)
env=dict(os.environ,CC='/usr/bin/clang',CFLAGS='-O2 -mmacosx-version-min=15.0',LDFLAGS='-mmacosx-version-min=15.0',MACOSX_DEPLOYMENT_TARGET='15.0')
configure=[str(source/'configure'),'--prefix='+str(prefix),'--without-icu','--without-readline','--without-zlib','--without-lz4','--without-zstd','--disable-nls']
for name,command in [('configure',configure),('build',['/usr/bin/make','-j4']),('install',['/usr/bin/make','install'])]:
    log=WORK/'Evidence'/('postgresql-macos15-'+name+'.log')
    with log.open('w') as output:result=subprocess.run(command,cwd=build,env=env,stdout=output,stderr=subprocess.STDOUT)
    if result.returncode:raise SystemExit(f'{name} failed; see {log}')
    print(name+': PASS',flush=True)
print(subprocess.check_output([prefix/'bin/postgres','--version'],text=True))
