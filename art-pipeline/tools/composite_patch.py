"""Composite a generated patch back onto a base image through a mask.

This is the second half of the "add a feature" (Track B) variant recipe. Track A — modifying
a feature that already exists — is done entirely in ComfyUI and needs nothing from here.

WHY TRACK B EXISTS: at 1024x1024 a forehead mask is only ~150x140px, a small enough
fraction of the latent that the model will not construct a new feature inside it no matter
how high the denoise or how explicit the prompt. Measured on the axolotl: asking for a
third eye full-frame at denoise 1.0 moved the masked region by 4.2/255 and produced no eye.
The same prompt on a 384px crop upscaled to 1024 (2.67x effective resolution) moved it by
37.9/255 and produced a clean, style-matched eye.

    Track A  modify existing feature   full frame, denoise 0.65-0.95, ComfyUI only
    Track B  add new feature           crop -> 1024 -> denoise 1.0 -> this script

Compositing here rather than in ComfyUI keeps outside-mask pixels byte-identical: they are
read straight from the base file and never make a VAE round trip. Measured drift 0.000/255.

Usage:
    # 1. cut the crop and its mask
    python composite_patch.py cut --base B.png --mask M.png --size 384 --out-dir DIR
    # 2. inpaint DIR/crop.png in ComfyUI at denoise 1.0 using DIR/crop_mask.png
    # 3. paste the result back
    python composite_patch.py paste --base B.png --mask M.png --patch GEN.png \\
        --box-file DIR/box.txt --out VARIANT.png
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

WORK_RES = 1024


def _mask_centre(mask: Image.Image) -> tuple[int, int]:
    m = np.asarray(mask.convert("L"))
    ys, xs = np.nonzero(m > 8)
    if len(xs) == 0:
        raise SystemExit("mask is empty")
    return (xs.min() + xs.max()) // 2, (ys.min() + ys.max()) // 2


def cut(base_path: Path, mask_path: Path, size: int, out_dir: Path) -> None:
    base = Image.open(base_path).convert("RGB")
    mask = Image.open(mask_path).convert("L")
    cx, cy = _mask_centre(mask)
    w, h = base.size

    # Clamp so the crop stays inside the canvas; the model needs surrounding face context
    # to match lighting and style, so keep the window generous rather than tight.
    half = size // 2
    x0 = max(0, min(cx - half, w - size))
    y0 = max(0, min(cy - half, h - size))
    box = (x0, y0, x0 + size, y0 + size)

    out_dir.mkdir(parents=True, exist_ok=True)
    base.crop(box).resize((WORK_RES, WORK_RES), Image.LANCZOS).save(out_dir / "crop.png")
    mask.crop(box).resize((WORK_RES, WORK_RES), Image.LANCZOS).save(out_dir / "crop_mask.png")
    (out_dir / "box.txt").write_text(",".join(str(v) for v in box), encoding="utf-8")

    scale = WORK_RES / size
    print(f"crop {box} ({size}px) -> {WORK_RES}px  = {scale:.2f}x effective resolution")
    print(f"  {out_dir / 'crop.png'}\n  {out_dir / 'crop_mask.png'}")


def paste(base_path: Path, mask_path: Path, patch_path: Path, box_file: Path, out_path: Path) -> None:
    base = Image.open(base_path).convert("RGB")
    mask = Image.open(mask_path).convert("L")
    patch = Image.open(patch_path).convert("RGB")
    box = tuple(int(v) for v in box_file.read_text(encoding="utf-8").split(","))
    size = box[2] - box[0]

    canvas = base.copy()
    canvas.paste(patch.resize((size, size), Image.LANCZOS), (box[0], box[1]))
    # Composite with the FULL-RESOLUTION original mask, not the scaled crop mask: the
    # feathered original is what guarantees the seam lands inside painted texture and that
    # every pixel outside it comes from the untouched base.
    out = Image.composite(canvas, base, mask)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out.save(out_path)

    drift = np.abs(
        np.asarray(out, dtype=np.float32) - np.asarray(base, dtype=np.float32)
    ).max(axis=2)
    outside = np.asarray(mask) < 2
    peak = float(drift[outside].max()) if outside.any() else 0.0
    print(f"wrote {out_path}")
    print(f"outside-mask peak drift: {peak:.3f}/255  (must be 0 — run flip_diff.py to gate)")


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("cut", help="extract a native-resolution crop + mask for inpainting")
    c.add_argument("--base", required=True, type=Path)
    c.add_argument("--mask", required=True, type=Path)
    c.add_argument("--size", type=int, default=384)
    c.add_argument("--out-dir", required=True, type=Path)

    p = sub.add_parser("paste", help="composite the generated patch back onto the base")
    p.add_argument("--base", required=True, type=Path)
    p.add_argument("--mask", required=True, type=Path)
    p.add_argument("--patch", required=True, type=Path)
    p.add_argument("--box-file", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)

    args = ap.parse_args()
    if args.cmd == "cut":
        cut(args.base, args.mask, args.size, args.out_dir)
    else:
        paste(args.base, args.mask, args.patch, args.box_file, args.out)


if __name__ == "__main__":
    main()
