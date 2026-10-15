"""Life OS transcription worker - transcribes a batch of audio files with faster-whisper.

Called by transcribe.ps1 (never by a person directly). One WhisperModel is loaded for the whole
batch. For every file it writes a UTF-8 .txt next to the audio file (same base name), sets the
.txt modification time to the audio's, and prints one JSON object per file on stdout. The last
line is a summary object. Errors per file are reported, the batch continues.

Usage:
  python transcribe_worker.py --model large-v3-turbo [--language de] FILE [FILE ...]
  python transcribe_worker.py --selftest [--model small]

Output contract (one JSON object per line):
  {"type": "file", "audio": ..., "txt": ..., "ok": true, "device": ..., "compute": ...,
   "audio_seconds": ..., "seconds": ..., "rtf": ..., "chars": ...}
  {"type": "file", "audio": ..., "ok": false, "error": "..."}
  {"type": "summary", "ok": n, "failed": n, "model": ..., "device": ..., "compute": ...}
"""

import argparse
import json
import os
import site
import sys
import time
from glob import glob
from pathlib import Path


def add_cuda_dll_dirs():
    """Make the pip-installed NVIDIA libraries (nvidia-*-cu12) findable on Windows.

    ctranslate2 loads cuBLAS and cuDNN at runtime; the pip wheels put the DLLs under
    site-packages/nvidia/<lib>/bin, which is not on the search path by default.
    """
    added = []
    for sp in site.getsitepackages():
        for dll_dir in glob(os.path.join(sp, "nvidia", "*", "bin")):
            if os.path.isdir(dll_dir):
                try:
                    os.add_dll_directory(dll_dir)
                except (AttributeError, OSError):
                    pass
                os.environ["PATH"] = dll_dir + os.pathsep + os.environ.get("PATH", "")
                added.append(dll_dir)
    return added


os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")  # quiet the cache warning


def load_model(model_name, prefer_cuda=True):
    """Load the model, with a quiet fallback from CUDA to CPU.

    Returns (model, device, compute_type). Tries float16 on the GPU first, then int8 on the CPU.
    """
    from faster_whisper import WhisperModel

    if prefer_cuda:
        try:
            model = WhisperModel(model_name, device="cuda", compute_type="float16")
            return model, "cuda", "float16"
        except Exception as exc:  # noqa: BLE001 - the reason is reported, not swallowed
            print(json.dumps({"type": "note", "message":
                              "CUDA failed, falling back to CPU int8: " + str(exc)[:300]}),
                  flush=True)
    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    return model, "cpu", "int8"


def transcribe_one(model, audio_path, language="de", beam_size=5):
    segments, info = model.transcribe(str(audio_path), language=language,
                                      vad_filter=True, beam_size=beam_size)
    parts = []
    for seg in segments:
        text = seg.text.strip()
        if text:
            parts.append(text)
    return " ".join(parts), float(info.duration)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="large-v3-turbo")
    parser.add_argument("--language", default="de")
    parser.add_argument("--beam-size", type=int, default=5)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args()

    if sys.platform == "win32":
        add_cuda_dll_dirs()

    if args.selftest:
        try:
            model, device, compute = load_model(args.model)
            del model
            print(json.dumps({"type": "selftest", "ok": True, "model": args.model,
                              "device": device, "compute": compute}))
            return 0
        except Exception as exc:  # noqa: BLE001
            print(json.dumps({"type": "selftest", "ok": False, "model": args.model,
                              "error": str(exc)[:500]}))
            return 1

    if not args.files:
        parser.error("no files given")

    t0 = time.perf_counter()
    model, device, compute = load_model(args.model)
    load_seconds = time.perf_counter() - t0

    ok_count, fail_count = 0, 0
    for name in args.files:
        audio = Path(name)
        entry: dict[str, object] = {"type": "file", "audio": audio.name,
                                    "device": device, "compute": compute}
        try:
            t1 = time.perf_counter()
            text, audio_seconds = transcribe_one(model, audio, args.language, args.beam_size)
            seconds = time.perf_counter() - t1
            txt_path = audio.with_suffix(".txt")
            with open(txt_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text + "\n")
            st = audio.stat()
            os.utime(txt_path, (st.st_atime, st.st_mtime))
            entry.update({"txt": txt_path.name, "ok": True, "audio_seconds": round(audio_seconds, 1),
                          "seconds": round(seconds, 1),
                          "rtf": round(seconds / audio_seconds, 3) if audio_seconds else None,
                          "chars": len(text)})
            ok_count += 1
        except Exception as exc:  # noqa: BLE001
            entry.update({"ok": False, "error": str(exc)[:500]})
            fail_count += 1
        print(json.dumps(entry, ensure_ascii=False), flush=True)

    print(json.dumps({"type": "summary", "ok": ok_count, "failed": fail_count,
                      "model": args.model, "device": device, "compute": compute,
                      "model_load_seconds": round(load_seconds, 1)}, ensure_ascii=False))
    return 0 if fail_count == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
