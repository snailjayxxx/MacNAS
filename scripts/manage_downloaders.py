#!/usr/bin/env python3
"""Prepare and manage MacNAS-owned native downloader bundles; never launch them.

The offline cache is part of the prepared distribution. Installation receipts
are local packaging metadata, separate from the PostgreSQL business database.
No system Applications directory, launch agent, account or network setting is
changed. All commands require an explicit managed root.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

CATALOG = Path(__file__).resolve().parents[1] / 'packages/downloaders.json'
SCHEMA = 'macnas-downloader-install/v1'


class PackageError(Exception):
    pass


def require(value, message):
    if not value:
        raise PackageError(message)


def digest(path):
    with path.open('rb') as stream:
        result = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()


def safe_path(path):
    """Reject symlink ancestors, including an existing final component."""
    path = Path(os.path.abspath(path))
    for component in [*reversed(path.parents), path]:
        require(not component.is_symlink(), 'symlinkPath')
    return path


def regular(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'invalidFile')


def run(arguments):
    try:
        result = subprocess.run(arguments, stdin=subprocess.DEVNULL,
                                capture_output=True, check=True, timeout=180)
        return result.stdout
    except (subprocess.SubprocessError, OSError) as error:
        raise PackageError('packageToolFailed: ' + Path(arguments[0]).name) from error


def write_json(path, value):
    """Atomic receipt replacement, with a private unpredictable staging file."""
    descriptor, temporary = tempfile.mkstemp(prefix='.receipt-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_catalog():
    catalog = json.loads(CATALOG.read_text(encoding='utf-8'))
    require(catalog['schema'] == 'macnas-bundled-downloaders/v1', 'invalidCatalog')
    packages = catalog['packages']
    require([p['id'] for p in packages] == ['qbittorrent', 'transmission'], 'invalidCatalog')
    for package in packages:
        require(package['bundled_by_default'] is True and package['removable'] is True,
                'invalidCatalog')
        require(all('/' not in package[key] and package[key] not in ['', '.', '..']
                    for key in ['id', 'archive', 'app_name', 'executable']), 'invalidCatalog')
    return catalog, {p['id']: p for p in packages}


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        host = parsed.hostname or ''
        require(parsed.scheme == 'https' and (host == 'github.com' or
                host.endswith('.githubusercontent.com') or host.endswith('.sourceforge.net')),
                'untrustedDownloadRedirect')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def fetch_cache(directory):
    """Release-build download only; normal install/reinstall stays offline."""
    directory = safe_path(directory)
    directory.mkdir(mode=0o700, parents=False, exist_ok=True)
    _, packages = load_catalog()
    opener = urllib.request.build_opener(HTTPSRedirect())
    for package in packages.values():
        destination = directory / package['archive']
        if destination.exists():
            verify_archive(destination, package)
            continue
        descriptor, temporary = tempfile.mkstemp(prefix='.download-', dir=directory)
        try:
            started = time.monotonic(); total = 0
            request = urllib.request.Request(package['download_url'], headers={'User-Agent':'MacNAS-package-builder/1'})
            with os.fdopen(descriptor, 'wb') as output, opener.open(request, timeout=30) as response:
                require(urllib.parse.urlsplit(response.url).scheme == 'https', 'untrustedDownloadRedirect')
                while True:
                    require(time.monotonic() - started < 300, 'downloadTimedOut')
                    block = response.read(1024 * 1024)
                    if not block: break
                    total += len(block); require(total <= 200 * 1024 * 1024, 'archiveTooLarge')
                    output.write(block)
                output.flush(); os.fsync(output.fileno())
            verify_archive(Path(temporary), package)
            # Refuse replacement rather than overwriting another cache writer.
            os.link(temporary, destination)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    return [{'id':p['id'], 'version':p['version'], 'sha256':digest(directory/p['archive'])} for p in packages.values()]


def verify_archive(path, package):
    regular(path)
    require(digest(path) == package['sha256'], 'archiveChecksumMismatch')


def verify_app(app, package):
    """Inspect metadata, containment, architecture and signature without executing."""
    require(app.is_dir() and not app.is_symlink(), 'missingApp')
    resolved = app.resolve()
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            item = Path(directory) / name
            require(item.resolve().is_relative_to(resolved), 'bundleLinkEscape')
            info = item.lstat()
            require(stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or
                    (stat.S_ISREG(info.st_mode) and info.st_nlink == 1), 'invalidBundleFile')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == package['bundle_id'] and
            info.get('CFBundleShortVersionString') == package['version'] and
            info.get('CFBundleExecutable') == package['executable'], 'bundleIdentityMismatch')
    executable = app / 'Contents/MacOS' / package['executable']
    regular(executable)
    run(['/usr/bin/lipo', str(executable), '-verify_arch', 'arm64'])
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])


def extract_app(archive, destination, package):
    """Read-only DMG mount, copying only the named app, preserving its signature."""
    # DiskImages cannot mount at this external development volume's private
    # staging directory. Use a private local temporary copy of the already
    # pinned public archive; the installed application stays in the owned root.
    with tempfile.TemporaryDirectory(prefix='macnas-downloader-', dir='/private/tmp') as temporary:
        local_archive = Path(temporary) / package['archive']
        shutil.copyfile(archive, local_archive)
        verify_archive(local_archive, package)
        mount = Path(temporary) / 'mount'
        mount.mkdir()
        attached = False
        try:
            run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                 '-mountpoint', str(mount), str(local_archive)])
            attached = True
            source = mount / package['app_name']
            verify_app(source, package)
            run(['/usr/bin/ditto', str(source), str(destination)])
            verify_app(destination, package)
        finally:
            if attached:
                run(['/usr/bin/hdiutil', 'detach', str(mount)])


class DownloaderPackages:
    def __init__(self, root):
        self.root = safe_path(root)
        self.catalog, self.packages = load_catalog()
        self.catalog_sha = hashlib.sha256(CATALOG.read_bytes()).hexdigest()

    def package(self, identity):
        require(identity in self.packages, 'unknownPackage')
        return self.packages[identity]

    @contextlib.contextmanager
    def locked(self):
        require(self.root.is_dir(), 'notInitialized')
        safe_path(self.root)
        flags = os.O_RDWR | os.O_NOFOLLOW
        descriptor = os.open(self.root / '.package-lock', flags)
        try:
            info = os.fstat(descriptor)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, 'invalidLock')
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            regular(self.root / 'receipt.json')
            receipt = json.loads((self.root / 'receipt.json').read_text())
            require(receipt.get('schema') == SCHEMA and
                    receipt.get('catalog_sha256') == self.catalog_sha and
                    set(receipt.get('packages', {})) == set(self.packages), 'invalidReceipt')
            for folder in ['installed', 'offline-cache', 'data', 'work']:
                path = safe_path(self.root / folder)
                require(path.is_dir(), 'invalidLayout')
            yield receipt
        finally:
            os.close(descriptor)

    def initialize(self, cache):
        """Seed both defaults once; an existing installation is never reseeded."""
        require(not self.root.exists(), 'alreadyInitialized')
        require(self.root.parent.is_dir(), 'missingParent')
        cache = safe_path(cache)
        for package in self.packages.values():
            verify_archive(cache / package['archive'], package)
        temporary = Path(tempfile.mkdtemp(prefix='.downloaders-', dir=self.root.parent))
        try:
            for name in ['installed', 'offline-cache', 'data', 'work']:
                (temporary / name).mkdir(mode=0o700)
            (temporary / '.package-lock').touch(mode=0o600)
            receipt = {'schema': SCHEMA, 'catalog_sha256': self.catalog_sha, 'packages': {}}
            for identity, package in self.packages.items():
                cached = temporary / 'offline-cache' / package['archive']
                shutil.copyfile(cache / package['archive'], cached)
                verify_archive(cached, package)
                home = temporary / 'installed' / identity
                home.mkdir()
                extract_app(cached, home / package['app_name'], package)
                (temporary / 'data' / identity).mkdir(mode=0o700)
                receipt['packages'][identity] = {'state': 'installed', 'version': package['version']}
            write_json(temporary / 'catalog.json', self.catalog)
            write_json(temporary / 'receipt.json', receipt)
            (temporary / 'NOTICE.txt').write_text('\n\n'.join(
                p['name'] + ' ' + p['version'] + '\n' + p['license'] + '\n' +
                p['license_source'] + '\nSource: ' + p['source_url']
                for p in self.packages.values()) + '\n', encoding='utf-8')
            # rename does not replace a preexisting nonempty directory. Refuse
            # even an empty destination rather than merging with user content.
            require(not self.root.exists(), 'destinationAppeared')
            os.rename(temporary, self.root)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        return self.status()

    def status(self):
        with self.locked() as receipt:
            result = []
            for identity, package in self.packages.items():
                location = safe_path(self.root / 'installed' / identity)
                present = location.is_dir()
                state = receipt['packages'][identity]['state']
                require(state in ['installed', 'removed'], 'invalidReceipt')
                result.append({'id': identity, 'name': package['name'],
                               'version': package['version'], 'bundled': True,
                               'removable': True, 'state': state if present == (state == 'installed') else 'needsRepair',
                               'data_preserved': True, 'auto_start': False})
            return result

    def install(self, identity):
        package = self.package(identity)
        with self.locked() as receipt:
            target = safe_path(self.root / 'installed' / identity)
            if target.exists():
                require(receipt['packages'][identity]['state'] == 'installed', 'unexpectedPackageDirectory')
                verify_app(target / package['app_name'], package)
                return
            archive = self.root / 'offline-cache' / package['archive']
            verify_archive(archive, package)
            with tempfile.TemporaryDirectory(prefix='install-', dir=self.root / 'work') as temporary:
                prepared = Path(temporary) / identity
                prepared.mkdir()
                extract_app(archive, prepared / package['app_name'], package)
                os.rename(prepared, target)
            receipt['packages'][identity] = {'state': 'installed', 'version': package['version']}
            write_json(self.root / 'receipt.json', receipt)

    def uninstall(self, identity):
        package = self.package(identity)
        with self.locked() as receipt:
            target = safe_path(self.root / 'installed' / identity)
            if target.exists():
                # No killing processes. Reject files held open by an active app.
                result = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(target)],
                                        capture_output=True, timeout=30)
                require(result.returncode in [0, 1] and not result.stdout.strip(), 'appRunning')
                require(set(p.name for p in target.iterdir()) == {package['app_name']}, 'unexpectedPackageContent')
                with tempfile.TemporaryDirectory(prefix='remove-', dir=self.root / 'work') as temporary:
                    os.rename(target, Path(temporary) / identity)
                    receipt['packages'][identity]['state'] = 'removed'
                    write_json(self.root / 'receipt.json', receipt)
            else:
                receipt['packages'][identity]['state'] = 'removed'
                write_json(self.root / 'receipt.json', receipt)
            # The data directory, download destinations and offline cache are
            # deliberately outside the only directory removed above.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True, help='Explicit MacNAS-owned package root')
    sub = parser.add_subparsers(dest='command', required=True)
    init = sub.add_parser('init', help='Prepare a new distribution with both downloaders installed')
    init.add_argument('--cache', type=Path, required=True, help='Directory containing the two verified official DMGs')
    fetch = sub.add_parser('fetch-cache', help='Download the two pinned official DMGs for an offline distribution')
    fetch.add_argument('--cache', type=Path, required=True)
    sub.add_parser('status')
    for name in ['install', 'uninstall']:
        child = sub.add_parser(name)
        child.add_argument('package', choices=['qbittorrent', 'transmission'])
    args = parser.parse_args()
    try:
        manager = DownloaderPackages(args.root)
        if args.command == 'fetch-cache':
            value = fetch_cache(args.cache)
        elif args.command == 'init':
            value = manager.initialize(args.cache)
        elif args.command == 'status':
            value = manager.status()
        else:
            getattr(manager, args.command)(args.package)
            value = manager.status()
        print(json.dumps({'status': 'PASS', 'packages': value}, ensure_ascii=False, indent=2))
        return 0
    except (PackageError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(json.dumps({'status': 'FAILED', 'error': str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
