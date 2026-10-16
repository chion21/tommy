"""Sharpen the character pictures with Real-ESRGAN (anime model, free/open source) and build the PC versions.

For every assets/characters/<id>_phone.webp smaller than 1440x2560:
  AI-upscale ×4 → 1440x2560 phone picture, then a 2560x1440 PC picture from it (same face, character on the right).
Run in CI (needs: pip install torch --index-url https://download.pytorch.org/whl/cpu ; pillow numpy)."""
import os
import sys
import urllib.request

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFilter
from torch import nn
from torch.nn import functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "characters")
MODEL_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
MODEL = os.path.join(HERE, ".cache", "realesr-animevideov3.pth")
PHONE = (1440, 2560)
PC = (2560, 1440)


class SRVGGNetCompact(nn.Module):
    """Real-ESRGAN compact network (same layout as the official one, so the official weights load)."""

    def __init__(self, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        self.upscale = upscale
        body = [nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        for _ in range(num_conv):
            body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_parameters=num_feat)]
        body.append(nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))
        self.body = nn.ModuleList(body)
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        return self.upsampler(out) + F.interpolate(x, scale_factor=self.upscale, mode="nearest")


def load_model() -> nn.Module:
    if not os.path.exists(MODEL):
        os.makedirs(os.path.dirname(MODEL), exist_ok=True)
        print("downloading Real-ESRGAN model…")
        urllib.request.urlretrieve(MODEL_URL, MODEL)
    state = torch.load(MODEL, map_location="cpu", weights_only=True)
    state = state.get("params", state.get("params_ema", state))
    net = SRVGGNetCompact()
    net.load_state_dict(state, strict=True)
    return net.eval()


@torch.inference_mode()
def upscale4(net: nn.Module, img: Image.Image, tile: int = 256, pad: int = 12) -> Image.Image:
    """×4 upscale in tiles (keeps memory low on the CI machine)."""
    a = torch.from_numpy(np.asarray(img.convert("RGB"), dtype=np.float32) / 255.0).permute(2, 0, 1)[None]
    _, _, h, w = a.shape
    out = torch.zeros((1, 3, h * 4, w * 4))
    for y in range(0, h, tile):
        for x in range(0, w, tile):
            y0, x0 = max(y - pad, 0), max(x - pad, 0)
            y1, x1 = min(y + tile + pad, h), min(x + tile + pad, w)
            res = net(a[:, :, y0:y1, x0:x1])
            ty, tx = (y - y0) * 4, (x - x0) * 4
            th, tw = (min(y + tile, h) - y) * 4, (min(x + tile, w) - x) * 4
            out[:, :, y * 4:y * 4 + th, x * 4:x * 4 + tw] = res[:, :, ty:ty + th, tx:tx + tw]
    arr = (out[0].clamp(0, 1).permute(1, 2, 0).numpy() * 255.0).round().astype(np.uint8)
    return Image.fromarray(arr)


def cover(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    w, h = size
    t = w / h
    if img.width / img.height > t:
        nw = int(img.height * t)
        img = img.crop(((img.width - nw) // 2, 0, (img.width - nw) // 2 + nw, img.height))
    else:
        nh = int(img.width / t)
        img = img.crop((0, (img.height - nh) // 2, img.width, (img.height - nh) // 2 + nh))
    return img.resize(size, Image.LANCZOS)


def make_pc(phone: Image.Image, path: str) -> None:
    """Dark backdrop with a soft glow in the character's own colour, character on the right."""
    W, H = PC
    small = phone.resize((24, 42), Image.LANCZOS)
    pixels = sorted(small.getdata(), key=lambda c: max(c) - min(c), reverse=True)[:60]
    glow = tuple(min(255, int(sum(p[i] for p in pixels) / len(pixels) * 1.15)) for i in range(3))
    fw = int(H * phone.width / phone.height)
    x0 = W - fw - int(W * 0.06)
    cx = x0 + fw // 2
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse((cx - W * 0.42, H * 0.35 - H * 0.75, cx + W * 0.42, H * 0.35 + H * 0.75), fill=135)
    d.ellipse((-W * 0.25, H * 0.55, W * 0.35, H * 1.4), fill=60)
    mask = mask.filter(ImageFilter.GaussianBlur(int(260 * W / 1920)))
    bg = Image.composite(Image.new("RGB", (W, H), glow), Image.new("RGB", (W, H), (8, 7, 12)), mask)
    fg = phone.resize((fw, H), Image.LANCZOS)
    feather = int(fw * 0.24)
    ramp = [255 if feather <= x <= fw - feather else int(255 * (min(x, fw - x) / feather) ** 1.6) for x in range(fw)]
    m = Image.new("L", (fw, 1))
    m.putdata(ramp)
    bg.paste(fg, (x0, 0), m.resize((fw, H)))
    bg.save(path, "WEBP", quality=90, method=6)


def main() -> None:
    force = "--force" in sys.argv
    todo = []
    for name in sorted(os.listdir(OUT)):
        if name.endswith("_phone.webp"):
            with Image.open(os.path.join(OUT, name)) as im:
                if force or im.width < PHONE[0]:
                    todo.append(name)
    if not todo:
        print("all pictures already sharp")
        return
    net = load_model()
    torch.set_num_threads(os.cpu_count() or 2)
    for name in todo:
        path = os.path.join(OUT, name)
        img = Image.open(path).convert("RGB")
        if img.width > 800:  # was stretched earlier → bring back to the real size before AI upscaling
            img = img.resize((img.width // 2, img.height // 2), Image.LANCZOS)
        big = upscale4(net, img)
        phone = cover(big, PHONE)
        phone.save(path, "WEBP", quality=90, method=6)
        make_pc(phone, path.replace("_phone.webp", "_pc.webp"))
        print(f"sharp {name}: {img.size} -> {phone.size} + PC {PC}", flush=True)


if __name__ == "__main__":
    main()
