"""Make the character pictures: for every character one PHONE picture (portrait 1080x1920) and one
PC picture (landscape 1920x1080). Saved as app/assets/characters/<id>_phone.webp and <id>_pc.webp.
The PC picture is built from the phone picture (same face): character on the right, blurred glow on the left.

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

from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "characters")
GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")

STYLE = ("2D anime key visual, cel shading, crisp clean line art, vibrant colours, highly detailed, "
         "beautiful detailed eyes, cinematic lighting, glowing neon rim light, dark moody background with soft bokeh, "
         "grown-up adult with a mature face, tasteful, fully clothed, original character, "
         "no text, no logo, no watermark, no signature")
PHONE = ("vertical phone wallpaper, upper-body portrait centred, looking at the viewer, "
         "head in the upper third, dark empty space at the top and bottom of the image")
PC = ("wide cinematic desktop wallpaper, the character placed on the right third of the frame, upper body, "
      "large dark empty area with subtle glow on the left side")

CHARACTERS = {
    "f1": "elegant adult woman with long straight black hair and gentle red eyes, black high-collar outfit with red accents, red neon light",
    "f2": "graceful adult woman with silver-lavender wavy hair, futuristic purple jacket, holding a softly glowing violet rose, purple city bokeh",
    "f3": "confident adult woman with a sleek teal bob, white tech jacket, cyan holographic interface glowing around her, deep blue background",
    "f4": "gentle adult woman with long soft pink hair and a hair clip, cream cardigan, falling cherry blossom petals, warm pink light",
    "f5": "confident adult woman with a golden-blonde ponytail, black and gold outfit, warm golden rim light, dark luxurious background",
    "m1": "calm adult man with a strong jawline with short dark-blue hair, black techwear jacket, electric blue neon light, rainy night city bokeh",
    "m2": "cool adult man with a sharp jawline with messy black hair and red eyes, dark long coat with red details, red neon glow",
    "m3": "kind handsome adult man with short brown hair and masculine features, broad shoulders, green hoodie, green neon glow, cozy futuristic room",
    "m4": "cheerful adult man with masculine features with light silver hair, white and sky-blue jacket, soft cyan glow, starry night sky",
    "m5": "confident adult man with a strong jawline with warm brown hair, orange and black bomber jacket, sunset orange neon glow",
}
SEEDS = {cid: 2024 + i * 53 for i, cid in enumerate(CHARACTERS)}

WATERMARK_CROP = 0.07  # the free service stamps a small logo bottom-right; we cut that strip off
LOG = []


def http_get(url: str, timeout: int = 150) -> bytes:
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


def finish(raw: bytes, w: int, h: int, path: str, crop_bottom: float = 0.0) -> Image.Image:
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    LOG.append(f"{os.path.basename(path)} original {img.size}")
    if img.width < 400 or img.height < 400:
        raise RuntimeError(f"image too small {img.size}")
    if crop_bottom:
        img = img.crop((0, 0, img.width, int(img.height * (1 - crop_bottom))))
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
    img.save(path, "WEBP", quality=90, method=6)
    return img


def make_pc(phone: Image.Image, path: str) -> None:
    """1920x1080 from the phone portrait: dark backdrop with a soft glow in the character's own colour,
    the character on the right (same face as on the phone), empty space on the left for the app."""
    W, H = 1920, 1080
    small = phone.resize((24, 42), Image.LANCZOS)
    pixels = sorted(small.getdata(), key=lambda c: max(c) - min(c), reverse=True)[:60]  # most colourful
    glow = tuple(min(255, int(sum(p[i] for p in pixels) / len(pixels) * 1.15)) for i in range(3))
    fw = int(H * phone.width / phone.height)
    x0 = W - fw - int(W * 0.06)
    cx = x0 + fw // 2
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse((cx - W * 0.42, H * 0.35 - H * 0.75, cx + W * 0.42, H * 0.35 + H * 0.75), fill=135)
    d.ellipse((-W * 0.25, H * 0.55, W * 0.35, H * 1.4), fill=60)  # faint glow bottom-left
    mask = mask.filter(ImageFilter.GaussianBlur(260))
    bg = Image.composite(Image.new("RGB", (W, H), glow), Image.new("RGB", (W, H), (8, 7, 12)), mask)
    fg = phone.resize((fw, H), Image.LANCZOS)
    feather = int(fw * 0.24)
    ramp = [255 if feather <= x <= fw - feather else int(255 * (min(x, fw - x) / feather) ** 1.6) for x in range(fw)]
    mask = Image.new("L", (fw, 1))
    mask.putdata(ramp)
    mask = mask.resize((fw, H))
    bg.paste(fg, (x0, 0), mask)
    bg.save(path, "WEBP", quality=90, method=6)


def make(cid: str) -> str:
    """Phone picture first (generated), then the PC picture built from it."""
    w, h = 1080, 1920
    prompt = f"{CHARACTERS[cid]}. {PHONE}. {STYLE}"
    phone_path = os.path.join(OUT, f"{cid}_phone.webp")
    errors, img, src = [], None, ""
    for attempt in range(4):
        try:
            raw = pollinations(prompt, 1056, 2016, SEEDS[cid])  # ≤2048 px; after the logo strip is cut → ~9:16
            img, src = finish(raw, w, h, phone_path, crop_bottom=WATERMARK_CROP), "pollinations"
            break
        except Exception as e:  # noqa: BLE001
            detail = e.read().decode(errors="ignore")[:200] if isinstance(e, urllib.error.HTTPError) else ""
            errors.append(f"pollinations#{attempt + 1}: {e} {detail}")
            time.sleep(15 * (attempt + 1))
    if img is None and GEMINI_KEY:
        try:
            img, src = finish(gemini(prompt, "9:16"), w, h, phone_path), "gemini"
        except Exception as e:  # noqa: BLE001
            errors.append(f"gemini: {e}")
    if img is None:
        raise RuntimeError("; ".join(errors))
    make_pc(img, os.path.join(OUT, f"{cid}_pc.webp"))
    return f"{src}, phone {os.path.getsize(phone_path) // 1024} KB"


def main() -> None:
    force = "--force" in sys.argv
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    os.makedirs(OUT, exist_ok=True)
    failed = []
    for cid in CHARACTERS:
        if only and cid not in only:
            continue
        if os.path.exists(os.path.join(OUT, f"{cid}_phone.webp")) and not force:
            print(f"skip {cid} (exists)")
            continue
        try:
            msg = f"ok   {cid}: {make(cid)}"
        except Exception as e:  # noqa: BLE001
            msg = f"FAIL {cid}: {e}"
            failed.append(cid)
        print(msg, flush=True)
        LOG.append(msg)
        time.sleep(8)  # be gentle with the free service
    LOG.append(f"failed: {failed or 'none'}")
    log_dir = os.path.join(OUT, "..", "..", "..", "docs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "character_generation_log.txt"), "w") as f:
        f.write("\n".join(LOG) + "\n")
    print("failed:", failed or "none")
    sys.exit(1 if failed and len(failed) == len(only or CHARACTERS) else 0)


if __name__ == "__main__":
    main()
