from pathlib import Path
import subprocess,shutil,json,hashlib,struct,os
FFMPEG,FFPROBE=os.environ.get('FFMPEG','ffmpeg'),os.environ.get('FFPROBE','ffprobe')  # the tools on PATH unless overridden
out=Path('.work/playback-completion/decoder-build/fixtures');out.mkdir(exist_ok=False)
root=Path('.work/playback-completion/android-runtime/fixtures')
names=['amr-nb.amr','amr-wb.amr','ogg-flac.ogg','wav-u8.wav','wav-s24.wav','wav-float.wav','wav-ima.wav','wav-alaw.wav','wav-mulaw.wav','video-multitrack.mp4','mpeg-ts.ts','video.flv','video.avi','video-vp8-opus.webm','video-vp9-vorbis.webm']
for n in names:shutil.copy2(root/n,out/n)
for n in ['hevc.mp4','hevc.mkv','av1.mp4','av1.mkv']:shutil.copy2(Path('.work/playback-completion/android-runtime/conditional/fixtures')/n,out/n)
shutil.copy2('.work/playback-completion/decoder-build/probe-results/fragmented.mp4',out/'fragmented.mp4')
commands=[]
def ff(args):
 cmd=[FFMPEG,'-v','error','-nostdin','-n']+args;commands.append(cmd);subprocess.run(cmd,check=True)
ff(['-i',str(root/'video-multitrack.mp4'),'-map','0:v','-an','-c','copy',str(out/'video-only.mp4')])
# AVI chunk layout is explicitly rearranged without altering compressed media.
# Keep all video packets before any PCM chunk to exercise skew independent of mux heuristics.
data=(root/'video.avi').read_bytes(); pos=12;hdrl=None;movi=None
while pos+8<=len(data):
 typ=data[pos:pos+4];size=int.from_bytes(data[pos+4:pos+8],'little');body=data[pos+8:pos+8+size]
 if typ==b'LIST' and body[:4]==b'hdrl':hdrl=bytearray(data[pos:pos+8+size])
 if typ==b'LIST' and body[:4]==b'movi':movi=body[4:]
 pos+=8+size+(size&1)
assert hdrl and movi
# Clear AVIF_HASINDEX; the demuxer scans valid chunks and builds its own index.
a=hdrl.index(b'avih')+8;flags=int.from_bytes(hdrl[a+12:a+16],'little')&~0x10;hdrl[a+12:a+16]=flags.to_bytes(4,'little')
chunks=[];pos=0
while pos+8<=len(movi):
 size=int.from_bytes(movi[pos+4:pos+8],'little');chunk=movi[pos:pos+8+size+(size&1)];assert len(chunk)==8+size+(size&1);chunks.append(chunk);pos+=len(chunk)
video=[c for c in chunks if c[:4]==b'00dc'];audio=[c for c in chunks if c[:4]==b'01wb'];assert len(video)==75 and audio
body=b'AVI '+hdrl+b'LIST'+struct.pack('<I',4+sum(map(len,video+audio)))+b'movi'+b''.join(video+audio)
(out/'skewed.avi').write_bytes(b'RIFF'+struct.pack('<I',len(body))+body)
# Two individually valid ADTS periods with changed sample rate/channel layout.
for rate,ch in [(48000,1),(24000,2)]:ff(['-i',str(root/'tone.wav'),'-t','1','-ar',str(rate),'-ac',str(ch),'-c:a','aac','-f','adts',str(out/f'part-{rate}.aac')])
(out/'changing.aac').write_bytes((out/'part-48000.aac').read_bytes()+(out/'part-24000.aac').read_bytes())
# Real in-band H264 geometry transition in a single transport stream.
for num,size in [(1,'320x180'),(2,'160x90')]:ff(['-i',str(root/'video-master.mkv'),'-t','1','-an','-vf','scale='+size,'-c:v','libx264','-threads','1','-g','25','-output_ts_offset',str(num-1),'-mpegts_flags','+initial_discontinuity','-f','mpegts',str(out/f'part-video{num}.ts')])
(out/'changing-video.ts').write_bytes((out/'part-video1.ts').read_bytes()+(out/'part-video2.ts').read_bytes())
manifest={'commands':commands,'sourceManifests':['.work/playback-completion/android-runtime/fixtures/manifest.json','.work/playback-completion/android-runtime/conditional/fixtures/manifest.json'],'files':{}}
for p in out.iterdir():
 if p.is_file():
  probe=subprocess.run([FFPROBE,'-v','error','-show_streams','-show_format','-of','json',str(p)],capture_output=True,text=True,check=True)
  manifest['files'][p.name]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size,'probe':json.loads(probe.stdout)}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
