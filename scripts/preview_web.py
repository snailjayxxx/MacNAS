#!/usr/bin/env python3
"""Explicitly authorized N-011 preview only. Read-only, allowlisted assets, loopback port 8766."""
import http.server, json, mimetypes, plistlib, subprocess, urllib.parse
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SITE=ROOT/'web/dist'
ALLOWED={'/':'index.html','/index.html':'index.html','/desktop.css':'desktop.css','/desktop.js':'desktop.js','/model.js':'model.js','/i18n.js':'i18n.js','/icon.svg':'icon.svg'}
actual=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist','/Volumes/MacNAS-Dev']))
expected=json.loads((ROOT.parent/'Evidence/environment.json').read_text())
assert actual['VolumeUUID']==expected['volume_uuid'] and actual['MountPoint']=='/Volumes/MacNAS-Dev' and not actual['Internal']
class Handler(http.server.BaseHTTPRequestHandler):
    server_version='MacNASLocalPreview'
    sys_version=''
    def serve(self,head=False):
        if self.headers.get('Host') not in ['127.0.0.1:8766','localhost:8766']:
            self.send_error(403);return
        path=urllib.parse.urlsplit(self.path).path
        name=ALLOWED.get(path)
        if name is None:
            self.send_error(404);return
        file=SITE/name
        if file.is_symlink() or file.resolve().parent != SITE.resolve():
            self.send_error(403);return
        data=file.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type',{'html':'text/html','css':'text/css','js':'text/javascript','svg':'image/svg+xml'}[file.suffix[1:]]+'; charset=utf-8')
        self.send_header('Content-Length',str(len(data)))
        self.send_header('Cache-Control','no-store')
        self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Referrer-Policy','no-referrer')
        self.send_header('Permissions-Policy','camera=(), microphone=(), geolocation=()')
        self.end_headers()
        if not head:self.wfile.write(data)
    def do_GET(self):self.serve()
    def do_HEAD(self):self.serve(True)
    def do_POST(self):self.send_error(405)
    def do_PUT(self):self.send_error(405)
    def do_DELETE(self):self.send_error(405)
    def log_message(self,format,*args):
        print(json.dumps({'request':self.command,'path':urllib.parse.urlsplit(self.path).path,'result':args[1] if len(args)>1 else ''}),flush=True)
if __name__=='__main__':
    server=http.server.ThreadingHTTPServer(('127.0.0.1',8766),Handler)
    print('MacNAS preview: http://127.0.0.1:8766 (allowlisted static assets only)',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close();print('Preview stopped',flush=True)
