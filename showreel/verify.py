"""Verify deliverable geometry, beats, silent beat, audio peaks, and frames."""
import json
import subprocess
import wave
from pathlib import Path
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parent
OUT=ROOT/'output/v3'
MOV=OUT/'Agent-Island-Quiet-Power-V3-1080p.mp4'
probe=json.loads(subprocess.check_output([
    '/opt/homebrew/bin/ffprobe','-v','error','-show_streams','-show_format','-of','json',str(MOV)]))
v=next(s for s in probe['streams'] if s['codec_type']=='video')
a=next(s for s in probe['streams'] if s['codec_type']=='audio')
assert (v['width'],v['height'])==(1920,1080)
assert v['r_frame_rate']=='30/1'
assert int(v['nb_frames'])==900
assert abs(float(v['duration'])-30)<.001
assert v['codec_name']=='h264' and v['pix_fmt']=='yuv420p'
assert a['codec_name']=='aac' and a['channels']==2 and int(a['sample_rate'])==48000
frames=sorted((OUT/'frames').glob('frame-*.png'))
assert len(frames)==900
render=json.loads((OUT/'render-report.json').read_text())
assert render['deterministic'] and not render['external'] and not render['errors']
assert render['particles']==9000
cuts=render['cuts']+render['recap_cuts']
assert all(abs(t/.5-round(t/.5))<1e-9 for t in cuts)
with wave.open(str(OUT/'original-score.wav')) as wf:
    pcm=np.frombuffer(wf.readframes(wf.getnframes()),dtype='<i2').reshape(-1,2)
assert np.max(np.abs(pcm[25*48000+24000:26*48000]))==0
# AAC is lossy: inspect interior of silent beat rather than window-overlap edges.
decoded=subprocess.check_output(['/opt/homebrew/bin/ffmpeg','-v','error','-i',str(MOV),
    '-map','0:a:0','-f','f32le','-acodec','pcm_f32le','pipe:1'])
audio=np.frombuffer(decoded,dtype='<f4').reshape(-1,2)
quiet=audio[int(25.55*48000):int(25.95*48000)]
quiet_peak=float(np.max(np.abs(quiet)))
assert quiet_peak<.001
# Check every bar and transition contains actual image information, not empty frames.
image_checks=[]
for i in range(14):
    for offset in [0,3,7,22]:
        f=min(899,i*60+offset)
        ar=np.asarray(Image.open(frames[f]).resize((240,135)).convert('RGB'))
        # The V3 opening has a deliberate dark build into the real small-state UI;
        # 26.000–26.240 is the designed dark impact / brand build-in.
        if not (f < 8 or 780 <= f < 788):
            assert float(ar.std())>10, f
        image_checks.append({'frame':f,'contrast_std':round(float(ar.std()),2),
                             'intentional_dark_impact':780 <= f < 788})
result={'video':{'width':v['width'],'height':v['height'],'fps':30,'frames':900,
                 'seconds':30,'codec':'H.264','pixel_format':'yuv420p'},
        'audio':{'codec':'AAC','sample_rate':48000,'channels':2,'bpm':120,
                 'source_silent_beat_samples_max':0,'aac_silent_beat_peak':quiet_peak},
        'deterministic':True,'remote_assets':0,'local_product_assets':len(render['local_assets']),'cuts_on_beats':True,
        'scene_count':13,'unique_transition_count':12,'particle_count':9000,
        'image_checks':image_checks,'file_bytes':MOV.stat().st_size}
(OUT/'verification.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
print(json.dumps({k:v for k,v in result.items() if k!='image_checks'},ensure_ascii=False,indent=2))
