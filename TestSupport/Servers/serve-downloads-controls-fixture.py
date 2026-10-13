"""Deterministic valid media and refresh counts for the Downloads screen journey."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from threading import Lock
import json

counts = {}
lock = Lock()
class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory='TestSupport/Media/listening', **kwargs)
    def do_GET(self):
        url = urlsplit(self.path)
        session = parse_qs(url.query).get('session', ['probe'])[0]
        if url.path == '/feed.xml':
            with lock:
                counts[session] = counts.get(session, 0) + 1
            items = ''.join(f'<item><guid>{name}</guid><title>{name}</title>'
                            f'<pubDate>{day:02d} Jan 2026 10:00:00 GMT</pubDate>'
                            f'<enclosure url="http://127.0.0.1:18771/30sec.mp3?session={session}&amp;episode={name}" '
                            f'length="120017" type="audio/mpeg"/></item>'
                            for day,name in enumerate(['Alpha','Zulu','Unplayed'], 1))
            body = f'<rss version="2.0"><channel><title>Downloads controls lab</title>{items}</channel></rss>'.encode()
            content_type = 'application/rss+xml'
        elif url.path == '/count':
            with lock:
                body = json.dumps({'count': counts.get(session, 0)}).encode()
            content_type = 'application/json'
        else:
            return super().do_GET()
        self.send_response(200); self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body))); self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(body)
ThreadingHTTPServer(('127.0.0.1', 18771), Handler).serve_forever()
