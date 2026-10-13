"""Twelve stored preview episodes and per-URL request counts for subscription tests."""
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from collections import Counter
from threading import Lock
import json
counts=Counter(); lock=Lock()
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**k):super().__init__(*a,directory='TestSupport/Media/listening',**k)
 def do_GET(self):
  route=urlsplit(self.path)
  if route.path=='/counts':
   with lock:body=json.dumps(dict(counts)).encode()
   self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  elif route.path=='/preview.xml':
   with lock:counts[self.path]+=1
   base='http://'+self.headers['Host']
   items=''.join(f'<item><guid>preview-{i}</guid><title>Preview episode {i:02}</title><description>Preview episode notes {i}</description><pubDate>Mon, 01 Jan 2001 {i:02}:00:00 GMT</pubDate><enclosure url="{base}/30sec.mp3?episode={i}" type="audio/mpeg" length="120000"/></item>' for i in range(12,0,-1))
   body=f'<rss version="2.0"><channel><title>Preview Navigation Lab</title><description>&lt;p&gt;A controlled preview with &lt;b&gt;twelve episodes&lt;/b&gt;. Tap this description to read podcast information.&lt;/p&gt;</description>{items}</channel></rss>'.encode()
   self.send_response(200);self.send_header('Content-Type','application/rss+xml');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
  else:super().do_GET()
ThreadingHTTPServer(('0.0.0.0',18774),Handler).serve_forever()  # own port since the shared UI-test fixture set (18769 is new-episodes)
