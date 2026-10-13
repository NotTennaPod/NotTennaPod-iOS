#!/usr/bin/env python3
"""Loopback-only HTTP CONNECT/SOCKSv5 relay to the source's fixed test endpoint.

Never logs credentials or TLS plaintext. This is a network-dependent protocol
probe, not a replacement for deterministic behavior tests.
"""
import argparse
import asyncio
import base64
import json
import time
from urllib.parse import urlsplit, parse_qs
from html import escape
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--report', type=Path, required=True)
parser.add_argument('--http-port', type=int, default=18790)
parser.add_argument('--socks-port', type=int, default=18791)
parser.add_argument('--media', type=Path)
parser.add_argument('--live-media', type=Path)
parser.add_argument('--hls', type=Path)
parser.add_argument('--hls-aes', type=Path)
args = parser.parse_args()
report = {'http': [], 'socks': []}
live_streams = {}

def record(kind, value):
    report[kind].append(value)
    args.report.write_text(json.dumps(report, indent=2) + '\n')

async def bridge(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()

async def tunnel(reader, writer, kind, target):
    # An explicit allowlist keeps this test fixture from becoming an open proxy.
    if target not in [('www.example.com', 443), ('raw.githubusercontent.com', 443)]:
        record(kind, {'rejectedTarget': True})
        return
    upstream, outbound = await asyncio.wait_for(asyncio.open_connection(*target), 10)
    if kind == 'http':
        writer.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
    else:
        writer.write(b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00')
    await writer.drain()
    record(kind, {'tunnel': 'established', 'host': target[0], 'port': target[1]})
    await asyncio.gather(bridge(reader, outbound), bridge(upstream, writer))

async def http(reader, writer):
    try:
        data = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
        lines = data.decode('iso-8859-1').split('\r\n')
        method, target, _ = lines[0].split(' ', 2)
        headers = dict(line.split(':', 1) for line in lines[1:] if ':' in line)
        headers = {k.lower(): v.strip() for k,v in headers.items()}
        expected = 'Basic ' + base64.b64encode(b'fixture-user:fixture-secret').decode()
        authenticated = headers.get('proxy-authorization') == expected
        record('http', {'method': method, 'target': target, 'authenticated': authenticated,
                        'originAuthorizationPresent': 'authorization' in headers, 'range': headers.get('range')})
        if not authenticated:
            writer.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="protocol-fixture"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            await writer.drain()
            return
        parsed = urlsplit(target)
        if parsed.path == '/recovery-status' and method == 'GET':
            session = parse_qs(parsed.query).get('session', [''])[0]
            state = live_streams.get(session)
            reconnects = state['reconnects'] if state else []
            body = json.dumps({'reconnected': bool(reconnects),
                              'secondsSinceReconnect': time.monotonic() - reconnects[0] if reconnects else 0}).encode()
            writer.write(('HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % len(body)).encode() + body)
            await writer.drain()
            return
        if args.hls_aes and method in ['GET', 'HEAD'] and (parsed.hostname == 'proxy-cdn.invalid' or
                (parsed.hostname == 'proxy-feed.invalid' and parsed.path.startswith('/encrypted/'))):
            name = Path(parsed.path).name
            if name == 'alternate.m3u8':
                name = 'variant.m3u8'
            if name not in ['master.m3u8', 'variant.m3u8', 'media.bin', 'key-a.bin', 'key-b.bin']:
                return
            body = (args.hls_aes / name).read_bytes()
            if name == 'master.m3u8':
                session = parsed.path.split('/')[-2]
                body = body.replace(b'http://cdn.invalid', ('http://proxy-cdn.invalid/' + session).encode())
            elif name == 'variant.m3u8':
                original = body.decode()
                segment_start = original.index('#EXT-X-KEY:')
                segments = original[segment_start:].replace('#EXT-X-ENDLIST', '').strip()
                body = (original[:segment_start] + '\n#EXT-X-DISCONTINUITY\n'.join([segments] * 3) + '\n#EXT-X-ENDLIST\n').encode()
            mime = 'application/vnd.apple.mpegurl' if name.endswith('m3u8') else 'application/octet-stream'
            status, extra, complete_length = 200, '', len(body)
            if headers.get('range', '').startswith('bytes='):
                start, end = headers['range'][6:].split('-', 1)
                start, end = int(start), min(int(end) if end else len(body) - 1, len(body) - 1)
                if start < 0 or end < start or start >= len(body):
                    return
                body = body[start:end + 1]
                status, extra = 206, 'Content-Range: bytes %d-%d/%d\r\n' % (start, end, complete_length)
            writer.write(('HTTP/1.1 %d OK\r\nContent-Type: %s\r\nContent-Length: %d\r\nAccept-Ranges: bytes\r\n%sConnection: close\r\n\r\n' %
                          (status, mime, len(body), extra)).encode() + (body if method == 'GET' else b''))
            await writer.drain()
            record('http', {'method': method, 'servedPath': parsed.path, 'status': status, 'bytes': len(body) if method == 'GET' else 0})
            return
        if args.media and method == 'GET' and parsed.hostname == 'proxy-redirect.invalid':
            target = 'https://raw.githubusercontent.com/AntennaPod/AntennaPod/f8c641887e4677237b01b6e942ff8fe20fc8beec/app/src/androidTest/assets/30sec.mp3'
            writer.write(('HTTP/1.1 302 Found\r\nLocation: ' + target + '\r\nContent-Length: 0\r\nConnection: close\r\n\r\n').encode())
            await writer.drain()
            return
        if args.media and method in ['GET', 'HEAD'] and parsed.hostname == 'proxy-feed.invalid':
            if parsed.path == '/feed.xml':
                query = parse_qs(parsed.query)
                session = query.get('session', ['fixture'])[0]
                mode = query.get('mode', ['progressive'])[0]
                path = '/hls/' + session + '/index.m3u8' if mode == 'playlist' else '/episode-open-ended.mp3' if mode == 'open-ended' else '/episode.mp3'
                if mode == 'encrypted':
                    path = '/encrypted/' + session + '/master.m3u8'
                if mode == 'live-recovery':
                    path = '/episode-live-recovery.mp3'
                enclosure = escape('http://proxy-feed.invalid' + path + '?' + parsed.query, quote=True)
                media_type = 'application/vnd.apple.mpegurl' if mode in ['playlist', 'encrypted'] else 'audio/mpeg'
                feed = ('<rss version="2.0"><channel><title>Proxy fixture</title>'
                        '<link>https://www.example.com</link><description>Owned proxy feed</description>'
                        '<item><guid>proxy-episode</guid><title>Proxy downloaded episode</title>'
                        '<enclosure url="' + enclosure + '" type="' + media_type + '" length="' + str(args.media.stat().st_size if mode == 'progressive' else 0) + '" />'
                        '</item></channel></rss>')
                body, mime = feed.encode(), 'application/rss+xml'
            elif parsed.path.startswith('/hls/') and args.hls:
                file = args.hls / Path(parsed.path).name
                if not file.is_file() or file.suffix not in ['.m3u8', '.ts']:
                    return
                body, mime = file.read_bytes(), 'application/vnd.apple.mpegurl' if file.suffix == '.m3u8' else 'video/mp2t'
                if file.suffix == '.m3u8':
                    # Three valid discontinuous copies give the UI enough time for pause/relaunch.
                    original = body.decode()
                    segment_start = original.index('#EXTINF:')
                    segments = original[segment_start:].replace('#EXT-X-ENDLIST', '').strip()
                    body = (original[:segment_start] + ('\n#EXT-X-DISCONTINUITY\n'.join([segments] * 3)) + '\n#EXT-X-ENDLIST\n').encode()
            elif parsed.path == '/episode-live-recovery.mp3' and args.live_media:
                session = parse_qs(parsed.query).get('session', ['fixture'])[0]
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
                if method == 'GET':
                    now = time.monotonic()
                    state = live_streams.setdefault(session, {'started': now, 'reconnects': []})
                    elapsed = now - state['started']
                    audio = args.live_media.read_bytes()
                    body = audio[:len(audio) // 2] if elapsed < 12 else audio
                    if elapsed > 2:
                        state['reconnects'].append(now)
                    writer.write(('%x\r\n' % len(body)).encode() + body + b'\r\n')
                    await writer.drain()
                    record('http', {'method': method, 'servedPath': parsed.path, 'query': parsed.query,
                                    'bytes': len(body), 'elapsed': elapsed, 'range': headers.get('range'), 'heldWithoutEOF': True})
                    await reader.read()
                return
            elif parsed.path == '/episode-open-ended.mp3':
                prefix = args.media.read_bytes()[:args.media.stat().st_size * 3 // 4]
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
                if method == 'GET':
                    writer.write(('%x\r\n' % len(prefix)).encode() + prefix + b'\r\n')
                    await writer.drain()
                    record('http', {'method': method, 'servedPath': parsed.path, 'query': parsed.query, 'bytes': len(prefix), 'heldWithoutEOF': True})
                    await reader.read()
                return
            elif parsed.path == '/episode.mp3':
                body, mime = args.media.read_bytes(), 'audio/mpeg'
            else:
                return
            writer.write(('HTTP/1.1 200 OK\r\nContent-Type: ' + mime + '\r\nContent-Length: ' + str(len(body)) + '\r\nConnection: close\r\n\r\n').encode() + (body if method == 'GET' else b''))
            await writer.drain()
            record('http', {'method': method, 'servedPath': parsed.path, 'query': parsed.query, 'bytes': len(body) if method == 'GET' else 0})
            return
        if method != 'CONNECT' or target not in ['www.example.com:443', 'raw.githubusercontent.com:443']:
            return
        host, port = target.rsplit(':', 1)
        await tunnel(reader, writer, 'http', (host, int(port)))
    except Exception as error:
        record('http', {'errorType': type(error).__name__})
    finally:
        writer.close()

async def socks(reader, writer):
    try:
        version, count = await reader.readexactly(2)
        methods = await reader.readexactly(count)
        record('socks', {'version': version, 'methods': list(methods)})
        if version != 5 or 2 not in methods:
            writer.write(b'\x05\xff'); await writer.drain(); return
        writer.write(b'\x05\x02'); await writer.drain()
        version, length = await reader.readexactly(2)
        user = await reader.readexactly(length)
        length = (await reader.readexactly(1))[0]
        password = await reader.readexactly(length)
        authenticated = version == 1 and user == b'fixture-user' and password == b'fixture-secret'
        record('socks', {'authenticated': authenticated})
        writer.write(b'\x01' + (b'\x00' if authenticated else b'\x01')); await writer.drain()
        if not authenticated: return
        version, command, _, address_type = await reader.readexactly(4)
        if version != 5 or command != 1: return
        if address_type == 3:
            length = (await reader.readexactly(1))[0]
            host = (await reader.readexactly(length)).decode('ascii')
        elif address_type == 1:
            host = '.'.join(str(b) for b in await reader.readexactly(4))
        else: return
        port = int.from_bytes(await reader.readexactly(2), 'big')
        await tunnel(reader, writer, 'socks', (host, port))
    except Exception as error:
        record('socks', {'errorType': type(error).__name__})
    finally:
        writer.close()

async def main():
    args.report.write_text(json.dumps(report))
    first = await asyncio.start_server(http, '127.0.0.1', args.http_port)
    second = await asyncio.start_server(socks, '127.0.0.1', args.socks_port)
    print('Owned proxy listeners ready', flush=True)
    async with first, second:
        await asyncio.gather(first.serve_forever(), second.serve_forever())

asyncio.run(main())
