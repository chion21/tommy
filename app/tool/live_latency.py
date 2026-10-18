"""Measures how fast Gemini Live answers (the same way the app talks to it).

Makes two spoken Bangla test sentences with Gemini TTS, streams them like a microphone (real time), and times:
connect+setup, end of speech → first sound back, → function call, → turn complete.
Needs GEMINI_API_KEY. Results are printed as GitHub annotations.  Run by .github/workflows/latency.yml
"""
import asyncio
import base64
import json
import os
import sys
import time
import urllib.request

import numpy as np
import websockets

KEY = os.environ.get("GEMINI_API_KEY", "")
API = "https://generativelanguage.googleapis.com/v1beta"
SENTENCES = ["হেই টমি, তুমি কেমন আছো?", "হেই টমি, একটা রোমান্টিক গান চালাও।"]
TOOLS = [{"functionDeclarations": [{
    "name": "play_youtube", "description": "Play a song/video on YouTube directly.",
    "parameters": {"type": "OBJECT", "properties": {"query": {"type": "STRING"}}, "required": ["query"]}}]}]
SYSTEM = ("You are Tommy (টমি), a sweet Bangla voice assistant. Reply in short natural spoken Bangla, 1 sentence. "
          "Only respond when called by name. For music call play_youtube right away.")


def note(msg: str) -> None:
    print(f"::notice::{msg}", flush=True)


def get(path: str):
    req = urllib.request.Request(f"{API}/{path}", headers={"x-goog-api-key": KEY})
    return json.loads(urllib.request.urlopen(req, timeout=60).read())


def post(path: str, body: dict):
    req = urllib.request.Request(f"{API}/{path}", data=json.dumps(body).encode(),
                                 headers={"x-goog-api-key": KEY, "Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=120).read())


def tts(text: str, model: str) -> np.ndarray:
    data = post(f"models/{model}:generateContent", {
        "contents": [{"parts": [{"text": text}]}],
        "generationConfig": {"responseModalities": ["AUDIO"],
                             "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": "Puck"}}}}})
    b64 = data["candidates"][0]["content"]["parts"][0]["inlineData"]["data"]
    pcm24 = np.frombuffer(base64.b64decode(b64), dtype="<i2").astype(np.float32)
    n16 = int(len(pcm24) * 16000 / 24000)
    pcm16 = np.interp(np.linspace(0, len(pcm24) - 1, n16), np.arange(len(pcm24)), pcm24)
    return pcm16.astype("<i2")


async def run(model: str, version: str, proactive: bool, speech: list[np.ndarray]) -> None:
    url = (f"wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.{version}"
           f".GenerativeService.BidiGenerateContent?key={KEY}")
    setup = {"model": f"models/{model}",
             "generationConfig": {"responseModalities": ["AUDIO"],
                                  "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": "Aoede"}}}},
             "systemInstruction": {"parts": [{"text": SYSTEM}]},
             "tools": TOOLS,
             "inputAudioTranscription": {}, "outputAudioTranscription": {},
             "realtimeInputConfig": {"automaticActivityDetection": {
                 "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH", "endOfSpeechSensitivity": "END_SENSITIVITY_HIGH",
                 "prefixPaddingMs": 120, "silenceDurationMs": 450}}}
    if proactive:
        setup["proactivity"] = {"proactiveAudio": True}
    label = f"{model} {version}{' proactive' if proactive else ''}"
    t0 = time.time()
    try:
        ws = await websockets.connect(url, max_size=None, open_timeout=15)
        await ws.send(json.dumps({"setup": setup}))
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), 15))
            if "setupComplete" in m:
                break
    except Exception as e:  # noqa: BLE001
        note(f"{label}: could not connect — {str(e)[:200]}")
        return
    note(f"{label}: connect+setup {time.time() - t0:.2f}s")

    for i, pcm in enumerate(speech):
        chunk = 640  # 40 ms
        start = time.time()
        for k in range(0, len(pcm), chunk):
            await ws.send(json.dumps({"realtimeInput": {"audio": {
                "data": base64.b64encode(pcm[k:k + chunk].tobytes()).decode(), "mimeType": "audio/pcm;rate=16000"}}}))
            await asyncio.sleep(max(0, start + (k + chunk) / 16000 - time.time()))
        speech_end = time.time()
        silence = np.zeros(640, dtype="<i2")

        async def feed_silence():
            for _ in range(30):  # 1.2 s like the app, then "mic paused"
                await ws.send(json.dumps({"realtimeInput": {"audio": {
                    "data": base64.b64encode(silence.tobytes()).decode(), "mimeType": "audio/pcm;rate=16000"}}}))
                await asyncio.sleep(0.04)
            await ws.send(json.dumps({"realtimeInput": {"audioStreamEnd": True}}))

        feeder = asyncio.create_task(feed_silence())
        first_audio = tool = done = None
        heard, said = "", ""
        try:
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), 25))
                now = time.time() - speech_end
                sc = m.get("serverContent") or {}
                heard += (sc.get("inputTranscription") or {}).get("text", "")
                said += (sc.get("outputTranscription") or {}).get("text", "")
                parts = ((sc.get("modelTurn") or {}).get("parts")) or []
                if first_audio is None and any(p.get("inlineData") for p in parts):
                    first_audio = now
                if "toolCall" in m:
                    tool = tool or now
                    calls = m["toolCall"].get("functionCalls", [])
                    await ws.send(json.dumps({"toolResponse": {"functionResponses": [
                        {"id": c.get("id"), "name": c.get("name"), "response": {"ok": True, "playing": "song"}} for c in calls]}}))
                if sc.get("turnComplete"):
                    done = now
                    if first_audio is not None or tool is None:
                        break
        except asyncio.TimeoutError:
            pass
        await feeder
        fa = "none" if first_audio is None else f"{first_audio:.2f}s"
        tc = "-" if tool is None else f"{tool:.2f}s"
        dn = "-" if done is None else f"{done:.2f}s"
        note(f"{label} | test {i + 1}: first sound {fa}, function {tc}, done {dn} | heard: {heard.strip()[:60]} | said: {said.strip()[:60]}")
        await asyncio.sleep(1.5)
    await ws.close()


def main() -> None:
    if not KEY:
        note("GEMINI_API_KEY secret is not set — latency test skipped")
        return
    models = get("models?pageSize=1000").get("models", [])
    live = [m["name"].split("/", 1)[1] for m in models if "bidiGenerateContent" in m.get("supportedGenerationMethods", [])]
    tts_models = [m["name"].split("/", 1)[1] for m in models if "tts" in m["name"]]
    note(f"Live models for this key: {', '.join(live) or 'NONE'}")
    if not live or not tts_models:
        return
    speech = [tts(s, sorted(tts_models, key=lambda n: "flash" not in n)[0]) for s in SENTENCES]
    for model in live[:4]:
        for version, proactive in (("v1alpha", True), ("v1beta", False)):
            asyncio.run(run(model, version, proactive, speech))


if __name__ == "__main__":
    sys.exit(main())
