"""Jarvis HEAR worker: speech to text, fully local (faster-whisper).

Protocol: one JSON line in per request: {"path": "/tmp/clip.m4a"}
          one JSON line out:            {"text": "..."} or {"text": "", "rejected": "why"}
The model stays loaded between requests.
"""
import os, sys, json

# Libraries sometimes print at import time. Keep a clean copy of stdout for the
# JSON protocol and send everything else to stderr.
_proto = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)

os.environ.setdefault("HF_HOME", os.path.join(os.path.dirname(__file__), "models"))
import numpy as np
import subprocess
from faster_whisper import WhisperModel

MODELS = os.path.join(os.path.dirname(__file__), "models")
# A plain copy of the model folder (used on Windows, where the HF cache's symlinks don't copy) wins if present.
LOCAL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "whisper-turbo")
model = WhisperModel(LOCAL if os.path.isfile(os.path.join(LOCAL, "model.bin")) else "large-v3-turbo",
                     device="cpu", compute_type="int8", download_root=MODELS, cpu_threads=8)

# Names Whisper should spell right.
NAMES = "Jarvis, Jellyfin, Tailscale, MakeMKV."

SR = 16000


def gate(audio):
    """Reject silence and room noise before Whisper sees it (Whisper invents words from silence)."""
    dur = len(audio) / SR
    if dur < 0.35:
        return "too short"
    rms = float(np.sqrt(np.mean(audio ** 2))) if len(audio) else 0.0
    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    if rms < 0.004 or peak < 0.02:
        return "too quiet"
    frame = int(0.03 * SR)
    n = len(audio) // frame
    if n == 0:
        return "too short"
    frames = audio[: n * frame].reshape(n, frame)
    frms = np.sqrt(np.mean(frames ** 2, axis=1))
    floor = max(float(np.percentile(frms, 10)), 1e-5)
    if int(np.sum(frms > 3 * floor)) < 8:
        return "no speech"
    return None


def looks_looped(text):
    words = text.lower().replace(",", " ").replace(".", " ").split()
    if not words:
        return True
    if len(words) >= 6:
        uniq = len(set(words))
        if uniq <= 2 or uniq / len(words) < 0.25:
            return True
    return False


def decode_audio(path):
    """Decode any clip (iPhone m4a, webm, wav) to 16 kHz mono float32 with ffmpeg."""
    raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR),
                          "-f", "f32le", "-"], capture_output=True, check=True, timeout=60).stdout
    return np.frombuffer(raw, dtype=np.float32).copy()


def transcribe(path):
    audio = decode_audio(path)
    why = gate(audio)
    if why:
        return {"text": "", "rejected": why}
    segments, _ = model.transcribe(
        audio, language="en", beam_size=5, initial_prompt=NAMES,
        condition_on_previous_text=False, temperature=(0.0, 0.2),
        no_speech_threshold=0.6, compression_ratio_threshold=2.4, vad_filter=False)
    text = " ".join(s.text.strip() for s in segments).strip()
    if not text or looks_looped(text):
        return {"text": "", "rejected": "unclear"}
    return {"text": text}


_proto.write(json.dumps({"ready": True}) + "\n")
for line in sys.stdin:
    try:
        req = json.loads(line)
        out = transcribe(req["path"])
    except Exception as e:
        out = {"text": "", "error": str(e)[:200]}
    _proto.write(json.dumps(out) + "\n")
