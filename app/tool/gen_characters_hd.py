"""Sharp, high-resolution anime character pictures (v2).

For one character id: draws a portrait (phone) and a landscape (PC) picture with an anime SDXL model
(Animagine XL, runs on the free GitHub CPU runner), then enlarges them 4x with the Real-ESRGAN anime model and
saves app/assets/characters/<id>_phone.webp (1440x2560) and <id>_pc.webp (2560x1440).
Soft, single-colour lighting (no strong multi-colour neon).

Run by .github/workflows/characters-hd.yml:  python tool/gen_characters_hd.py f1 [--steps 26]
"""
import argparse
import gc
import os
import time
import urllib.request

import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "characters")
MODEL = "cagliostrolab/animagine-xl-3.1"
ESRGAN_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth"

QUALITY = "masterpiece, best quality, very aesthetic, absurdres, highres, detailed eyes, detailed face, clean lineart"
NEGATIVE = ("nsfw, lowres, bad anatomy, bad hands, text, error, missing fingers, extra digits, fewer digits, cropped, "
            "worst quality, low quality, normal quality, jpeg artifacts, signature, watermark, username, blurry, "
            "artist name, child, loli, shota, chibi, multiple views, oversaturated, harsh neon, strong glow, "
            "chromatic aberration")

# who they are (same looks as before), with ONE soft light colour each
CHARACTERS = {
    "f1": ("1girl, solo, adult woman, mature female, long straight black hair, red eyes, gentle smile, "
           "black high-collar blouse with red accents", "dark room, soft red rim light"),
    "f2": ("1girl, solo, adult woman, mature female, silver hair, lavender hair, wavy hair, violet eyes, smile, "
           "futuristic purple jacket, holding a rose", "night city bokeh, soft purple light"),
    "f3": ("1girl, solo, adult woman, mature female, short teal hair, bob cut, aqua eyes, confident smile, "
           "white tech jacket", "dark blue background, soft cyan light"),
    "f4": ("1girl, solo, adult woman, mature female, long pink hair, pink eyes, gentle smile, cream cardigan, "
           "cherry blossoms, falling petals", "night, soft warm pink light"),
    "f5": ("1girl, solo, adult woman, mature female, blonde hair, ponytail, golden eyes, confident smile, "
           "black and gold outfit", "dark elegant background, soft golden light"),
    "m1": ("1boy, solo, adult man, mature male, short dark blue hair, blue eyes, calm expression, black techwear jacket",
           "rainy night city bokeh, soft blue light"),
    "m2": ("1boy, solo, adult man, mature male, messy black hair, red eyes, cool expression, dark long coat with red trim",
           "dark background, soft red rim light"),
    "m3": ("1boy, solo, adult man, mature male, short brown hair, brown eyes, kind smile, broad shoulders, green hoodie",
           "cozy room, soft green light"),
    "m4": ("1boy, solo, adult man, mature male, short silver hair, light blue eyes, cheerful smile, "
           "white and sky blue jacket", "starry night sky, soft cyan light"),
    "m5": ("1boy, solo, adult man, mature male, warm brown hair, amber eyes, confident smile, orange and black bomber jacket",
           "sunset sky, soft orange light"),
}
SEEDS = {cid: 4100 + i * 97 for i, cid in enumerate(CHARACTERS)}


