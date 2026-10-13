"""Session-isolated refresh with one included and one excluded downloadable episode."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from threading import Lock
import json

armed = set()
lock = Lock()

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory='TestSupport/Media/listening', **kwargs)
    def do_GET(self):
        url = urlsplit(self.path)
        session = parse_qs(url.query).get('session', ['probe'])[0]
        if url.path == '/arm':
            with lock: armed.add(session)
            body = b'armed'; kind = 'text/plain'
        elif url.path == '/feed.xml':
            with lock: active = session in armed
            items = ''
            for i, title in ([(2, 'Keep episode'), (1, 'Skip episode')] if active else []) + [(0, 'Existing episode')]:
                items += (f'<item><guid>auto-{i}</guid><title>{title}</title>'
                          f'<pubDate>Mon, 01 Jan 2001 {i:02}:00:00 GMT</pubDate>'
                          f'<enclosure url="http://{self.headers["Host"]}/30sec.mp3?episode={i}&amp;session={session}" length="120017" type="audio/mpeg"/>'
                          '<itunes:duration>00:30</itunes:duration></item>')
            body = (f'<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                    f'<title>Automatic download lab</title>{items}</channel></rss>').encode()
            kind = 'application/rss+xml'
            print(json.dumps({'session': session, 'armed': active}), flush=True)
        else:
            return super().do_GET()
        self.send_response(200); self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(body)

# own port: 18770 is the authenticated feed
ThreadingHTTPServer(('127.0.0.1', 18775), Handler).serve_forever()
