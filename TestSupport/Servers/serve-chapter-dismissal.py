"""Per-run chapter refresh gate; empty late responses by default, optional successful rotation fixtures."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import threading

media = (Path(__file__).resolve().parents[2] / 'Tests/NotTennaPodCoreTests/Fixtures/playback-30sec.mp3').read_bytes()
condition = threading.Condition()
runs = {}
chapters = {'version':'1.2.0','chapters':[{'startTime':i*10,'title':title,'url':f'https://example.invalid/chapter/{i}'} for i,title in enumerate(['Opening','Middle','Closing'])]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def reply(self,kind,data):
        try:
            self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)))
            self.send_header('Cache-Control','no-store');self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        url=urlsplit(self.path);query=parse_qs(url.query);run=query.get('run',[''])[0]
        long_list=query.get('count',['3'])[0]=='20'
        response_chapters={'version':'1.2.0','chapters':[{'startTime':i,'title':f'Chapter {i+1:02d} with a deliberately long title that wraps onto another line','url':f'https://example.invalid/chapter/{i}'} for i in range(20)]} if long_list else chapters
        with condition:state=runs.setdefault(run,{'armed':False,'held':False,'released':False,'completed':False,'requests':0,'emptyOnRelease':True})
        if url.path in ['/arm','/release','/state']:
            with condition:
                if url.path=='/arm':state.update(armed=True,held=False,released=False,completed=False,emptyOnRelease=query.get('result',['empty'])[0]!='chapters')
                if url.path=='/release':state['released']=True;condition.notify_all()
                data=json.dumps(state).encode()
            self.reply('application/json',data)
        elif url.path=='/chapters':
            with condition:
                state['requests']+=1;held=state['armed'];empty=state['emptyOnRelease']
                if held:
                    state['armed']=False;state['held']=True;condition.notify_all()
                    condition.wait_for(lambda:state['released'],timeout=90)
            self.reply('application/json',json.dumps({'chapters':[]} if held and empty else response_chapters).encode())
            if held:
                with condition:state['completed']=True;condition.notify_all()
        elif url.path=='/media.mp3':self.reply('audio/mpeg',media)
        elif url.path=='/feed.xml':
            data=(f'<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Dismissal parity</title><description>Chapter refresh cancellation</description><item><guid>{run}</guid><title>Chapter episode</title><enclosure url="http://127.0.0.1:18809/media.mp3" type="audio/mpeg" length="{len(media)}"/><podcast:chapters url="http://127.0.0.1:18809/chapters?run={run}&amp;count={20 if long_list else 3}" type="application/json+chapters"/></item></channel></rss>').encode()
            self.reply('application/rss+xml',data)
        else:self.send_error(404)

ThreadingHTTPServer(('127.0.0.1',18809),Handler).serve_forever()
