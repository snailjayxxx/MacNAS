#!/usr/bin/env python3
"""Static asset and HTTP handler tests. No browser or TCP listener is started."""
import io,runpy,unittest,re
from pathlib import Path
from html.parser import HTMLParser
ROOT=Path(__file__).resolve().parents[1]
preview=runpy.run_path(str(ROOT/'scripts/preview_web.py'))
class MemoryRequest:
    def __init__(self,data):self.input=io.BytesIO(data);self.output=bytearray()
    def makefile(self,mode,*args):assert mode=='rb';return self.input
    def sendall(self,data):self.output.extend(data)
class QuietHandler(preview['Handler']):
    def log_message(self,*args):pass
def exchange(path='/',method='GET',host='127.0.0.1:8766'):
    request=MemoryRequest((method+' '+path+' HTTP/1.0\r\nHost: '+host+'\r\n\r\n').encode('ascii'))
    QuietHandler(request,('127.0.0.1',12345),None)
    head,body=bytes(request.output).split(b'\r\n\r\n',1)
    lines=head.decode('ascii').split('\r\n')
    return int(lines[0].split()[1]),{k.lower():v.strip() for k,v in (line.split(':',1) for line in lines[1:])},body
class AssetParser(HTMLParser):
    def __init__(self):super().__init__();self.assets=[];self.inline=[];self.policies=[];self.events=[]
    def handle_starttag(self,tag,attributes):
        a=dict(attributes)
        if tag=='script':self.assets.append(a.get('src'));self.inline.append('src' not in a)
        if tag=='link':self.assets.append(a.get('href'))
        if tag=='meta' and a.get('http-equiv')=='Content-Security-Policy':self.policies.append(a['content'])
        self.events.extend(k for k in a if k.startswith('on'))
