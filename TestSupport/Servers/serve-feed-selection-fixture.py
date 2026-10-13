"""Synthetic eight-episode feed for original/native selection journeys."""
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**k):super().__init__(*a,directory='TestSupport/Media/listening',**k)
 def do_GET(self):
  if self.path.startswith('/selection.xml'):
   base='http://'+self.headers['Host']
   items=''.join(f'<item><guid>selection-{i}</guid><title>Selection episode {i:02}</title><pubDate>Mon, 01 Jan 2001 {i:02}:00:00 GMT</pubDate><enclosure url="{base}/30sec.mp3?episode={i}" type="audio/mpeg" length="120000"/></item>' for i in range(8,0,-1))
   body=f'<rss version="2.0"><channel><title>Feed Selection Lab</title>{items}</channel></rss>'.encode()
   self.send_response(200);self.send_header('Content-Type','application/rss+xml');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  else:super().do_GET()
ThreadingHTTPServer(('0.0.0.0',18768),Handler).serve_forever()
