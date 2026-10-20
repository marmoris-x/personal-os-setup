"""Groq transcription worker for Life OS.

Called by transcribe.ps1 when the engine is "groq". It preprocesses audio to 16 kHz mono
FLAC, splits files above 24 MB into 600 s chunks with a 10 s overlap, sends them to Groq's
OpenAI-compatible transcription endpoint, merges the overlapping texts and writes one .txt
next to every audio file (same base name), like transcribe_worker.py does for the local
engine.

The chunking and the overlap merge follow the Groq API Cookbook, audio chunking tutorial:
https://github.com/groq/groq-api-cookbook (tutorials/06-multimodal/audio-chunking/
audio_chunking_code.py). Only the text merge is used; the timestamp merge is not needed here.
The preprocessing command is the one from Groq's speech-to-text docs:
https://console.groq.com/docs/speech-to-text

Quota guard: the free limits are shared with OpenWhispr dictation. The worker keeps a daily
log of the audio seconds it sent and stops at --cap-seconds (default 21600 = 6 hours),
leaving 2 of the 8 free hours for dictation. It also stops a file when the audio seconds of
the last hour plus that file would exceed --hour-cap-seconds (default 7200, the free hourly
limit). One worker process handles all files of a run, so the request pacing (20 per minute)
and both caps apply across files, not once per file. Groq's rate-limit headers report
requests and tokens, not audio seconds, so the caps rest on this local log; a 429 still
falls back.

Output contract, one JSON object per line on stdout:
  {"type": "file", "audio": ..., "ok": true, "engine": "groq", "txt": ..., "audio_seconds": ...,
   "seconds_sent": ..., "chunks": n, "model": ...}
  {"type": "file", "audio": ..., "ok": false, "reason": "missing_key|daily_cap|hourly_cap|
   rate_limit|auth_error|network|api_error|preprocess_error", "error": ...}
  {"type": "summary", "engine": "groq", "ok": n, "failed": n, "seconds_sent": ...,
   "today_seconds": ..., "daily_cap_seconds": ..., "hour_cap_seconds": ...}
Exit 0 when every file succeeded, 2 when at least one file failed.

The API key is read from GROQ_API_KEY in the process environment. It is never printed.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from datetime import date, datetime
from pathlib import Path

GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
MAX_BYTES = 24 * 1024 * 1024
CHUNK_SECONDS = 600
OVERLAP_SECONDS = 10


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def find_longest_common_sequence(sequences, match_by_words=True):
    """Merge overlapping texts; copied from the Groq API Cookbook audio chunking tutorial."""
    if not sequences:
        return ""

    if match_by_words:
        sequences = [
            [word for word in re.split(r"(\s+\w+)", seq) if word]
            for seq in sequences
        ]
    else:
        sequences = [list(seq) for seq in sequences]

    left_sequence = sequences[0]
    left_length = len(left_sequence)
    total_sequence = []

    for right_sequence in sequences[1:]:
        max_matching = 0.0
        right_length = len(right_sequence)
        max_indices = (left_length, left_length, 0, 0)

        for i in range(1, left_length + right_length + 1):
            eps = float(i) / 10000.0
            left_start = max(0, left_length - i)
            left_stop = min(left_length, left_length + right_length - i)
            left = left_sequence[left_start:left_stop]
            right_start = max(0, i - left_length)
            right_stop = min(right_length, i)
            right = right_sequence[right_start:right_stop]

            if len(left) != len(right):
                raise RuntimeError("Mismatched subsequences detected during transcript merging.")

            matches = sum(a == b for a, b in zip(left, right))
            matching = matches / float(i) + eps
            if matches > 1 and matching > max_matching:
                max_matching = matching
                max_indices = (left_start, left_stop, right_start, right_stop)

        left_start, left_stop, right_start, right_stop = max_indices
        left_mid = (left_stop + left_start) // 2
        right_mid = (right_stop + right_start) // 2
        total_sequence.extend(left_sequence[:left_mid])
        left_sequence = right_sequence[right_mid:]
        left_length = len(left_sequence)

    total_sequence.extend(left_sequence)
    return "".join(total_sequence)


def merge_texts(texts):
    cleaned = [t.strip() for t in texts if t and t.strip()]
    if not cleaned:
        return ""
    if len(cleaned) == 1:
        return cleaned[0]
    return find_longest_common_sequence(cleaned, match_by_words=True).strip()


def probe_duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    return float(out)


def preprocess_audio(input_path, workdir):
    output = workdir / "preprocessed.flac"
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(input_path),
         "-ar", "16000", "-ac", "1", "-map", "0:a", "-c:a", "flac", "-y", str(output)],
        check=True, capture_output=True,
    )
    return output


def plan_chunks(flac_path, duration, workdir, max_bytes, chunk_seconds, overlap_seconds):
    if flac_path.stat().st_size <= max_bytes:
        return [(flac_path, 0.0, duration)]
    if chunk_seconds <= overlap_seconds:
        raise ValueError("chunk seconds must be greater than overlap seconds")
    chunks = []
    step = chunk_seconds - overlap_seconds
    total_chunks = int(duration // step) + 1
    for i in range(total_chunks):
        start = i * step
        if start >= duration:
            break
        end = min(start + chunk_seconds, duration)
        out = workdir / ("chunk-%03d.flac" % i)
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(start),
             "-t", str(end - start), "-i", str(flac_path), "-ar", "16000", "-ac", "1",
             "-c:a", "flac", "-y", str(out)],
            check=True, capture_output=True,
        )
        chunks.append((out, start, end - start))
    return chunks


def read_daily_seconds(log_path, today):
    total = 0.0
    if not log_path.exists():
        return total
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            entry = json.loads(line)
            if entry.get("date") == today:
                total += float(entry.get("seconds", 0))
        except Exception:
            continue
    return total


def read_hourly_seconds(log_path, now=None):
    """Audio seconds sent in the last 60 minutes, from the same daily log."""
    total = 0.0
    if not log_path.exists():
        return total
    now = now or datetime.now().astimezone()
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            entry = json.loads(line)
            stamp = entry.get("ts")
            if not stamp:
                continue
            sent_at = datetime.fromisoformat(str(stamp))
            if sent_at.tzinfo is None:
                sent_at = sent_at.astimezone()
            age = (now - sent_at).total_seconds()
            if 0 <= age < 3600:
                total += float(entry.get("seconds", 0))
        except Exception:
            continue
    return total


def append_daily(log_path, today, audio_name, chunk_index, seconds, model):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "date": today,
        "file": audio_name,
        "chunk": chunk_index,
        "seconds": round(seconds, 1),
        "model": model,
    }
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def post_audio(url, api_key, file_path, model, language, timeout=300):
    boundary = "----LifeOsGroq" + uuid.uuid4().hex
    fields = {
        "model": model,
        "language": language,
        "response_format": "json",
        "temperature": "0",
    }
    parts = []
    for name, value in fields.items():
        parts.append((
            "--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
            % (boundary, name, value)
        ).encode("utf-8"))
    parts.append((
        "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
        "Content-Type: audio/flac\r\n\r\n" % (boundary, file_path.name)
    ).encode("utf-8"))
    parts.append(file_path.read_bytes())
    parts.append(("\r\n--%s--\r\n" % boundary).encode("utf-8"))
    body = b"".join(parts)
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "multipart/form-data; boundary=" + boundary,
            "Accept": "application/json",
            # Cloudflare in front of api.groq.com refuses the default Python-urllib signature
            # with "Error 1010: Access denied" (measured 2026-10-20), so send a normal one.
            "User-Agent": "LifeOS-Groq-Worker/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read().decode("utf-8", "replace")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        # Unreachable host, refused connection, timeout: the caller falls back to local.
        return None, {}, str(exc)


def rate_wait(request_times, max_per_minute):
    now = time.time()
    request_times[:] = [t for t in request_times if now - t < 60]
    if len(request_times) >= max_per_minute:
        wait = 60.0 - (now - request_times[0]) + 0.5
        if wait > 0:
            time.sleep(wait)
        now = time.time()
        request_times[:] = [t for t in request_times if now - t < 60]


def error_reason(status, headers, body):
    if status == 429:
        return "rate_limit"
    if status == 401:
        return "auth_error"
    if status is None:
        return "network"
    # 403 is not necessarily a bad key: Cloudflare in front of api.groq.com answers 403 with
    # "Error 1010" when it dislikes the client signature. The body is logged with the reason.
    return "api_error"


def transcribe_one(audio_path, args, today, request_times):
    audio_path = Path(audio_path)
    result: dict[str, object] = {"type": "file", "audio": audio_path.name}
    if not audio_path.exists():
        result.update({"ok": False, "reason": "preprocess_error", "error": "file not found"})
        return result, 0.0
    api_key = os.environ.get("GROQ_API_KEY", "").strip()
    if not api_key:
        result.update({"ok": False, "reason": "missing_key",
                       "error": "GROQ_API_KEY is not set in the process environment"})
        return result, 0.0

    daily_log = Path(args.daily_log)
    today_seconds = read_daily_seconds(daily_log, today)

    with tempfile.TemporaryDirectory(prefix="life-os-groq-") as tmp:
        workdir = Path(tmp)
        try:
            flac = preprocess_audio(audio_path, workdir)
            duration = probe_duration(flac)
        except Exception as exc:
            result.update({"ok": False, "reason": "preprocess_error", "error": str(exc)[:500]})
            return result, 0.0

        try:
            chunks = plan_chunks(flac, duration, workdir, args.max_bytes,
                                 args.chunk_seconds, args.overlap_seconds)
        except Exception as exc:
            result.update({"ok": False, "reason": "preprocess_error", "error": str(exc)[:500]})
            return result, 0.0

        planned = sum(c[2] for c in chunks)
        if today_seconds + planned > args.cap_seconds:
            result.update({
                "ok": False, "reason": "daily_cap",
                "error": ("today %0.0f s + this file %0.0f s exceeds the cap of %d s"
                          % (today_seconds, planned, args.cap_seconds)),
                "today_seconds": round(today_seconds, 1),
                "planned_seconds": round(planned, 1),
            })
            return result, 0.0
        hour_seconds = read_hourly_seconds(daily_log)
        if hour_seconds + planned > args.hour_cap_seconds:
            result.update({
                "ok": False, "reason": "hourly_cap",
                "error": ("last hour %0.0f s + this file %0.0f s exceeds the hourly cap of %d s"
                          % (hour_seconds, planned, args.hour_cap_seconds)),
                "hour_seconds": round(hour_seconds, 1),
                "planned_seconds": round(planned, 1),
            })
            return result, 0.0

        texts = []
        sent = 0.0
        for index, (chunk_path, _start, chunk_seconds) in enumerate(chunks):
            rate_wait(request_times, args.requests_per_minute)
            status, headers, body = post_audio(
                args.base_url, api_key, chunk_path, args.model, args.language)
            request_times.append(time.time())
            if status != 200:
                reason = error_reason(status, headers, body)
                detail = {"status": status, "body": body[:300]}
                if status == 429 and "retry-after" in {k.lower() for k in headers}:
                    detail["retry_after"] = headers.get("retry-after") or headers.get("Retry-After")
                result.update({"ok": False, "reason": reason, "error": json.dumps(detail)})
                return result, sent
            try:
                payload = json.loads(body)
                text = payload.get("text", "") if isinstance(payload, dict) else str(payload)
            except Exception:
                text = body.strip()
            texts.append(text)
            sent += chunk_seconds
            append_daily(daily_log, today, audio_path.name, index, chunk_seconds, args.model)

        merged = merge_texts(texts)
        txt_path = audio_path.with_suffix(".txt")
        with open(txt_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(merged + "\n")
        stat = audio_path.stat()
        os.utime(txt_path, (stat.st_atime, stat.st_mtime))
        result.update({
            "ok": True, "engine": "groq", "txt": txt_path.name,
            "audio_seconds": round(duration, 1), "seconds_sent": round(sent, 1),
            "chunks": len(chunks), "model": args.model,
        })
        return result, sent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--model", default="whisper-large-v3-turbo")
    parser.add_argument("--language", default="de")
    parser.add_argument("--base-url", default=GROQ_URL)
    parser.add_argument("--daily-log", default=os.path.join(
        os.environ.get("LOCALAPPDATA", str(Path.home())), "life-os", "groq-audio.jsonl"))
    parser.add_argument("--cap-seconds", type=int, default=21600)
    parser.add_argument("--hour-cap-seconds", type=int, default=7200)
    parser.add_argument("--requests-per-minute", type=int, default=20)
    parser.add_argument("--max-bytes", type=int, default=MAX_BYTES)
    parser.add_argument("--chunk-seconds", type=int, default=CHUNK_SECONDS)
    parser.add_argument("--overlap-seconds", type=int, default=OVERLAP_SECONDS)
    args = parser.parse_args()

    today = date.today().isoformat()
    ok_count = 0
    fail_count = 0
    total_sent = 0.0
    # One list for the whole run: the 20-requests-per-minute limit is per account, not per file.
    request_times = []
    for name in args.files:
        result, sent = transcribe_one(name, args, today, request_times)
        total_sent += sent
        if result.get("ok"):
            ok_count += 1
        else:
            fail_count += 1
        emit(result)

    today_total = read_daily_seconds(Path(args.daily_log), today)
    emit({
        "type": "summary", "engine": "groq", "ok": ok_count, "failed": fail_count,
        "seconds_sent": round(total_sent, 1), "today_seconds": round(today_total, 1),
        "daily_cap_seconds": args.cap_seconds, "hour_cap_seconds": args.hour_cap_seconds,
        "model": args.model,
    })
    return 0 if fail_count == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