class WebStaticTests(unittest.TestCase):
    def test_html_loads_only_allowlisted_local_assets_and_blocks_connections(self):
        parser=AssetParser();parser.feed((ROOT/'web/dist/index.html').read_text())
        self.assertFalse(any(parser.inline));self.assertEqual(parser.events,[])
        self.assertTrue(parser.policies);self.assertIn("connect-src 'none'",parser.policies[0])
        for name in parser.assets:
            self.assertIsNotNone(name);self.assertNotIn(':',name);self.assertNotIn('..',name)
            self.assertIn('/'+name,preview['ALLOWED']);self.assertTrue((ROOT/'web/dist'/name).is_file())
    def test_every_asset_is_read_only_and_uses_explicit_content_type(self):
        for path in preview['ALLOWED']:
            with self.subTest(path=path):
                status,headers,body=exchange(path)
                self.assertEqual(status,200);self.assertEqual(headers['cache-control'],'no-store')
                self.assertEqual(headers['x-content-type-options'],'nosniff');self.assertTrue(body)
                self.assertIn('charset=utf-8',headers['content-type'])
                self.assertEqual(int(headers['content-length']),len(body))
    def test_head_returns_no_body_and_mutations_are_rejected(self):
        status,headers,body=exchange(method='HEAD')
        self.assertEqual(status,200);self.assertEqual(body,b'');self.assertGreater(int(headers['content-length']),0)
        for method in ['POST','PUT','DELETE']:
            with self.subTest(method=method):self.assertEqual(exchange(method=method)[0],405)
    def test_directory_traversal_unknown_assets_and_repository_sources_are_not_served(self):
        for path in ['/../AGENTS.md','/%2e%2e/AGENTS.md','/Sources/MacNASCore/StateStore.swift','/.git/config','/model.js/../index.html','/web/tests/model.test.cjs','/missing','//etc/passwd']:
            with self.subTest(path=path):self.assertEqual(exchange(path)[0],404)
    def test_other_hosts_are_denied_even_with_an_allowlisted_path(self):
        for host in ['evil.example','127.0.0.1:8767','192.168.2.1:8766','127.0.0.1.evil.example:8766']:
            with self.subTest(host=host):self.assertEqual(exchange(host=host)[0],403)
    def test_dynamic_content_uses_text_nodes_and_reduced_motion_is_defined(self):
        js=(ROOT/'web/dist/desktop.js').read_text()
        for sink in ['innerHTML','outerHTML','insertAdjacentHTML','eval(','new Function(']:self.assertNotIn(sink,js)
        css=(ROOT/'web/dist/desktop.css').read_text()
        self.assertIn('prefers-reduced-motion:reduce',css);self.assertIn(':focus-visible',css)
        self.assertEqual(css.count('{'),css.count('}'))
        self.assertEqual(css.count('('),css.count(')'))
    def test_task_presentation_loads_after_model_and_keeps_host_transport_explicit(self):
        html=(ROOT/'web/dist/index.html').read_text()
        scripts=re.findall(r'<script defer src="([^"]+)"',html)
        self.assertLess(scripts.index('model.js'),scripts.index('task-pages.js'))
        self.assertLess(scripts.index('task-pages.js'),scripts.index('desktop.js'))
        self.assertNotIn('bridge-client.js',scripts)
        self.assertEqual(exchange('/bridge-client.js')[0],404)
        self.assertEqual(exchange('/task-pages.js')[0],200)
    def test_notification_view_loads_before_desktop_and_has_accessible_status(self):
        html=(ROOT/'web/dist/index.html').read_text()
        scripts=re.findall(r'<script defer src="([^"]+)"',html)
        self.assertLess(scripts.index('model.js'),scripts.index('notification-view.js'))
        self.assertLess(scripts.index('notification-view.js'),scripts.index('desktop.js'))
        self.assertEqual(exchange('/notification-view.js')[0],200)
        self.assertRegex(html,r'id="notification-status"[^>]*role="status"[^>]*aria-live="polite"')
    def test_directory_source_loads_in_order_and_keeps_paged_scope_explicit(self):
        scripts=re.findall(r'<script defer src="([^"]+)"',(ROOT/'web/dist/index.html').read_text())
        self.assertLess(scripts.index('model.js'),scripts.index('directory-view.js'))
        self.assertLess(scripts.index('directory-view.js'),scripts.index('file-browser.js'))
        self.assertLess(scripts.index('file-browser.js'),scripts.index('desktop.js'))
        self.assertEqual(exchange('/directory-view.js')[0],200)
        self.assertEqual(exchange('/file-browser.js')[0],200)
        js=(ROOT/'web/dist/desktop.js').read_text()
        self.assertNotIn('api.listFiles(',js);self.assertNotIn('api.previewFile(',js)
        self.assertIn('t("fileLoadedScope")',js);self.assertIn('el("span", "", file.name)',js)
        self.assertNotIn('t(file.name)',js);self.assertIn('win.filePager?.dispose()',js)
        self.assertIn('state.directorySource?.dispose()',js)
    def test_new_internal_modules_and_user_requirement_ledgers_are_not_static_assets(self):
        scripts=re.findall(r'<script defer src="([^"]+)"',(ROOT/'web/dist/index.html').read_text())
        self.assertNotIn('notification-reconciliation.js',scripts)
        for path in ['/notification-reconciliation.js','/bridge-client.js','/requirements/user-additions.json','/docs/plans/FUTURE-WEB-MAC-REMOTE-CONTROL.md']:
            with self.subTest(path=path):self.assertEqual(exchange(path)[0],404)
    def test_file_operation_presentation_loads_before_sources_without_exposing_host_approval(self):
        scripts=re.findall(r'<script defer src="([^"]+)"',(ROOT/'web/dist/index.html').read_text())
        self.assertLess(scripts.index('model.js'),scripts.index('file-operations.js'))
        self.assertLess(scripts.index('file-operations.js'),scripts.index('directory-view.js'))
        self.assertEqual(exchange('/file-operations.js')[0],200)
        js=(ROOT/'web/dist/desktop.js').read_text()
        self.assertNotIn('authorizeFixtureLibraryMutations',js)
        self.assertIn('win.fileOperation?.dispose()',js)
    def test_transfer_assets_load_before_sources_and_preserve_static_only_permissions(self):
        scripts=re.findall(r'<script defer src="([^"]+)"',(ROOT/'web/dist/index.html').read_text())
        for earlier,later in [('model.js','sha256.js'),('sha256.js','file-transfers.js'),('file-operations.js','file-transfers.js'),('file-transfers.js','file-transfer-view.js'),('file-transfers.js','directory-view.js'),('file-transfer-view.js','desktop.js')]:
            self.assertLess(scripts.index(earlier),scripts.index(later))
        for path in ['/sha256.js','/file-transfers.js','/file-transfer-view.js']:self.assertEqual(exchange(path)[0],200)
        self.assertEqual(exchange('/transfer-staging/upload-test')[0],404)
        js=(ROOT/'web/dist/desktop.js').read_text()
        self.assertIn('win.fileTransfer?.dispose()',js);self.assertIn('win.fileTransferPanel?.dispose()',js)
        for marker in ['authorizeFixtureLibraryUploads','fetch(','XMLHttpRequest','WebSocket(']:self.assertNotIn(marker,js)
    def test_download_view_uses_bounded_blob_and_explicit_link_without_automatic_click(self):
        js=(ROOT/'web/dist/file-transfer-view.js').read_text()
        self.assertIn('urls.revokeObjectURL(url)',js);self.assertIn('save.download=name',js)
        for marker in ['.click(','.innerHTML','window.open(','fetch(','localStorage']:self.assertNotIn(marker,js)
    def test_copy_assets_load_before_directory_and_keep_host_approval_private(self):
        scripts=re.findall(r'<script defer src="([^"]+)"',(ROOT/'web/dist/index.html').read_text())
        for earlier,later in [('file-transfers.js','file-copies.js'),('file-copies.js','file-copy-fixture.js'),('file-copy-fixture.js','directory-view.js'),('file-copy-view.js','desktop.js')]:
            self.assertLess(scripts.index(earlier),scripts.index(later))
        for path in ['/file-copies.js','/file-copy-fixture.js','/file-copy-view.js']:self.assertEqual(exchange(path)[0],200)
        js=(ROOT/'web/dist/desktop.js').read_text()
        for marker in ['authorizeFixtureLibraryCopies','fetch(','XMLHttpRequest','WebSocket(']:self.assertNotIn(marker,js)
        self.assertIn('win.fileCopy?.dispose()',js);self.assertIn('win.fileCopyPanel?.dispose()',js)
        self.assertEqual(exchange('/transfer-staging/copy-test')[0],404)
    def test_copy_view_uses_literal_text_and_explicit_source_pages(self):
        js=(ROOT/'web/dist/file-copy-view.js').read_text()
        for marker in ['innerHTML','outerHTML','insertAdjacentHTML','fetch(','localStorage','.click(']:self.assertNotIn(marker,js)
        self.assertIn('source.page(',js);self.assertIn('source.discardCursor(',js)
        self.assertIn('aria-valuetext',js);self.assertIn('pageSize:50',js)
if __name__=='__main__':unittest.main()
