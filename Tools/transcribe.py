from faster_whisper import WhisperModel
import json, wave, numpy as np
from pathlib import Path
model=WhisperModel('small',device='cpu',compute_type='int8',cpu_threads=8,download_root='Work/models')
all_segments={}
for name in ['source1','source2']:
 with wave.open('Work/asr'+name[-1]+'.wav') as w:
  samples=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(np.float32)/32768
 segments,info=model.transcribe(samples,language='zh',word_timestamps=True,beam_size=5,vad_filter=False,condition_on_previous_text=False)
 rows=[]
 for s in segments:
  row={'start':s.start,'end':s.end,'text':s.text,'words':[{'start':w.start,'end':w.end,'word':w.word} for w in (s.words or [])]}
  rows.append(row); print(name,json.dumps(row,ensure_ascii=False),flush=True)
 all_segments[name]=rows
Path('Work/transcript.json').write_text(json.dumps(all_segments,ensure_ascii=False,indent=2))
