"""Turn a generated clinic-room render into a game backdrop plus the window-opening rect.

The patient has to appear *inside* the service hatch, not floating in front of the wall, so
the game needs to know where the opening is in pixel terms. Rather than hand-measuring it
(and re-measuring every time the backdrop is regenerated), find it: the opening is by far the
darkest large blob in the image, because it was prompted as "solid flat black and completely
empty".

The rect is written next to the image as JSON and read by the Shift screen, which clips the
patient to it. That means a new backdrop can be dropped in and the framing follows
automatically.

Usage:
    python prepare_room.py <room.png> <out_dir> [--width 1080] [--height 1920]
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image


def find_opening(img: Image.Image) -> tuple[int, int, int, int]:
    """Bounding box (x, y, w, h) of the dark window opening."""
    gray = np.asarray(img.convert("L"), dtype=np.float32)
    h, w = gray.shape

    # The opening is the darkest thing in frame; take a low absolute threshold rather than a
    # percentile so a lighter render does not drag the cutoff up into the wall shadows.
    dark = gray < max(48.0, float(np.percentile(gray, 8.0)))

    # Row/column projections: the opening is a large solid rectangle, so the rows and columns
    # it occupies are overwhelmingly dark. Projections are far more robust here than
    # connected components, because the mullion bars split the opening into several blobs.
    row_frac = dark.mean(axis=1)
    col_frac = dark.mean(axis=0)

    # 0.22 rather than something stricter: watercolour panes are not uniformly dark (one side
    # of this render reads bluer than the other), and a tight threshold clips the opening
    # short, which would cut the creature off mid-pane.
    rows = np.nonzero(row_frac > 0.22)[0]
    cols = np.nonzero(col_frac > 0.22)[0]
    if len(rows) == 0 or len(cols) == 0:
        raise SystemExit("could not find a dark opening — check the render")

    # Take the longest contiguous run in each axis, so pinned notices or a dark skirting board
    # elsewhere in the frame cannot widen the box.
    def longest_run(idx: np.ndarray) -> tuple[int, int]:
        best = (idx[0], idx[0])
        start = idx[0]
        prev = idx[0]
        for v in idx[1:]:
            if v != prev + 1:
                if prev - start > best[1] - best[0]:
                    best = (start, prev)
                start = v
            prev = v
        if prev - start > best[1] - best[0]:
            best = (start, prev)
        return best

    y0, y1 = longest_run(rows)
    x0, x1 = longest_run(cols)
    return int(x0), int(y0), int(x1 - x0 + 1), int(y1 - y0 + 1)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source", type=Path)
    ap.add_argument("out_dir", type=Path)
    ap.add_argument("--width", type=int, default=1080)
    ap.add_argument("--height", type=int, default=1920)
    ap.add_argument("--name", default="clinic_night")
    args = ap.parse_args()

    img = Image.open(args.source).convert("RGB")
    rect = find_opening(img)

    # Scale the render to the game's logical canvas and carry the rect across with it.
    sx = args.width / img.width
    sy = args.height / img.height
    scaled_rect = [
        int(round(rect[0] * sx)), int(round(rect[1] * sy)),
        int(round(rect[2] * sx)), int(round(rect[3] * sy)),
    ]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_png = args.out_dir / f"{args.name}.png"
    img.resize((args.width, args.height), Image.LANCZOS).save(out_png)

    meta = {
        "backdrop": out_png.name,
        "canvas": [args.width, args.height],
        # x, y, w, h of the hatch the patient is framed by, in canvas coordinates.
        "opening": scaled_rect,
    }
    out_json = args.out_dir / f"{args.name}.json"
    out_json.write_text(json.dumps(meta, indent=2), encoding="utf-8")

    # Overlay so the detection can be eyeballed before it is trusted.
    dbg = img.copy()
    from PIL import ImageDraw
    d = ImageDraw.Draw(dbg, "RGBA")
    d.rectangle([rect[0], rect[1], rect[0] + rect[2], rect[1] + rect[3]],
                outline=(255, 60, 60, 255), width=6)
    d.rectangle([rect[0], rect[1], rect[0] + rect[2], rect[1] + rect[3]],
                fill=(255, 60, 60, 40))
    dbg.save(args.out_dir / f"_debug_{args.name}.png")

    print(f"source {img.width}x{img.height}  opening {rect}")
    print(f"canvas {args.width}x{args.height}  opening {scaled_rect}")
    print(f"  {out_png}\n  {out_json}")


if __name__ == "__main__":
    main()
