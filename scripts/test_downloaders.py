#!/usr/bin/env python3
"""Offline package-manager state and failure tests using synthetic app bundles."""
import copy, io, hashlib, importlib.util, json, os, plistlib, shutil, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('downloaders', ROOT/'scripts/manage_downloaders.py')
P = importlib.util.module_from_spec(spec); spec.loader.exec_module(P)
ORIGINAL_EXTRACT = P.extract_app
REAL_RUN = subprocess.run

class DownloaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='n030-synthetic-')
        self.base = Path(self.tmp.name).resolve(); self.cache = self.base/'cache'; self.cache.mkdir()
        self.catalog = copy.deepcopy(P.load_catalog()[0])
        for item in self.catalog['packages']:
            value = ('synthetic-DMG-'+item['id']).encode(); (self.cache/item['archive']).write_bytes(value)
            item['sha256'] = hashlib.sha256(value).hexdigest()
        self.catalog_file = self.base/'catalog.json'; self.catalog_file.write_text(json.dumps(self.catalog))
        self.catalog_patch = patch.object(P, 'CATALOG', self.catalog_file); self.catalog_patch.start()
        self.extract_patch = patch.object(P, 'extract_app', self.fake_extract); self.extract_patch.start()
        self.verify_patch = patch.object(P, 'verify_app'); self.verify_patch.start()
        def tools(arguments, **kwargs):
            if arguments[0]=='/usr/bin/ditto': return REAL_RUN(arguments, **kwargs)
            return subprocess.CompletedProcess(arguments, 1, b'', b'')
        self.process_patch = patch.object(P.subprocess, 'run', side_effect=tools); self.process_patch.start()
        self.manager = P.DownloaderPackages(self.base/'owned-packages')
    def tearDown(self):
        self.process_patch.stop(); self.verify_patch.stop(); self.extract_patch.stop(); self.catalog_patch.stop(); self.tmp.cleanup()
    def fake_extract(self, archive, target, item):
        (target/'Contents/MacOS').mkdir(parents=True)
        (target/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':item['bundle_id'], 'CFBundleShortVersionString':item['version'], 'CFBundleExecutable':item['executable']}))
        (target/'Contents/MacOS'/item['executable']).write_bytes(b'synthetic-not-executable')
    def initialize(self): self.manager.initialize(self.cache)
    def test_default_both_installed_and_never_launched(self):
        self.initialize(); self.assertEqual([p['state'] for p in self.manager.status()], ['installed','installed'])
        self.assertTrue(all(p['removable'] and p['bundled'] and not p['auto_start'] for p in self.manager.status()))
    def test_removal_and_offline_reinstall_preserve_configuration_and_payload(self):
        self.initialize(); root=self.manager.root
        (root/'data/qbittorrent/settings').write_bytes(b'config')
        payload=self.base/'downloads'; payload.mkdir(); (payload/'keep.bin').write_bytes(b'download')
        for identity in self.manager.packages:
            self.manager.uninstall(identity); self.manager.uninstall(identity)
            self.assertFalse((root/'installed'/identity).exists())
            self.manager.install(identity); self.manager.install(identity)
        self.assertEqual((root/'data/qbittorrent/settings').read_bytes(), b'config')
        self.assertEqual((payload/'keep.bin').read_bytes(), b'download')
    def test_uninstall_one_does_not_remove_other(self):
        self.initialize(); self.manager.uninstall('qbittorrent')
        self.assertEqual([p['state'] for p in self.manager.status()], ['removed','installed'])
    def test_restart_respects_removal(self):
        self.initialize(); self.manager.uninstall('transmission')
        restarted=P.DownloaderPackages(self.manager.root)
        self.assertEqual(restarted.status()[1]['state'], 'removed')
        with self.assertRaisesRegex(P.PackageError,'alreadyInitialized'): restarted.initialize(self.cache)
        self.assertEqual(restarted.status()[1]['state'], 'removed')
    def test_bad_checksum_cannot_seed_partial_defaults(self):
        (self.cache/self.catalog['packages'][1]['archive']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(P.PackageError,'archiveChecksumMismatch'): self.initialize()
        self.assertFalse(self.manager.root.exists())
    def test_extraction_failure_does_not_publish_a_partial_distribution(self):
        with patch.object(P,'extract_app',side_effect=P.PackageError('syntheticExtractionFailure')):
            with self.assertRaisesRegex(P.PackageError,'syntheticExtractionFailure'): self.initialize()
        self.assertFalse(self.manager.root.exists()); self.assertEqual(list(self.base.glob('.downloaders-*')),[])
    def test_reinstall_rejects_corrupt_cache_without_marking_installed(self):
        self.initialize(); self.manager.uninstall('transmission')
        (self.manager.root/'offline-cache'/self.catalog['packages'][1]['archive']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(P.PackageError,'archiveChecksumMismatch'): self.manager.install('transmission')
        self.assertEqual(self.manager.status()[1]['state'],'removed')
    def test_existing_unmanaged_directory_is_untouched(self):
        self.manager.root.mkdir(); (self.manager.root/'user-file').write_bytes(b'keep')
        with self.assertRaisesRegex(P.PackageError,'alreadyInitialized'): self.initialize()
        self.assertEqual((self.manager.root/'user-file').read_bytes(),b'keep')
    def test_symlink_root_or_ancestor_is_rejected(self):
        (self.base/'link').symlink_to(self.cache)
        for path in [self.base/'link',self.base/'link/child']:
            with self.assertRaisesRegex(P.PackageError,'symlinkPath'): P.DownloaderPackages(path)
    def test_archive_symlink_and_hardlink_are_rejected(self):
        path=self.cache/self.catalog['packages'][0]['archive'];saved=self.cache/'saved';path.rename(saved);path.symlink_to(saved)
        with self.assertRaisesRegex(P.PackageError,'invalidFile'): self.initialize()
        path.unlink(); os.link(saved,path)
        with self.assertRaisesRegex(P.PackageError,'invalidFile'): self.initialize()
    def test_unknown_packages_cannot_select_paths(self):
        self.initialize()
        for identity in ['../data','arbitrary','','Transmission']:
            for method in [self.manager.install,self.manager.uninstall]:
                with self.assertRaisesRegex(P.PackageError,'unknownPackage'): method(identity)
    def test_symlink_installed_directory_cannot_delete_external_content(self):
        self.initialize(); root=self.manager.root;target=root/'installed/qbittorrent';shutil.rmtree(target)
        outside=self.base/'outside';outside.mkdir();(outside/'keep').write_bytes(b'keep');target.symlink_to(outside)
        with self.assertRaisesRegex(P.PackageError,'symlinkPath'): self.manager.uninstall('qbittorrent')
        self.assertEqual((outside/'keep').read_bytes(),b'keep')
    def test_running_app_is_not_killed_or_removed(self):
        self.initialize()
        with patch.object(P.subprocess,'run',return_value=subprocess.CompletedProcess([],0,b'123\n',b'')):
            with self.assertRaisesRegex(P.PackageError,'appRunning'): self.manager.uninstall('qbittorrent')
        self.assertEqual(self.manager.status()[0]['state'],'installed')
    def test_unexpected_sibling_content_blocks_uninstall(self):
        self.initialize();p=self.manager.root/'installed/qbittorrent/user-file';p.write_bytes(b'keep')
        with self.assertRaisesRegex(P.PackageError,'unexpectedPackageContent'): self.manager.uninstall('qbittorrent')
        self.assertEqual(p.read_bytes(),b'keep')
    def test_interrupted_receipt_is_reported_and_can_be_explicitly_repaired(self):
        self.initialize();shutil.rmtree(self.manager.root/'installed/qbittorrent')
        self.assertEqual(self.manager.status()[0]['state'],'needsRepair');self.manager.install('qbittorrent')
        self.assertEqual(self.manager.status()[0]['state'],'installed')
    def test_catalog_mismatch_cannot_mutate_installed_distribution(self):
        self.initialize(); receipt=self.manager.root/'receipt.json'; data=json.loads(receipt.read_text());data['catalog_sha256']='0'*64;receipt.write_text(json.dumps(data))
        with self.assertRaisesRegex(P.PackageError,'invalidReceipt'):self.manager.uninstall('qbittorrent')
        self.assertTrue((self.manager.root/'installed/qbittorrent').exists())

    def test_fetch_uses_verified_existing_cache_without_network(self):
        with patch.object(P.urllib.request, 'build_opener') as opener:
            result=P.fetch_cache(self.cache)
            self.assertEqual(len(result),2);opener.return_value.open.assert_not_called()
    def test_fetch_refuses_existing_bad_cache_without_overwriting(self):
        path=self.cache/self.catalog['packages'][0]['archive'];path.write_bytes(b'bad')
        with self.assertRaisesRegex(P.PackageError,'archiveChecksumMismatch'):P.fetch_cache(self.cache)
        self.assertEqual(path.read_bytes(),b'bad')
    def test_download_wrong_checksum_is_not_published(self):
        class Response(io.BytesIO):
            url='https://downloads.sourceforge.net/fake'
        target=self.base/'fresh-cache'
        opener=unittest.mock.Mock();opener.open.return_value=Response(b'incorrect-archive')
        with patch.object(P.urllib.request,'build_opener',return_value=opener):
            with self.assertRaisesRegex(P.PackageError,'archiveChecksumMismatch'):P.fetch_cache(target)
        self.assertEqual(list(target.iterdir()),[])
    def test_download_timeout_cleans_private_partial(self):
        class Response(io.BytesIO):
            url='https://downloads.sourceforge.net/fake'
        target=self.base/'fresh-cache';opener=unittest.mock.Mock();opener.open.return_value=Response(b'partial')
        with patch.object(P.urllib.request,'build_opener',return_value=opener), patch.object(P.time,'monotonic',side_effect=[0,301]):
            with self.assertRaisesRegex(P.PackageError,'downloadTimedOut'):P.fetch_cache(target)
        self.assertEqual(list(target.iterdir()),[])
    def test_redirect_cannot_downgrade_https_or_switch_to_untrusted_host(self):
        redirect=P.HTTPSRedirect();request=P.urllib.request.Request('https://github.com/example')
        for url in ['http://github.com/file','https://evil.example/file','https://sourceforge.net.evil.example/file','file:///private/file']:
            with self.assertRaisesRegex(P.PackageError,'untrustedDownloadRedirect'):
                redirect.redirect_request(request,None,302,'redirect',{},url)
    def test_official_release_redirects_are_accepted(self):
        redirect=P.HTTPSRedirect();request=P.urllib.request.Request('https://github.com/example')
        for url in ['https://release-assets.githubusercontent.com/file','https://pilotfiber.dl.sourceforge.net/file']:
            self.assertEqual(redirect.redirect_request(request,None,302,'redirect',{},url).full_url,url)

    def test_manual_app_deletion_is_visible_as_needs_repair(self):
        self.initialize(); package=self.catalog['packages'][0]
        shutil.rmtree(self.manager.root/'installed'/package['id']/package['app_name'])
        self.assertEqual(self.manager.status()[0]['state'],'needsRepair')
    def test_explicit_install_repairs_empty_package_directory_and_keeps_data(self):
        self.initialize(); package=self.catalog['packages'][0]; data=self.manager.root/'data'/package['id']/'keep';data.write_bytes(b'configuration')
        app=self.manager.root/'installed'/package['id']/package['app_name'];shutil.rmtree(app)
        self.manager.install(package['id'])
        self.assertTrue(app.is_dir());self.assertEqual(data.read_bytes(),b'configuration')
    def test_uninstall_after_manual_app_removal_is_idempotent_and_keeps_data(self):
        self.initialize();package=self.catalog['packages'][1];data=self.manager.root/'data'/package['id']/'keep';data.write_bytes(b'configuration')
        shutil.rmtree(self.manager.root/'installed'/package['id']/package['app_name'])
        self.manager.uninstall(package['id']);self.manager.uninstall(package['id'])
        self.assertEqual(self.manager.status()[1]['state'],'removed');self.assertEqual(data.read_bytes(),b'configuration')
    def test_archive_extended_metadata_survives_cache_and_mount_working_copy(self):
        package=self.catalog['packages'][0];key='com.macnas.synthetic-provenance';value=b'fixture-metadata'
        archive=self.cache/package['archive'];REAL_RUN(['/usr/bin/xattr','-wx',key,value.hex(),str(archive)],check=True)
        self.initialize();cached=self.manager.root/'offline-cache'/package['archive']
        self.assertEqual(bytes.fromhex(REAL_RUN(['/usr/bin/xattr','-px',key,str(cached)],capture_output=True,check=True).stdout.decode().replace(' ', '').replace('\n','')),value)
        observed=[]
        def capture(arguments):
            if arguments[0]=='/usr/bin/ditto' and arguments[-2]==str(cached):
                return REAL_RUN(arguments,capture_output=True,check=True).stdout
            if arguments[0]=='/usr/bin/hdiutil' and arguments[1]=='attach':observed.append(bytes.fromhex(REAL_RUN(['/usr/bin/xattr','-px',key,str(arguments[-1])],capture_output=True,check=True).stdout.decode().replace(' ', '').replace('\n','')))
            return b''
        with patch.object(P,'run',side_effect=capture):ORIGINAL_EXTRACT(cached,self.base/'app.app',package)
        self.assertEqual(observed,[value])

if __name__=='__main__':unittest.main()
