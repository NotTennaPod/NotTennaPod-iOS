"""Deterministic 96-second selected-app video journey. No microphone or external media."""
from pathlib import Path
import hashlib, json, math, os, struct, subprocess, tempfile, wave
ROOT = Path(__file__).resolve().parent
# The tools on PATH; FFMPEG and FFPROBE override them.
FFMPEG, FFPROBE = os.environ.get('FFMPEG', 'ffmpeg'), os.environ.get('FFPROBE', 'ffprobe')
GLYPHS = {'0':['111','101','101','101','111'],'1':['010','110','010','010','111'],
'2':['111','001','111','100','111'],'3':['111','001','111','001','111'],
'4':['101','101','111','001','001'],'5':['111','100','111','001','111'],
'6':['111','100','111','101','111'],'7':['111','001','010','010','010'],
'8':['111','101','111','101','111'],'9':['111','101','111','001','111']}
def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout
with tempfile.TemporaryDirectory(prefix='video-fixture-') as temp:
    temp = Path(temp)
    for hz in (440,880):
        with wave.open(str(temp/f'{hz}.wav'), 'wb') as out:
            out.setparams((1,2,48000,0,'NONE','not compressed'))
            tone = b''.join(struct.pack('<h', round(10000*math.sin(2*math.pi*hz*i/48000))) for i in range(48000))
            for second in range(96): out.writeframes(tone if (second//2)%2 == 0 else bytes(96000))
    command = [FFMPEG,'-hide_banner','-loglevel','error','-nostdin','-n','-f','rawvideo','-pixel_format','rgb24',
        '-video_size','320x180','-framerate','25','-i','pipe:0','-i',str(temp/'440.wav'),'-i',str(temp/'880.wav'),
        '-map','0:v','-map','1:a','-map','2:a','-c:v','libx264','-threads','2','-preset','fast','-pix_fmt','yuv420p',
        '-g','25','-c:a','aac','-b:a','96k','-metadata:s:a:0','language=eng','-metadata:s:a:1','language=deu',
        '-movflags','+faststart',str(ROOT/'journey.mp4')]
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    for frame in range(2400):
        color = [(220,0,0),(0,0,220),(0,180,0),(200,180,0)][(frame//50)%4]
        pixels = bytearray(bytes(color)*320*180)
        for n,char in enumerate(f'{frame:04d}'):
            for y,row in enumerate(GLYPHS[char]):
                for x,bit in enumerate(row):
                    if bit == '1':
                        for dy in range(6):
                            for dx in range(6):
                                offset = ((70+y*6+dy)*320+95+n*30+x*6+dx)*3
                                pixels[offset:offset+3] = bytes((255,255,255))
        process.stdin.write(pixels)
    process.stdin.close()
    stderr = process.stderr.read().decode(); assert process.wait() == 0, stderr
path = ROOT/'journey.mp4'
probe = json.loads(run([FFPROBE,'-v','error','-count_frames','-show_streams','-show_format','-of','json',str(path)]))
assert [(x['codec_type'],x['codec_name']) for x in probe['streams']] == [('video','h264'),('audio','aac'),('audio','aac')]
assert int(probe['streams'][0]['nb_read_frames']) == 2400
run([FFMPEG,'-v','error','-i',str(path),'-map','0','-f','null','-'])
(ROOT/'manifest.json').write_text(json.dumps({'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
    'bytes':path.stat().st_size,'generator':'generate.py; original synthetic public-domain fixture',
    'oracle':'Burned-in integer is frame index; source seconds = index/25. Color cycles red,blue,green,yellow every2s. Both mono48k audio tracks alternate2s tone/2s silence. English440Hz; German880Hz.',
    'independentValidation':'ffprobe counted2400 frames; ffmpeg decoded all3streams without error',
    'ffmpegVersion':run([FFMPEG,'-version']).splitlines()[0],'ffprobe':probe},indent=2)+'\n')
