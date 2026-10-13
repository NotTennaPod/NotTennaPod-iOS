"""Explicitly armed synthetic refresh response for native/original gesture tests."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit,parse_qs
from threading import Lock, Event
import json
armed=set(); counts={}; holds={}; lock=Lock()
class Handler(BaseHTTPRequestHandler):
 def do_GET(self):
  url=urlsplit(self.path);session=parse_qs(url.query).get('session',['android'])[0]
  with lock:
   if url.path=='/arm':armed.add(session)
   if url.path=='/hold':holds[session]=Event()
   if url.path=='/release':
    event=holds.pop(session,None)
    if event:event.set()
   if url.path=='/feed.xml':counts[session]=counts.get(session,0)+1
   active=session in armed; count=counts.get(session,0); held=holds.get(session)
  if url.path in ['/arm','/count','/hold','/release']:body=str(count).encode();kind='text/plain'
  elif url.path=='/feed.xml':
   if held:held.wait(timeout=30)
   title='Pull delivered podcast' if active else 'Pull Refresh Lab'
   extra='<item><guid>new</guid><title>Pull delivered episode</title><pubDate>Mon, 01 Jan 2001 16:00:00 GMT</pubDate></item>' if active else ''
   items=''.join(f'<item><guid>pull-{i}</guid><title>Pull episode {i}</title><pubDate>Mon, 01 Jan 2001 {i:02}:00:00 GMT</pubDate></item>' for i in range(4,0,-1))
   body=f'<rss version="2.0"><channel><title>{title}</title>{extra}{items}</channel></rss>'.encode();kind='application/rss+xml'
   print(json.dumps({'session':session,'request':count,'armed':active}),flush=True)
  else:self.send_error(404);return
  self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
ThreadingHTTPServer(('0.0.0.0',18767),Handler).serve_forever()
