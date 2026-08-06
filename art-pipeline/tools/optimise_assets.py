"""Convert game assets to WebP at display resolution, and rewrite the manifest to match.

341 PNGs at 1536x1536 RGBA came to 949MB, which is not shippable — the plan targets under 200MB
of download and iOS install conversion falls off well before that.

Two levers, both safe:

  RESOLUTION  The creature is only ever drawn inside the hatch, which is 536 logical px wide.
              At the 2.6x inspection zoom that is ~1390 px, and on a 3x device the hatch itself is
              ~1600 physical px — so 1536 is justified for the BODY. Nothing else is ever inspected
              that closely: X-ray plates are shown at hatch size or smaller (the handbook reference
              is 212px), and blink/mouth frames flash for a tenth of a second.

  FORMAT      Lossy WebP with alpha at quality 88 is visually indistinguishable from PNG on
              watercolour art — there are no hard edges or flat colour fields for it to ruin — and
              is roughly an order of magnitude smaller.

The 1536 PNG masters stay in art-pipeline/ as the source of truth; this only rewrites what ships.

    python optimise_assets.py            # convert and rewrite the manifest
    python optimise_assets.py --dry-run  # report the saving without touching anything
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT.parent / "game"
CREATURES = GAME / "assets" / "creatures"
XRAYS = GAME / "assets" / "xray"
BACKDROPS = GAME / "assets" / "backdrops"
MANIFEST = GAME / "data" / "roster.json"

QUALITY = 88
# 4, not 6: method 6 is an exhaustive search that costs minutes across the roster for a couple
# of percent. Not worth it for art that is already lossy-tolerant.
METHOD = 4

# Per-role budgets. The body carries the inspection zoom; nothing else does.
# Roles constrained by WIDTH rather than longest edge. The backdrop is a portrait full-canvas
# image; capping its longest edge shrinks the width and desynchronises it from the opening rect.
WIDTH_CONSTRAINED = {"backdrop"}

MAX_SIZE = {
    "body": 1536,
    "pupil": 1536,        # must match the body pixel-for-pixel to stay registered
    "frame": 1024,        # on screen for ~0.1-0.5s
    "anomaly": 1536,      # inspected as closely as the body
    "xray": 1024,         # shown at hatch size, and at 212px in the handbook
    "backdrop": 1080,     # exactly the canvas width; larger is wasted
}


def role_of(path: Path) -> str:
    name = path.stem
    if path.parent.name == "xray":
        return "xray"
    if path.parent.parent.name == "backdrops" or path.parent.name == "backdrops":
        return "backdrop"
    if name == "body":
        return "body"
    if name.startswith("pupil_"):
        return "pupil"
    if name.startswith("frame_"):
        return "frame"
    if name.startswith("anom_"):
        return "anomaly"
    return "frame"


def convert(path: Path, dry_run: bool) -> tuple[int, int]:
    """Returns (bytes_before, bytes_after)."""
    before = path.stat().st_size
    role = role_of(path)
    limit = MAX_SIZE.get(role, 1024)

    with Image.open(path) as im:
        im = im.convert("RGBA")
        measure = im.width if role in WIDTH_CONSTRAINED else max(im.size)
        if measure > limit:
            scale = limit / measure
            im = im.resize((round(im.width * scale), round(im.height * scale)), Image.LANCZOS)
        target = path.with_suffix(".webp")
        if dry_run:
            import io
            buf = io.BytesIO()
            im.save(buf, "WEBP", quality=QUALITY, method=METHOD)
            return before, buf.tell()
        im.save(target, "WEBP", quality=QUALITY, method=METHOD)

    after = target.stat().st_size
    path.unlink()
    # Godot's import metadata for the deleted PNG would otherwise linger and re-import a ghost.
    imp = path.with_suffix(path.suffix + ".import")
    if imp.exists():
        imp.unlink()
    return before, after


def rewrite_manifest() -> None:
    text = MANIFEST.read_text(encoding="utf-8")
    # Blunt but exactly right: every asset reference in the manifest is a .png that this script
    # has just replaced with a .webp of the same stem.
    MANIFEST.write_text(text.replace(".png", ".webp"), encoding="utf-8")
    print(f"manifest rewritten -> .webp")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    targets: list[Path] = []
    for root in (CREATURES, XRAYS, BACKDROPS):
        if root.exists():
            targets.extend(sorted(root.rglob("*.png")))

    if not targets:
        raise SystemExit("no PNGs found — already converted?")

    total_before = total_after = 0
    per_role: dict[str, list[int]] = {}
    for i, p in enumerate(targets, 1):
        b, a = convert(p, args.dry_run)
        if i % 40 == 0:
            print(f"  ...{i}/{len(targets)}", flush=True)
        total_before += b
        total_after += a
        per_role.setdefault(role_of(p), [0, 0])
        per_role[role_of(p)][0] += b
        per_role[role_of(p)][1] += a

    mb = 1024 * 1024
    print(f"{len(targets)} files")
    for role, (b, a) in sorted(per_role.items()):
        print(f"  {role:9} {b / mb:7.1f} MB -> {a / mb:6.1f} MB")
    print(f"  {'TOTAL':9} {total_before / mb:7.1f} MB -> {total_after / mb:6.1f} MB "
          f"({total_after / max(total_before, 1) * 100:.1f}%)")

    if not args.dry_run:
        rewrite_manifest()


if __name__ == "__main__":
    main()
