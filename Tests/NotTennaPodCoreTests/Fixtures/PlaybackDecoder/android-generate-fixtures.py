from pathlib import Path
import subprocess,json,hashlib,wave,struct,math,os
FFMPEG,FFPROBE=os.environ.get('FFMPEG','ffmpeg'),os.environ.get('FFPROBE','ffprobe')  # the tools on PATH unless overridden
r=Path(__file__).resolve().parent;f=r/'fixtures';f.mkdir(exist_ok=True); records=[]
def run(args):
 p=subprocess.run(args,capture_output=True,text=True); assert p.returncode==0,(args,p.stderr);return p.stdout
def gen(name,args):
 cmd=[FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-n']+args+[str(f/name)];(run(cmd) if not (f/name).exists() else None); records.append({'name':name,'command':cmd})
for name,freq in [('tone',440),('av440',440),('av880',880)]:
 with wave.open(str(f/(name+'.wav')),'wb') as w:
  w.setparams((1,2,48000,0,'NONE','not compressed')); length=3 if name=='tone' else 8
  w.writeframes(b''.join(struct.pack('<h',int(10000*math.sin(2*math.pi*freq*i/48000)) if name=='tone' or (i//96000)%2==0 else 0)for i in range(48000*length)))
for codec,suffix in [('pcm_u8','u8'),('pcm_s24le','s24'),('pcm_f32le','float'),('adpcm_ima_wav','ima'),('adpcm_ms','ms'),('pcm_alaw','alaw'),('pcm_mulaw','mulaw')]:gen('wav-'+suffix+'.wav',['-i',str(f/'tone.wav'),'-c:a',codec])
gen('ogg-flac.ogg',['-i',str(f/'tone.wav'),'-c:a','flac','-f','ogg'])
# Video has visible independently known two-second segments and burned-in media timestamp.
# Dependency-free frame number glyphs; presentation timestamp is frame / 25 seconds.
glyphs={"0":["111","101","101","101","111"],"1":["010","110","010","010","111"],"2":["111","001","111","100","111"],"3":["111","001","111","001","111"],"4":["101","101","111","001","001"],"5":["111","100","111","001","111"],"6":["111","100","111","101","111"],"7":["111","001","010","010","010"],"8":["111","101","111","101","111"],"9":["111","101","111","001","111"]}
raw=f/'frames.rgb'
with raw.open('wb') as out:
 for frame in range(200):
  color=[(220,0,0),(0,0,220),(0,180,0),(200,180,0)][frame//50]; pixels=bytearray(bytes(color)*320*180)
  for n,char in enumerate(f'{frame:03d}'):
   for y,row in enumerate(glyphs[char]):
    for x,bit in enumerate(row):
     if bit=='1':
      for dy in range(6):
       for dx in range(6):
        offset=((70+y*6+dy)*320+100+n*30+x*6+dx)*3; pixels[offset:offset+3]=bytes((255,255,255))
  out.write(pixels)
gen('video-master.mkv',['-f','rawvideo','-pixel_format','rgb24','-video_size','320x180','-framerate','25','-i',str(raw),'-i',str(f/'av440.wav'),'-c:v','ffv1','-c:a','pcm_s16le','-t','8'])
gen('video-multitrack.mp4',['-i',str(f/'video-master.mkv'),'-i',str(f/'av880.wav'),'-map','0:v','-map','0:a','-map','1:a','-c:v','libx264','-preset','fast','-pix_fmt','yuv420p','-g','25','-c:a','aac','-b:a','96k','-metadata:s:a:0','language=eng','-metadata:s:a:1','language=deu','-movflags','+faststart'])
for name,vc,ac,extra in [('video-vp8-opus.webm','libvpx','libopus',[]),('video-vp9-vorbis.webm','libvpx-vp9','vorbis',['-strict','experimental','-ac','2']),('mpeg-ts.ts','libx264','aac',['-f','mpegts']),('mpeg-ps.mpg','mpeg2video','mp2',['-f','mpeg']),('video.flv','libx264','aac',['-f','flv']),('video.avi','mpeg4','pcm_s16le',['-f','avi'])]:
 gen(name,['-i',str(f/'video-master.mkv'),'-t','3','-c:v',vc,'-pix_fmt','yuv420p','-g','25','-c:a',ac]+extra)
for p in f.iterdir():
 if p.suffix in ['.json','.txt','.rgb']:continue
 probe=json.loads(run([FFPROBE,'-v','error','-show_streams','-show_format','-of','json',str(p)]))
 run([FFMPEG,'-v','error','-i',str(p),'-f','null','-'])
 rec=next((x for x in records if x['name']==p.name),{'name':p.name,'generator':'Python deterministic monoPCM16 wave; amplitude10000, rate48000,440/880Hz; alternating2s signal/silence for AV'})
 rec.update(sha256=hashlib.sha256(p.read_bytes()).hexdigest(),bytes=p.stat().st_size,ffprobe=probe,independentDecode='ffmpeg -f null passes')
 if rec not in records:records.append(rec)
(f/'manifest.json').write_text(json.dumps(records,indent=2)+'\n')
assets=r/'checkout/app/src/playbackProbe/assets';assets.mkdir(parents=True,exist_ok=True)
import shutil
for p in f.iterdir():
 if p.name not in ['video-master.mkv','tone.wav','av440.wav','av880.wav','manifest.json','frames.rgb']:shutil.copyfile(p,assets/p.name)
shutil.copyfile('Tests/NotTennaPodCoreTests/Fixtures/playback-30sec.mp3',assets/'control.mp3')
print(len(records),'valid fixtures')
