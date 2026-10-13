"""Deterministic three-page feed. Logs requests for original/native comparisons."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit
import json
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        pages = {'/paged.xml': 0, '/page1.xml': 1, '/page2.xml': 2}
        if path not in pages:
            self.send_error(404); return
        page = pages[path]
        # Use the requesting host so the same fixture works through Android's
        # emulator gateway and the iOS Simulator's loopback interface.
        base = 'http://' + self.headers['Host']
        next_link = f'<atom:link rel="next" href="{base}/page{page+1}.xml"/>' if page < 2 else ''
        items = ''.join(f'<item><guid>paged-{i}</guid><title>Pagination episode {i:02}</title><pubDate>Mon, 01 Jan 2001 {i%24:02}:00:00 GMT</pubDate><enclosure url="{base}/audio-{i}.mp3" type="audio/mpeg" length="40000"/></item>' for i in range(12-page*4, 8-page*4, -1))
        body = f'<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel><title>Pagination Lab</title><description>Controlled paged feed</description>{next_link}{items}</channel></rss>'.encode()
        print(json.dumps({'path':path,'host':self.headers['Host']}), flush=True)
        self.send_response(200); self.send_header('Content-Type','application/rss+xml');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('0.0.0.0',18766),Handler).serve_forever()
