"""Lossless audio remux plus QuickTime per-track title metadata; coded bytes unchanged."""
import hashlib, json, os, struct, subprocess, sys
from pathlib import Path
source, intermediate, output = map(Path, sys.argv[1:])
# The tools on PATH; FFMPEG and FFPROBE override them.
FFMPEG, FFPROBE = os.environ.get('FFMPEG', 'ffmpeg'), os.environ.get('FFPROBE', 'ffprobe')
command = [FFMPEG, '-v', 'error', '-nostdin', '-n', '-i', str(source), '-map', '0:a', '-vn', '-c', 'copy', str(intermediate)]
subprocess.run(command, check=True)
def box(kind, payload):
    return struct.pack('>I', len(payload) + 8) + kind + payload
def boxes(data):
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack('>I4s', data[offset:offset+8])
        assert size >= 8 and offset + size <= len(data)
        yield kind, data[offset+8:offset+size]
        offset += size
result = b''
titles = iter(['English 440 Hz', 'Deutsch 880 Hz'])
for kind, payload in boxes(intermediate.read_bytes()):
    if kind == b'moov':
        children = b''
        for child, body in boxes(payload):
            if child == b'trak':
                title = next(titles).encode('utf-8')
                # QuickTime udta text carries UInt16 length and language code.
                body += box(b'udta', box(b'\xa9nam', struct.pack('>HH', len(title), 0) + title))
            children += box(child, body)
        payload = children
    result += box(kind, payload)
# Default remux puts moov after mdat; adding title atoms cannot shift media offsets.
assert intermediate.read_bytes().index(b'mdat') < intermediate.read_bytes().index(b'moov')
with output.open('xb') as handle: handle.write(result)
probe = json.loads(subprocess.check_output([FFPROBE,'-v','error','-show_streams','-show_format','-of','json',str(output)]))
checks = []
for index in range(2):
    args = [FFMPEG,'-v','error','-i']
    pcm = subprocess.check_output(args+[str(output),'-map',f'0:a:{index}','-f','s16le','-c:a','pcm_s16le','-'])
    original = subprocess.check_output(args+[str(source),'-map',f'0:a:{index}','-f','s16le','-c:a','pcm_s16le','-'])
    assert pcm == original and len(pcm) == 384000 * 2
    # Independently decode compressed packet payloads and compare stream hashes.
    hashes = []
    for path in [source, output]:
        hashes.append(subprocess.check_output(args+[str(path),'-map',f'0:a:{index}','-c','copy','-f','hash','-hash','sha256','-']).decode().strip())
    assert hashes[0] == hashes[1]
    checks.append({'trackID':index,'samples':len(pcm)//2,'rate':48000,'toneHz':[440,880][index],'pcmSHA256':hashlib.sha256(pcm).hexdigest(),'unchangedCodedPayload':hashes[0]})
manifest={'source':source.name,'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'command':command,'titleMetadata':'QuickTime trak/udta/©nam UTF8 length and language header; media offsets unchanged','sha256':hashlib.sha256(result).hexdigest(),'checks':checks,'probe':probe}
output.with_suffix('.provenance.json').write_text(json.dumps(manifest,indent=2)+'\n')
