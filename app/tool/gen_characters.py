"""Generate the 10 character portraits with Gemini (needs GEMINI_API_KEY).
Run by .github/workflows/characters.yml, or locally:  python tool/gen_characters.py [--force] [f1 m2 ...]
Saves app/assets/characters/<id>.jpg (portrait 9:16, ~1080 px wide)."""
import base64
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request

from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "characters")
API = "https://generativelanguage.googleapis.com/v1beta"
KEY = os.environ.get("GEMINI_API_KEY", "")

STYLE = ("high-quality modern anime illustration, clearly an adult (mid-20s), tasteful and fully clothed, "
         "upper-body portrait facing the viewer, soft cinematic lighting, dark background with neon glow, "
         "plenty of empty dark space at the top and bottom for app text, vertical 9:16 phone wallpaper, "
         "no text, no logo, no watermark, original character design")

CHARACTERS = {
    "f1": "Rin — elegant adult woman, long straight black hair, gentle red eyes, black high-collar outfit with red accents, red neon light",
    "f2": "Luna — calm adult woman, silver-lavender wavy hair, futuristic purple jacket, holding a softly glowing violet rose, purple city bokeh",
    "f3": "Mira — friendly adult woman, short teal bob hair, white tech jacket, cyan holographic interface glowing around her, deep blue background",
    "f4": "Sakura — warm adult woman, soft pink long hair with a hair clip, modern cream cardigan, falling cherry blossom petals, warm pink light",
    "f5": "Aria — confident adult woman, golden-blonde ponytail, black and gold outfit, warm golden rim light, dark luxurious background",
    "m1": "Kai — calm adult man, short dark-blue hair, black techwear jacket, electric blue neon light, rainy night city bokeh",
    "m2": "Ren — cool adult man, messy black hair, red eyes, dark long coat with red details, red neon glow",
    "m3": "Haru — kind adult man, brown wavy hair, green hoodie, green neon glow, cozy futuristic room",
    "m4": "Sora — cheerful adult man, light silver hair, white and sky-blue jacket, soft cyan glow, starry night sky",
    "m5": "Leo — confident adult man, warm brown hair, orange and black bomber jacket, sunset orange neon glow",
}

PREFERRED = ["gemini-3-pro-image", "gemini-3-flash-image", "gemini-2.5-flash-image"]


def call(url: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body else None,
                                 headers={"Content-Type": "application/json", "x-goog-api-key": KEY})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())


def pick_model() -> str:
    if os.environ.get("IMAGE_MODEL"):
        return os.environ["IMAGE_MODEL"]
    names = []
    url = f"{API}/models?pageSize=1000"
    data = call(url)
    for m in data.get("models", []):
        if "generateContent" in m.get("supportedGenerationMethods", []) and "image" in m["name"]:
            names.append(m["name"].split("/", 1)[1])
    print("Image-capable models:", names)
    for pref in PREFERRED:
        for n in names:
            if n.startswith(pref):
                return n
    if names:
        return names[0]
    raise SystemExit("No image model available for this key.")


def generate(model: str, prompt: str) -> bytes:
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseModalities": ["IMAGE"], "imageConfig": {"aspectRatio": "9:16"}},
    }
    data = call(f"{API}/models/{model}:generateContent", body)
    for cand in data.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            inline = part.get("inlineData") or part.get("inline_data")
            if inline and inline.get("data"):
                return base64.b64decode(inline["data"])
    raise RuntimeError(f"no image in response: {json.dumps(data)[:400]}")


def save(raw: bytes, path: str) -> None:
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    w, h = img.size
    target = 9 / 16
    if abs(w / h - target) > 0.02:  # centre-crop to 9:16 if the model returned another shape
        if w / h > target:
            nw = int(h * target)
            img = img.crop(((w - nw) // 2, 0, (w - nw) // 2 + nw, h))
        else:
            nh = int(w / target)
            img = img.crop((0, (h - nh) // 2, w, (h - nh) // 2 + nh))
    if img.width > 1080:
        img = img.resize((1080, int(1080 / target)), Image.LANCZOS)
    img.save(path, "JPEG", quality=86, optimize=True, progressive=True)


def main() -> None:
    if not KEY:
        raise SystemExit("GEMINI_API_KEY is not set (add it as a GitHub secret).")
    force = "--force" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    os.makedirs(OUT, exist_ok=True)
    model = pick_model()
    print("Using model:", model)
    failed = []
    for cid, desc in CHARACTERS.items():
        if only and cid not in only:
            continue
        path = os.path.join(OUT, f"{cid}.jpg")
        if os.path.exists(path) and not force:
            print(f"skip {cid} (exists)")
            continue
        for attempt in range(3):
            try:
                save(generate(model, f"{desc}. {STYLE}"), path)
                print(f"ok   {cid} -> {os.path.getsize(path)//1024} KB")
                break
            except urllib.error.HTTPError as e:
                msg = e.read().decode()[:300]
                print(f"try {attempt+1} {cid}: HTTP {e.code} {msg}")
                if e.code in (400, 403):
                    break
                time.sleep(15 * (attempt + 1))
            except Exception as e:  # noqa: BLE001
                print(f"try {attempt+1} {cid}: {e}")
                time.sleep(10)
        else:
            failed.append(cid)
        if not os.path.exists(path):
            failed.append(cid)
    if failed:
        print("FAILED:", sorted(set(failed)))
        sys.exit(1 if len(set(failed)) == len(only or CHARACTERS) else 0)


if __name__ == "__main__":
    main()
