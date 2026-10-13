"""Session-isolated, explicitly advanced feed for the new-episode settings journey."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from threading import Lock
import json

stages = {}
lock = Lock()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        session = query.get('session', ['probe'])[0]
        with lock:
            if url.path == '/advance':
                stages[session] = int(query['stage'][0])
            stage = stages.get(session, 0)
        if url.path == '/advance':
            body, kind = str(stage).encode(), 'text/plain'
        elif url.path == '/feed.xml':
            items = ''.join(
                f'<item><guid>action-{i}</guid><title>Action episode {i}</title>'
                f'<pubDate>Mon, 01 Jan 2001 {i:02}:00:00 GMT</pubDate>'
                f'<enclosure url="https://example.invalid/action-{i}.mp3" length="1000" type="audio/mpeg"/></item>'
                for i in range(stage, -1, -1))
            body = f'<rss version="2.0"><channel><title>New episodes lab</title>{items}</channel></rss>'.encode()
            kind = 'application/rss+xml'
            print(json.dumps({'session': session, 'stage': stage}), flush=True)
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(('127.0.0.1', 18769), Handler).serve_forever()
