"""Run only on an explicitly reserved loopback port. Logs retain request/range evidence."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import argparse, json, time, os, sqlite3, uuid, hashlib
from urllib.parse import urlparse, parse_qs
parser=argparse.ArgumentParser()
parser.add_argument('--port',type=int,required=True)
parser.add_argument('--device',required=True, type=lambda value: str(uuid.UUID(value)).upper(),
                    help='the Simulator that started the servers; other Simulators are searched too')
args=parser.parse_args()
libraries={}
def find_library(identity):
    devices=Path.home()/'Library'/'Developer'/'CoreSimulator'/'Devices'
    def installed(device):
        # A test run (re)installs the app, so the Simulator in use has the newest application containers.
        try: return (device/'data'/'Containers'/'Data'/'Application').stat().st_mtime
        except OSError: return 0
    for device in sorted(devices.iterdir(), key=lambda device: (device.name!=args.device, -installed(device))):
        for container in (device/'data'/'Containers'/'Data'/'Application').glob('*'):
            library=container/'Library'/'Application Support'/('UITests-'+identity)
            if library.is_dir(): return library
    return None
def checkpoint(identity):
    # Explicit owned Simulator and UUID-only test namespace; read-only SQLite.
    identity=str(uuid.UUID(identity)).upper()
    # Runs on several Simulators share this server: find the app data container holding this UUID library.
    # Read the Simulators' data directories directly: `simctl get_app_container` on a busy Simulator took
    # over 10 s while other test runs were active (2026-09-28), failing the checkpoint for a different device.
    directory=libraries.get(identity)
    if directory is None or not directory.is_dir():
        directory=find_library(identity)
    assert directory is not None, 'No Simulator holds library '+identity
    libraries[identity]=directory # A test polls its checkpoint; the library stays in place.
    with sqlite3.connect((directory/'library.sqlite').as_uri()+'?mode=ro',uri=True) as db:
        rows=db.execute('SELECT id,record FROM episodes ORDER BY id').fetchall()
        selected=db.execute('SELECT episode_id FROM playback_selection WHERE id=1').fetchone()
    assert len(rows)==1 and selected and selected[0]==rows[0][0], 'Expected exactly the selected fixture episode'
    episode=json.loads(rows[0][1]); assert episode['details']['title']=='Numbered two-track video'
    result={'library':identity,'episode':episode,'selectedEpisodeID':selected[0],'observedAtMilliseconds':int(time.time()*1000),
            'speedPreferences':json.loads((directory/'playback-speed-preferences.json').read_text())}
    print(json.dumps({'checkpoint':result}),flush=True)
    return result
media=Path(__file__).with_name('journey.mp4').read_bytes()
failures={}
class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self): self.respond(False)
    def do_GET(self): self.respond(True)
    def do_POST(self):
        try:
            assert self.path.startswith('/repair/')
            identity=str(uuid.UUID(self.path.removeprefix('/repair/'))).upper()
            assert identity in failures
        except Exception:self.send_error(404);return
        failures[identity]=True
        self.send_response(204); self.end_headers()
    def respond(self,body):
        if urlparse(self.path).path == '/checkpoint':
            try:
                data=json.dumps(checkpoint(parse_qs(urlparse(self.path).query)['library'][0])).encode()
            except Exception as error:
                self.send_error(409, str(error)); return
            self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
            if body:self.wfile.write(data)
            return
        if self.path.startswith('/feed.xml'):
            query=parse_qs(urlparse(self.path).query)
            media_path='/journey.mp4'
            if query.get('failure') == ['1']:
                identity=str(uuid.UUID(query['run'][0])).upper();failures.setdefault(identity,False)
                media_path='/broken/'+identity+'.mp4'
            data=('''<?xml version="1.0"?><rss version="2.0" xmlns:psc="http://podlove.org/simple-chapters"><channel><title>Playback video fixture</title><link>https://example.invalid/video</link><description>Deterministic video</description><item><guid>video-journey</guid><title>Numbered two-track video</title><description>Original synthetic frame/tone fixture.</description><psc:chapters version="1.2"><psc:chapter start="00:00:00" title="Beginning"/><psc:chapter start="00:00:48" title="Midpoint"/></psc:chapters><enclosure url="http://127.0.0.1:%d%s" type="video/mp4" length="%d"/></item></channel></rss>'''%(self.server.server_port,media_path,len(media))).encode()
            self.send_response(200); self.send_header('Content-Type','application/rss+xml'); self.send_header('Content-Length',str(len(data))); self.end_headers()
            if body:self.wfile.write(data)
            return
        payload=media
        if self.path.startswith('/broken/'):
            try:
                identity=str(uuid.UUID(self.path.removeprefix('/broken/').removesuffix('.mp4'))).upper()
                repaired=failures[identity]
            except Exception:self.send_error(404);return
            if not repaired:payload=bytes(128) # Explicit malformed-input scenario, never a normal format fixture.
        elif self.path != '/journey.mp4': self.send_error(404); return
        etag='\"'+hashlib.sha256(payload).hexdigest()+'\"'
        start,end=0,len(payload)-1; code=200
        if self.headers.get('Range') and self.headers.get('If-Range',etag) == etag:
            value=self.headers['Range'].removeprefix('bytes='); first,last=value.split('-',1)
            if not first:start=max(0,len(payload)-int(last))
            else:start=int(first);end=min(end,int(last)) if last else end
            if start>end or start>=len(payload):self.send_error(416);return
            code=206
        self.send_response(code); self.send_header('Content-Type','video/mp4'); self.send_header('Accept-Ranges','bytes'); self.send_header('ETag',etag)
        self.send_header('Content-Length',str(end-start+1))
        if code==206:self.send_header('Content-Range',f'bytes {start}-{end}/{len(payload)}')
        self.end_headers()
        print(json.dumps({'response':self.path,'status':code,'etag':etag,'entityBytes':len(payload),'start':start,'end':end,'ifRange':self.headers.get('If-Range')}),flush=True)
        if body:
            try:self.wfile.write(payload[start:end+1])
            except (BrokenPipeError,ConnectionResetError):pass
    def log_message(self,fmt,*values):print(json.dumps({'time':time.time(),'request':fmt%values,'range':self.headers.get('Range')}),flush=True)
server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
print(json.dumps({'port':server.server_port,'pid':os.getpid(),'device':args.device,'mediaBytes':len(media)}),flush=True)
try:server.serve_forever()
finally:server.server_close()
