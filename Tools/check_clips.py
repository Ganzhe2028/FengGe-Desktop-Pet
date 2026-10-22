from faster_whisper import WhisperModel
import numpy as np, wave, subprocess, json
model=WhisperModel('small',device='cpu',compute_type='int8',cpu_threads=8,download_root='Work/models',local_files_only=True)
rows=[]
for clip in json.load(open('Assets/clips.json')):
 subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1','Assets/Clips/'+clip['file'],'Work/check.wav'],check=True)
 with wave.open('Work/check.wav') as w:
  assert w.getframerate()==16000
  samples=np.frombuffer(w.readframes(w.getnframes()),dtype=np.int16).astype(np.float32)/32768
 segments,_=model.transcribe(samples,language='zh',beam_size=5,vad_filter=False,condition_on_previous_text=False)
 text=''.join(s.text for s in segments)
 row={'id':clip['id'],'expected':clip['label'],'recognized':text}
 rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
json.dump(rows,open('Work/clip-check.json','w'),ensure_ascii=False,indent=2)
