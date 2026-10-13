"""Gated loopback-only MP3 stream; each test UUID owns an independent byte budget."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import threading

media = (Path(__file__).resolve().parents[2] / 'Tests/NotTennaPodCoreTests/Fixtures/playback-30sec.mp3').read_bytes()
condition = threading.Condition()
budgets = {}
hls_folder = Path(__file__).resolve().parents[2] / "TestSupport/Media/listening/buffering-hls"


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        run = query.get('run', ['missing'])[0]
        hls = query.get('kind', ['mp3'])[0] == 'hls'
        if url.path == '/release':
            with condition:
                budgets[run] = int(float(query['fraction'][0]) * len(media))
                condition.notify_all()
            self.reply('application/json', b'{}')
        elif url.path == '/feed.xml' and hls:
            self.reply('application/rss+xml', (f'<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Buffer parity</title><description>Controlled HLS stream</description><item><guid>{run}</guid><title>Gated HLS stream</title><enclosure url="http://127.0.0.1:18808/hls/{run}/index.m3u8" type="application/vnd.apple.mpegurl" length="0"/><podcast:chapters url="http://127.0.0.1:18808/chapters.json?kind=hls" type="application/json+chapters"/></item></channel></rss>').encode())
        elif url.path.startswith('/hls/'):
            _, _, run, name = url.path.split('/')
            if name == 'index.m3u8':
                self.reply('application/vnd.apple.mpegurl', (hls_folder / name).read_bytes())
            elif name in {path.name for path in hls_folder.glob('part*.ts')}:
                part = int(name[4:6])
                print(json.dumps({'run': run, 'segment': name}), flush=True)
                with condition:
                    threshold = 0 if part < 7 else len(media) - 1
                    if not condition.wait_for(lambda: budgets.get(run, 0) > threshold, timeout=90):
                        return
                self.reply('video/mp2t', (hls_folder / name).read_bytes())
            else:
                self.send_error(404)
        elif url.path == '/feed.xml':
            self.reply('application/rss+xml', (f'<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0"><channel><title>Buffer parity</title><description>Controlled stream</description><item><guid>{run}</guid><title>Gated stream</title><enclosure url="http://127.0.0.1:18808/stream.mp3?run={run}" type="audio/mpeg" length="{len(media)}"/><podcast:chapters url="http://127.0.0.1:18808/chapters.json" type="application/json+chapters"/></item></channel></rss>').encode())
        elif url.path == '/chapters.json':
            self.reply('application/json', json.dumps({'chapters': [{'startTime': 0, 'title': 'Opening'}, {'startTime': 10, 'title': 'Middle'}, {'startTime': 25, 'title': 'Closing'}]}).encode())
        elif url.path == '/stream.mp3':
            value = self.headers.get('Range')
            start, end = 0, len(media) - 1
            if value:
                first, last = value.removeprefix('bytes=').split('-', 1)
                if first:
                    start = int(first)
                    if last:
                        end = min(int(last), end)
                else:
                    start = max(0, len(media) - int(last))
            if start > end:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{len(media)}')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            self.send_response(206 if value else 200)
            self.send_header('Content-Type', 'audio/mpeg')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(end - start + 1))
            self.send_header('Connection', 'close')
            if value:
                self.send_header('Content-Range', f'bytes {start}-{end}/{len(media)}')
            self.end_headers()
            self.close_connection = True
            print(json.dumps({'run': run, 'range': value, 'start': start, 'end': end}), flush=True)
            try:
                while start <= end:
                    with condition:
                        if not condition.wait_for(lambda: budgets.get(run, 0) > start, timeout=90):
                            return
                        stop = min(budgets[run], start + 4096, end + 1)
                    self.wfile.write(media[start:stop])
                    self.wfile.flush()
                    start = stop
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            self.send_error(404)

    def reply(self, content_type, data):
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(('127.0.0.1', 18808), Handler).serve_forever()
