#!/usr/bin/env python3
"""Persistent Kokoro-82M synthesis daemon for SpeakIt.

Why a daemon and not a CLI
--------------------------
`EdgeTTSProvider` spawns one `edge-tts` process per sentence, which is fine
because that process just makes an HTTP request. Kokoro is local: starting a
process means importing onnxruntime and loading a 325 MB model, which costs a
few seconds. Paying that per sentence would make the first word arrive later
than the network engine it is meant to replace.

So the model is loaded once and the process stays alive for the life of the
app. Requests arrive as JSON lines on stdin, replies leave as JSON lines on
stdout. Anything the libraries print goes to stderr, because a stray print on
stdout would corrupt the protocol.

Protocol
--------
Startup, once the model is resident:

    {"event": "ready", "sample_rate": 24000, "voices": [...]}

Request:

    {"id": 7, "text": "Hello.", "voice": "af_heart", "speed": 1.0,
     "out": "/tmp/speakit-kokoro-7.wav"}

Reply, one per request, always carrying the same id:

    {"id": 7, "ok": true,  "out": "...", "seconds": 1.31, "synth_ms": 402}
    {"id": 7, "ok": false, "error": "..."}

Control:

    {"cancel_before": 12}   drop queued work with id < 12 (a seek happened)
    {"shutdown": true}

A cancelled request still gets a reply, with `"cancelled": true`, so the
caller never waits forever on an id it sent.
"""

from __future__ import annotations

import json
import os
import queue
import sys
import threading
import time
import wave

# onnxruntime and phonemizer both write to stdout on import. That would land in
# the middle of the JSON protocol, so stdout is redirected to stderr for the
# duration of the import and restored afterwards.
_real_stdout = sys.stdout
sys.stdout = sys.stderr

try:
    import numpy as np
    from kokoro_onnx import Kokoro
except Exception as exc:  # noqa: BLE001 - reported to the client, not raised
    sys.stdout = _real_stdout
    print(json.dumps({"event": "error", "error": f"import failed: {exc}"}), flush=True)
    sys.exit(1)

sys.stdout = _real_stdout


# Kokoro voice ids encode language in the first letter and gender in the
# second: "af_heart" is American English, female. The synthesis call needs the
# espeak language code, which is not derivable from the id without this table.
LANG_BY_PREFIX = {
    "a": "en-us",
    "b": "en-gb",
    "e": "es",
    "f": "fr-fr",
    "h": "hi",
    "i": "it",
    "j": "ja",
    "p": "pt-br",
    "z": "cmn",
}


def lang_for_voice(voice: str) -> str:
    return LANG_BY_PREFIX.get(voice[:1], "en-us")


def write_wav(path: str, samples, sample_rate: int) -> float:
    """Write float samples as 16-bit PCM. Returns duration in seconds.

    Written with the `wave` module rather than soundfile so the virtualenv does
    not need libsndfile, which is a system library and one more thing to fail
    on a user's machine.
    """
    audio = np.asarray(samples, dtype=np.float32)
    # Clip before scaling: Kokoro occasionally returns values just past 1.0 and
    # letting those wrap round in int16 produces a loud click.
    audio = np.clip(audio, -1.0, 1.0)
    pcm = (audio * 32767.0).astype("<i2")

    tmp = f"{path}.part"
    with wave.open(tmp, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(sample_rate)
        f.writeframes(pcm.tobytes())
    # Rename into place so a reader can never observe a partial file.
    os.replace(tmp, path)
    return len(pcm) / float(sample_rate)


class Daemon:
    def __init__(self, model_path: str, voices_path: str) -> None:
        self.kokoro = Kokoro(model_path, voices_path)
        self.jobs: queue.Queue = queue.Queue()
        # Requests with an id below this were superseded by a seek.
        self.cancel_floor = 0
        self.lock = threading.Lock()
        self.sample_rate = 24000

    def reply(self, payload: dict) -> None:
        _real_stdout.write(json.dumps(payload) + "\n")
        _real_stdout.flush()

    def voices(self) -> list:
        try:
            return sorted(self.kokoro.get_voices())
        except Exception:  # noqa: BLE001
            return []

    # -- worker ----------------------------------------------------------

    def work(self) -> None:
        while True:
            job = self.jobs.get()
            if job is None:
                self.jobs.task_done()
                return

            job_id = job.get("id", 0)
            with self.lock:
                floor = self.cancel_floor
            if job_id < floor:
                # Superseded before we got to it. Reply anyway so the caller's
                # bookkeeping for this id is closed out.
                self.reply({"id": job_id, "ok": False, "cancelled": True})
                self.jobs.task_done()
                continue

            try:
                started = time.monotonic()
                voice = job.get("voice") or "af_heart"
                samples, sample_rate = self.kokoro.create(
                    job["text"],
                    voice=voice,
                    speed=float(job.get("speed", 1.0)),
                    lang=job.get("lang") or lang_for_voice(voice),
                )
                seconds = write_wav(job["out"], samples, sample_rate)
                self.reply(
                    {
                        "id": job_id,
                        "ok": True,
                        "out": job["out"],
                        "seconds": round(seconds, 3),
                        "synth_ms": int((time.monotonic() - started) * 1000),
                    }
                )
            except Exception as exc:  # noqa: BLE001 - one bad sentence must not kill the daemon
                self.reply({"id": job_id, "ok": False, "error": str(exc)})
            finally:
                self.jobs.task_done()

    # -- reader ----------------------------------------------------------

    def run(self) -> None:
        threading.Thread(target=self.work, daemon=True).start()
        self.reply(
            {"event": "ready", "sample_rate": self.sample_rate, "voices": self.voices()}
        )

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue

            if msg.get("shutdown"):
                break

            if "cancel_before" in msg:
                floor = int(msg["cancel_before"])
                with self.lock:
                    self.cancel_floor = max(self.cancel_floor, floor)
                # Drain what is already queued. The job in flight is left to
                # finish: interrupting an onnxruntime call is not possible, and
                # its reply will be ignored by the client anyway.
                drained = []
                try:
                    while True:
                        drained.append(self.jobs.get_nowait())
                        # Balance the get so `jobs.join()` on shutdown still
                        # reaches zero; kept jobs are re-counted by the put below.
                        self.jobs.task_done()
                except queue.Empty:
                    pass
                for job in drained:
                    if job.get("id", 0) >= floor:
                        self.jobs.put(job)
                    else:
                        self.reply(
                            {"id": job.get("id", 0), "ok": False, "cancelled": True}
                        )
                continue

            if "text" in msg and "out" in msg:
                self.jobs.put(msg)

        # Both exits land here: an explicit shutdown, and stdin reaching EOF
        # because the app quit. Wait for accepted work to finish and be
        # acknowledged. Returning straight away would kill the worker thread
        # mid-synthesis and drop replies the client is still waiting on.
        self.jobs.join()


def main() -> int:
    model = os.environ.get("SPEAKIT_KOKORO_MODEL")
    voices = os.environ.get("SPEAKIT_KOKORO_VOICES")
    if not model or not voices:
        print(
            json.dumps(
                {
                    "event": "error",
                    "error": "SPEAKIT_KOKORO_MODEL and SPEAKIT_KOKORO_VOICES must be set",
                }
            ),
            flush=True,
        )
        return 2
    if not os.path.exists(model) or not os.path.exists(voices):
        print(
            json.dumps({"event": "error", "error": "model or voices file missing"}),
            flush=True,
        )
        return 2

    Daemon(model, voices).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
