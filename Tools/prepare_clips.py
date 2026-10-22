import json, wave
from pathlib import Path
import numpy as np

cuts=[
 ('source1',0.04,1.115,'这个是个好事'),
 ('source1',1.115,2.03,'这是个好事'),
 ('source1',2.03,3.685,'是个好事'),
 ('source1',3.685,4.775,'这是个好事啊'),
 ('source1',4.775,6.055,'这是一个好事啊'),
 ('source1',6.055,7.14,'这是个好事啊'),
 ('source1',7.14,8.6465,'那这是个好事吗'),
 ('source2',0.04,0.91,'挺好的啊'),
 ('source2',0.91,2.065,'这是个好事啊'),
 ('source2',2.065,3.00,'对你挺好的'),
 ('source2',3.30,4.70,'人有欲望是好事'),
]
source_names={'source1':'这是个好事(1).mp3','source2':'10月22日 (1).mp3'}
clips=[]; provenance=[]
for i,(source,start,end,label) in enumerate(cuts,1):
 with wave.open(f'Work/{source}.wav') as w:
  sr=w.getframerate(); channels=w.getnchannels()
  audio=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).reshape(-1,channels).astype(np.float64)/32768
 clip=audio[round(start*sr):round(end*sr)].copy()
 rms=float(np.sqrt(np.mean(clip**2))); peak=float(np.abs(clip).max())
 gain=min(10**(-20/20)/max(rms,1e-6),10**(-1/20)/max(peak,1e-6),3.0)
 clip*=gain
 # Five-millisecond ramps only at the quiet edit boundaries prevent clicks.
 fade=min(round(.005*sr),len(clip)//2)
 clip[:fade]*=np.linspace(0,1,fade)[:,None]; clip[-fade:]*=np.linspace(1,0,fade)[:,None]
 out=np.clip(np.rint(clip*32767),-32768,32767).astype(np.int16)
 filename=f'{i:02d}.wav'
 with wave.open(f'Assets/Clips/{filename}','wb') as w:
  w.setnchannels(channels);w.setsampwidth(2);w.setframerate(sr);w.writeframes(out.tobytes())
 duration=len(out)/sr
 clips.append(dict(id=i,label=label,file=filename,duration=duration))
 provenance.append(dict(id=i,original=source_names[source],start=start,end=end,label=label,gain_db=round(20*np.log10(gain),2),duration=duration))
Path('Assets/clips.json').write_text(json.dumps(clips,ensure_ascii=False,indent=2))
Path('Work/cuts.json').write_text(json.dumps(provenance,ensure_ascii=False,indent=2))
print(json.dumps(provenance,ensure_ascii=False,indent=2))
