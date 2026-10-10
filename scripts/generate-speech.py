#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import wave
import hashlib
root = Path(__file__).resolve().parent.parent
config = json.loads((root/'bench/speech-fixtures.json').read_text())
output = root/'bench/results/audio'; output.mkdir(parents=True, exist_ok=True)
metadata = []
for clip in config['clips']:
    source = output/(clip['id']+'.aiff')
    destination = output/(clip['id']+'.wav')
    subprocess.run(['say', '-v', config['voice'], '-r', str(config['words_per_minute']), '-o', str(source), clip['text']], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(source), str(destination)], check=True)
    with wave.open(str(destination), 'rb') as audio:
        parameters = audio.getparams(); frames = audio.readframes(audio.getnframes())
        if audio.getnframes() == 0 or audio.getframerate() != 16000 or audio.getnchannels() != 1:
            destination.unlink()
            raise RuntimeError('Speech generation produced no valid samples; the say process needs normal macOS access')
        speech_seconds = audio.getnframes() / audio.getframerate()
    if 'duration_seconds' in clip:
        target = int(clip['duration_seconds'] * 16000)
        if parameters.nframes > target:
            raise RuntimeError('Synthetic utterance exceeds target duration; adjust fixture text instead of clipping speech')
        frames += bytes((target - parameters.nframes) * parameters.sampwidth)
        with wave.open(str(destination), 'wb') as audio:
            audio.setparams(parameters); audio.writeframes(frames)
    metadata.append(dict(id=clip['id'], speech_seconds=speech_seconds,
                         container_seconds=len(frames)/32000,
                         sha256=hashlib.sha256(destination.read_bytes()).hexdigest()))
(output/'metadata.json').write_text(json.dumps(dict(voice=config['voice'], words_per_minute=config['words_per_minute'],
    macOS_build=subprocess.check_output(['sw_vers','-buildVersion'], text=True).strip(), clips=metadata), indent=2)+'\n')
print('Synthetic speech written to bench/results/audio; no ASR accuracy has been measured.')
