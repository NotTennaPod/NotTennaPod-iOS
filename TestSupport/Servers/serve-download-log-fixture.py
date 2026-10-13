"""Per-session feed/media failures and recovery for the real Download log journey."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from threading import Lock

state = {}
lock = Lock()
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory='TestSupport/Media/listening', **kwargs)
    def do_GET(self):
        url = urlsplit(self.path)
        session = parse_qs(url.query).get('session', ['probe'])[0]
        with lock:
            flags = state.setdefault(session, {'feed_failed': False, 'media_ready': False})
            if url.path == '/fail-feed': flags['feed_failed'] = True
            if url.path == '/recover-media': flags['media_ready'] = True
            flags = flags.copy()
        if url.path in ['/fail-feed', '/recover-media']:
            body = b'ok'; kind = 'text/plain'
        elif url.path == '/feed.xml':
            if flags['feed_failed']:
                self.send_error(503); return
            body = (f'<rss version="2.0"><channel><title>Download log lab</title>'
                    f'<item><guid>log-episode</guid><title>Log episode</title>'
                    f'<enclosure url="http://{self.headers["Host"]}/30sec.mp3?session={session}" '
                    'length="120017" type="audio/mpeg"/></item></channel></rss>').encode()
            kind = 'application/rss+xml'
        elif url.path == '/30sec.mp3' and not flags['media_ready']:
            self.send_error(404); return
        else:
            return super().do_GET()
        self.send_response(200); self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(body)
# own port: 18770 is the authenticated feed
ThreadingHTTPServer(('127.0.0.1', 18776), Handler).serve_forever()
