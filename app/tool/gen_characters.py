"""Make the character pictures: for every character one PHONE picture (portrait 1080x1920) and one
PC picture (landscape 1920x1080). Saved as app/assets/characters/<id>_phone.webp and <id>_pc.webp.

Free by default: uses Pollinations (FLUX model, no account or key). If that fails and GEMINI_API_KEY
is set, falls back to Gemini image generation.
Run by .github/workflows/characters.yml, or locally:  python tool/gen_characters.py [--force] [f1 m2 ...]"""
import base64
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from PIL import Image, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "characters")
GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")

STYLE = ("masterpiece, best quality, highly detailed modern anime illustration, sharp clean line art, "
         "beautiful detailed eyes, cinematic lighting, glowing neon rim light, dark moody background with soft bokeh, "
         "the character is clearly an adult in their mid-20s, tasteful, fully clothed, original character, "
         "no text, no logo, no watermark, no signature")
PHONE = ("vertical phone wallpaper, upper-body portrait centred, looking at the viewer, "
         "dark empty space at the top and bottom of the image")
PC = ("wide cinematic desktop wallpaper, the character placed on the right third of the frame, upper body, "
      "large dark empty area with subtle glow on the left side")

CHARACTERS = {
    "f1": "Rin, elegant woman with long straight black hair and gentle red eyes, black high-collar outfit with red accents, red neon light",
    "f2": "Luna, calm woman with silver-lavender wavy hair, futuristic purple jacket, holding a softly glowing violet rose, purple city bokeh",
    "f3": "Mira, friendly woman with a short teal bob, white tech jacket, cyan holographic interface glowing around her, deep blue background",
    "f4": "Sakura, warm woman with long soft pink hair and a hair clip, cream cardigan, falling cherry blossom petals, warm pink light",
    "f5": "Aria, confident woman with a golden-blonde ponytail, black and gold outfit, warm golden rim light, dark luxurious background",
    "m1": "Kai, calm man with short dark-blue hair, black techwear jacket, electric blue neon light, rainy night city bokeh",
    "m2": "Ren, cool man with messy black hair and red eyes, dark long coat with red details, red neon glow",
    "m3": "Haru, kind man with brown wavy hair, green hoodie, green neon glow, cozy futuristic room",
    "m4": "Sora, cheerful man with light silver hair, white and sky-blue jacket, soft cyan glow, starry night sky",
    "m5": "Leo, confident man with warm brown hair, orange and black bomber jacket, sunset orange neon glow",
}
SEEDS = {cid: 1000 + i * 37 for i, cid in enumerate(CHARACTERS)}  # same seed for both shapes → similar look

SHAPES = {"phone": (1080, 1920, PHONE, "9:16"), "pc": (1920, 1080, PC, "16:9")}


def http_get(url: str, timeout: int = 240) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "tommy-character-generator/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def pollinations(prompt: str, w: int, h: int, seed: int) -> bytes:
    q = urllib.parse.urlencode({"width": w, "height": h, "seed": seed, "model": "flux",
                                "nologo": "true", "safe": "true", "enhance": "false"})
    return http_get(f"https://image.pollinations.ai/prompt/{urllib.parse.quote(prompt)}?{q}")


def gemini(prompt: str, aspect: str) -> bytes:
    api = "https://generativelanguage.googleapis.com/v1beta"
    hdr = {"Content-Type": "application/json", "x-goog-api-key": GEMINI_KEY}
    models = json.loads(urllib.request.urlopen(urllib.request.Request(f"{api}/models?pageSize=1000", headers=hdr),
                                               timeout=60).read())
    names = [m["name"].split("/", 1)[1] for m in models.get("models", [])
             if "image" in m["name"] and "generateContent" in m.get("supportedGenerationMethods", [])]
    if not names:
        raise RuntimeError("no Gemini image model for this key")
    model = sorted(names, key=lambda n: ("pro" not in n, n))[0]
    body = {"contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"responseModalities": ["IMAGE"], "imageConfig": {"aspectRatio": aspect}}}
    req = urllib.request.Request(f"{api}/models/{model}:generateContent", data=json.dumps(body).encode(), headers=hdr)
    data = json.loads(urllib.request.urlopen(req, timeout=240).read())
    for cand in data.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            inline = part.get("inlineData") or part.get("inline_data")
            if inline and inline.get("data"):
                return base64.b64decode(inline["data"])
    raise RuntimeError("Gemini returned no image")


def finish(raw: bytes, w: int, h: int, path: str) -> None:
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    if img.width < 400 or img.height < 400:
        raise RuntimeError(f"image too small {img.size}")
    # cover-crop to the exact shape, then scale to the target size
    target = w / h
    if img.width / img.height > target:
        nw = int(img.height * target)
        img = img.crop(((img.width - nw) // 2, 0, (img.width - nw) // 2 + nw, img.height))
    else:
        nh = int(img.width / target)
        img = img.crop((0, (img.height - nh) // 2, img.width, (img.height - nh) // 2 + nh))
    if img.size != (w, h):
        img = img.resize((w, h), Image.LANCZOS)
        img = img.filter(ImageFilter.UnsharpMask(radius=1.2, percent=60, threshold=2))
    img.save(path, "WEBP", quality=88, method=6)


def make(cid: str, shape: str) -> str:
    w, h, framing, aspect = SHAPES[shape]
    prompt = f"{CHARACTERS[cid]}. {framing}. {STYLE}"
    errors = []
    for attempt in range(4):
        try:
            return _save(pollinations(prompt, w, h, SEEDS[cid]), w, h, cid, shape, "pollinations")
        except Exception as e:  # noqa: BLE001
            errors.append(f"pollinations#{attempt + 1}: {e}")
            time.sleep(20 * (attempt + 1))
    if GEMINI_KEY:
        try:
            return _save(gemini(prompt, aspect), w, h, cid, shape, "gemini")
        except Exception as e:  # noqa: BLE001
            errors.append(f"gemini: {e}")
    raise RuntimeError("; ".join(errors))


def _save(raw: bytes, w: int, h: int, cid: str, shape: str, src: str) -> str:
    path = os.path.join(OUT, f"{cid}_{shape}.webp")
    finish(raw, w, h, path)
    return f"{src}, {os.path.getsize(path) // 1024} KB"


def main() -> None:
    force = "--force" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    os.makedirs(OUT, exist_ok=True)
    failed = []
    for cid in CHARACTERS:
        if only and cid not in only:
            continue
        for shape in SHAPES:
            path = os.path.join(OUT, f"{cid}_{shape}.webp")
            if os.path.exists(path) and not force:
                print(f"skip {cid}_{shape} (exists)")
                continue
            try:
                print(f"ok   {cid}_{shape}: {make(cid, shape)}", flush=True)
            except Exception as e:  # noqa: BLE001
                print(f"FAIL {cid}_{shape}: {e}", flush=True)
                failed.append(f"{cid}_{shape}")
            time.sleep(8)  # be gentle with the free service
    print("failed:", failed or "none")
    sys.exit(1 if failed and len(failed) == len(only or CHARACTERS) * len(SHAPES) else 0)


if __name__ == "__main__":
    main()
