"""Jarvis SPEAK worker: text to speech, fully local (Kokoro).

Protocol: one JSON line in:  {"text": "...", "voice": "bm_george", "speed": 1.05}
          one JSON line out: {"wav_b64": "..."} or {"error": "..."}
"""
import os, sys, json, io, base64

_proto = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)

import soundfile as sf
from kokoro_onnx import Kokoro

HERE = os.path.dirname(os.path.abspath(__file__))
tts = Kokoro(os.path.join(HERE, "kokoro-v1.0.onnx"), os.path.join(HERE, "voices-v1.0.bin"))


def speak(text, voice, speed):
    lang = "en-gb" if voice.startswith("b") else "en-us"
    samples, sr = tts.create(text, voice=voice, speed=speed, lang=lang)
    buf = io.BytesIO()
    sf.write(buf, samples, sr, format="WAV", subtype="PCM_16")
    return base64.b64encode(buf.getvalue()).decode()


_proto.write(json.dumps({"ready": True, "voices": sorted(v for v in tts.get_voices())}) + "\n")
for line in sys.stdin:
    try:
        req = json.loads(line)
        out = {"wav_b64": speak(req["text"], req.get("voice", "bm_george"), float(req.get("speed", 1.05)))}
    except Exception as e:
        out = {"error": str(e)[:200]}
    _proto.write(json.dumps(out) + "\n")