# ---------------- Real-ESRGAN (RRDBNet, anime 6B) ----------------
class RDB(nn.Module):
    def __init__(self, nf=64, gc_=32):
        super().__init__()
        self.conv1 = nn.Conv2d(nf, gc_, 3, 1, 1)
        self.conv2 = nn.Conv2d(nf + gc_, gc_, 3, 1, 1)
        self.conv3 = nn.Conv2d(nf + 2 * gc_, gc_, 3, 1, 1)
        self.conv4 = nn.Conv2d(nf + 3 * gc_, gc_, 3, 1, 1)
        self.conv5 = nn.Conv2d(nf + 4 * gc_, nf, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, nf):
        super().__init__()
        self.rdb1, self.rdb2, self.rdb3 = RDB(nf), RDB(nf), RDB(nf)

    def forward(self, x):
        return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, nb=6, nf=64):
        super().__init__()
        self.conv_first = nn.Conv2d(3, nf, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(nf) for _ in range(nb)])
        self.conv_body = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_hr = nn.Conv2d(nf, nf, 3, 1, 1)
        self.conv_last = nn.Conv2d(nf, 3, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(0.2, True)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


def load_esrgan() -> nn.Module:
    path = "/tmp/anime6b.pth"
    if not os.path.exists(path):
        urllib.request.urlretrieve(ESRGAN_URL, path)
    sd = torch.load(path, map_location="cpu")
    sd = sd.get("params_ema", sd.get("params", sd))
    net = RRDBNet()
    net.load_state_dict(sd, strict=True)
    return net.eval()


@torch.no_grad()
def upscale4(net: nn.Module, img: Image.Image, tile: int = 192, pad: int = 16) -> Image.Image:
    import numpy as np
    arr = torch.from_numpy(np.asarray(img.convert("RGB")).astype("float32") / 255.0).permute(2, 0, 1)[None]
    _, _, h, w = arr.shape
    out = torch.zeros((1, 3, h * 4, w * 4))
    for y in range(0, h, tile):
        for x in range(0, w, tile):
            y0, x0 = max(y - pad, 0), max(x - pad, 0)
            y1, x1 = min(y + tile + pad, h), min(x + tile + pad, w)
            res = net(arr[:, :, y0:y1, x0:x1]).clamp(0, 1)
            ty, tx = (y - y0) * 4, (x - x0) * 4
            th, tw = (min(y + tile, h) - y) * 4, (min(x + tile, w) - x) * 4
            out[:, :, y * 4:y * 4 + th, x * 4:x * 4 + tw] = res[:, :, ty:ty + th, tx:tx + tw]
    data = (out[0].permute(1, 2, 0).numpy() * 255).round().astype("uint8")
    return Image.fromarray(data)


def cover(img: Image.Image, size: tuple[int, int], focus_y: float = 0.4) -> Image.Image:
    tw, th = size
    s = max(tw / img.width, th / img.height)
    im = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    left = (im.width - tw) // 2
    top = int((im.height - th) * focus_y)
    return im.crop((left, top, left + tw, top + th))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cid")
    ap.add_argument("--steps", type=int, default=26)
    a = ap.parse_args()
    who, light = CHARACTERS[a.cid]
    torch.set_num_threads(os.cpu_count() or 4)

    from diffusers import DPMSolverMultistepScheduler, StableDiffusionXLPipeline
    t0 = time.time()
    pipe = StableDiffusionXLPipeline.from_pretrained(MODEL, torch_dtype=torch.float32, use_safetensors=True)
    pipe.scheduler = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config, use_karras_sigmas=True)
    pipe.set_progress_bar_config(disable=False)

    jobs = [
        ("phone", 832, 1216, f"{who}, upper body, looking at viewer, portrait, {light}, simple background, {QUALITY}"),
        ("pc", 1216, 832, f"{who}, upper body, looking at viewer, wide shot, {light}, scenery, {QUALITY}"),
    ]
    # encode the prompts first, then free the text encoders (saves ~3 GB of memory on the CPU runner)
    embeds = {}
    for name, _, _, prompt in jobs:
        embeds[name] = pipe.encode_prompt(prompt=prompt, negative_prompt=NEGATIVE, device="cpu",
                                          num_images_per_prompt=1, do_classifier_free_guidance=True)
    pipe.text_encoder = None
    pipe.text_encoder_2 = None
    gc.collect()
    print(f"model ready in {time.time() - t0:.0f}s", flush=True)

    raw = {}
    for name, w, h, _ in jobs:
        pe, npe, ppe, nppe = embeds[name]
        t1 = time.time()
        g = torch.Generator("cpu").manual_seed(SEEDS[a.cid])
        img = pipe(prompt_embeds=pe, negative_prompt_embeds=npe, pooled_prompt_embeds=ppe,
                   negative_pooled_prompt_embeds=nppe, width=w, height=h, num_inference_steps=a.steps,
                   guidance_scale=6.5, generator=g).images[0]
        raw[name] = img
        img.save(f"/tmp/{a.cid}_{name}_raw.png")
        print(f"{name}: drawn in {time.time() - t1:.0f}s", flush=True)
    del pipe
    gc.collect()

    net = load_esrgan()
    os.makedirs(OUT, exist_ok=True)
    for name, size in (("phone", (1440, 2560)), ("pc", (2560, 1440))):
        t1 = time.time()
        big = upscale4(net, raw[name])
        final = cover(big, size, focus_y=0.3 if name == "phone" else 0.35)
        final = final.filter(ImageFilter.UnsharpMask(radius=1.2, percent=40, threshold=2))
        final.save(os.path.join(OUT, f"{a.cid}_{name}.webp"), "WEBP", quality=92, method=6)
        print(f"{name}: sharpened in {time.time() - t1:.0f}s", flush=True)


if __name__ == "__main__":
    main()
