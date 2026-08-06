"""Derive anomaly masks for a creature base by locating its eyes.

The roster is all front-facing and symmetrical by design law, so the two pupils are the
only landmarks needed: everything else (mouth, forehead) is a fixed proportion of the
inter-eye distance. That makes masks reproducible across all 20 creatures instead of
hand-painted per creature, and it keeps mask geometry consistent so the difficulty of an
anomaly tier means the same thing on every species.

Hand-painted masks still win for irregular species (moth, crow) — this is the fast path,
not the only path. Check the debug overlay before trusting a mask.

Usage:
    python make_masks.py <base.png> <out_dir> [--debug]
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# Masks are built at this feather radius so the composite seam falls inside painted
# texture rather than on a hard edge.
FEATHER_PX = 12


def _label_blobs(dark: np.ndarray) -> list[np.ndarray]:
    """Connected components over a boolean mask, 4-connectivity, iterative BFS.

    Rolled by hand rather than pulling in scipy — the dark-pixel set is a few thousand
    pixels, so a plain queue is fast and keeps the pipeline dependency-light.
    """
    h, w = dark.shape
    seen = np.zeros_like(dark, dtype=bool)
    blobs: list[np.ndarray] = []
    for sy, sx in zip(*np.nonzero(dark)):
        if seen[sy, sx]:
            continue
        stack = [(sy, sx)]
        seen[sy, sx] = True
        pixels = []
        while stack:
            y, x = stack.pop()
            pixels.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < h and 0 <= nx < w and dark[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        blobs.append(np.array(pixels))
    return blobs


def _blob_candidates(gray, x0, y0, x1, y1, percentiles, want_dark=True):
    """Compact blobs within a region, as (area, cx, cy, radius) tuples."""
    region = gray[y0:y1, x0:x1]
    out = []
    for pct in percentiles:
        thresh = np.percentile(region, pct if want_dark else 100.0 - pct)
        mask = (region <= thresh) if want_dark else (region >= thresh)
        found = []
        for pixels in _label_blobs(mask):
            ys, xs = pixels[:, 0], pixels[:, 1]
            bh = ys.max() - ys.min() + 1
            bw = xs.max() - xs.min() + 1
            area = len(pixels)
            if area < 24:
                continue
            aspect = bw / bh if bh else 99.0
            if not (0.35 < aspect < 2.8):
                continue
            if area / (bw * bh) < 0.34:
                continue
            if bw > (x1 - x0) * 0.45 or bh > (y1 - y0) * 0.55:
                continue
            found.append((area, float(xs.mean() + x0), float(ys.mean() + y0),
                          max(bw, bh) / 2.0))
        out.extend(found)
    # Near-duplicates across thresholds are harmless (the scorer picks one) but wasteful, so
    # collapse blobs whose centres nearly coincide, keeping the larger.
    deduped: list = []
    for c in sorted(out, key=lambda t: -t[3]):
        if not any(abs(c[1] - d[1]) < c[3] and abs(c[2] - d[2]) < c[3] for d in deduped):
            deduped.append(c)
    return deduped


def creature_bbox(img: Image.Image) -> tuple[int, int, int, int]:
    """Bounding box of the painted creature, from the flat backdrop.

    The base prompt pins a plain flat dark charcoal background specifically so the subject can be
    separated without a segmentation model. Corners are sampled rather than assuming a colour, in
    case the backdrop shade drifts between renders.
    """
    rgb = np.asarray(img.convert("RGB"), dtype=np.float32)
    h, w = rgb.shape[:2]
    patch = 24
    corners = np.concatenate([
        rgb[:patch, :patch].reshape(-1, 3), rgb[:patch, -patch:].reshape(-1, 3),
        rgb[-patch:, :patch].reshape(-1, 3), rgb[-patch:, -patch:].reshape(-1, 3),
    ])
    bg = np.median(corners, axis=0)
    fg = np.linalg.norm(rgb - bg, axis=2) > 40.0

    # Ignore sparse rows/columns so a stray speck cannot inflate the box.
    rows = np.nonzero(fg.mean(axis=1) > 0.02)[0]
    cols = np.nonzero(fg.mean(axis=0) > 0.02)[0]
    if len(rows) == 0 or len(cols) == 0:
        return 0, 0, w, h
    return int(cols[0]), int(rows[0]), int(cols[-1] - cols[0] + 1), int(rows[-1] - rows[0] + 1)


def _sclera_contrast(gray, cx, cy, r):
    """How much brighter the ring around a blob is than the blob itself.

    This is the feature that actually distinguishes an eye from everything else that is dark,
    compact and symmetric. A pupil sits inside a painted sclera, so its surroundings are much
    LIGHTER; an ear tip, a paw shadow or a raccoon's eye mask has no such ring. Threshold tuning
    on darkness, size and symmetry alone plateaued around 14/20 because none of those describe
    what an eye actually is.
    """
    h, w = gray.shape
    r = max(r, 3.0)
    y0, y1 = int(max(0, cy - r * 2.4)), int(min(h, cy + r * 2.4))
    x0, x1 = int(max(0, cx - r * 2.4)), int(min(w, cx + r * 2.4))
    if y1 - y0 < 4 or x1 - x0 < 4:
        return -999.0
    ys, xs = np.mgrid[y0:y1, x0:x1]
    d = np.sqrt((xs - cx) ** 2 + (ys - cy) ** 2)
    patch = gray[y0:y1, x0:x1]
    core = d <= r * 0.75
    ring = (d >= r * 1.35) & (d <= r * 2.3)
    if core.sum() < 4 or ring.sum() < 8:
        return -999.0
    return float(patch[ring].mean() - patch[core].mean())


def _best_symmetric_pair(cands, centre_x, min_r, max_r, min_span, max_span, ideal_span,
                         gray=None, min_contrast=18.0):
    """Pick the pair that best looks like two eyes on a symmetric face.

    Front-facing symmetry is the design law for the whole roster, so it is the strongest signal
    available: mirrored about the creature's centre, level with each other, similar size. A
    spurious blob (a nose, a dark marking, a shadow) rarely has a convincing mirror twin.

    The radius gate is what makes this reliable. Without it, two symmetric specks beat two real
    eyes on every symmetry term, which is exactly how v2 started returning 5px pupils.
    """
    usable = [c for c in cands if min_r <= c[3] <= max_r]
    # Keep only blobs that sit inside a lighter surround, i.e. that look like pupils.
    if gray is not None:
        scored = [(c, _sclera_contrast(gray, c[1], c[2], c[3])) for c in usable]
        eyes = [(c, v) for c, v in scored if v >= min_contrast]
        if len(eyes) >= 2:
            usable = [c for c, _ in eyes]
            contrast = {id(c): v for c, v in eyes}
        else:
            contrast = {id(c): v for c, v in scored}
    else:
        contrast = {}
    best = None
    best_score = 1e9
    for a in usable:
        if a[1] >= centre_x:
            continue
        for b in usable:
            if b[1] <= centre_x:
                continue
            span = b[1] - a[1]
            if span < min_span or span > max_span:
                continue
            mid = (a[1] + b[1]) / 2.0
            asym = abs(mid - centre_x) / max(span, 1.0)
            level = abs(a[2] - b[2]) / max(span, 1.0)
            size = abs(a[3] - b[3]) / max(a[3], b[3], 1.0)
            # How far the separation is from a typical eye span, relative to the creature.
            span_dev = abs(span - ideal_span) / max(ideal_span, 1.0)
            score = asym * 3.0 + level * 3.0 + size * 1.5 + span_dev * 2.0
            # Reward a strong sclera ring on both blobs, so a genuine eye pair beats a merely
            # symmetric one.
            ring = (contrast.get(id(a), 0.0) + contrast.get(id(b), 0.0)) / 2.0
            score -= min(ring, 90.0) / 90.0 * 2.5
            if score < best_score:
                best_score = score
                best = (a, b)
    return best, best_score


def find_pupils(img: Image.Image) -> tuple[tuple[float, float], tuple[float, float], float]:
    """Locate the two pupils. Returns (left, right, pupil_radius_px).

    Searches inside the creature's own bounding box, requires a plausible pupil size, and scores
    candidate PAIRS on symmetry. Falls back to the painted white catchlight for eyes so dark they
    merge with their surroundings.
    """
    gray = np.asarray(img.convert("L"), dtype=np.float32)
    bx, by, bw, bh = creature_bbox(img)

    # Eyes sit in the upper part of the animal. Generous enough for an owl (very high) and a
    # capybara (low, wide), but anchored to the creature instead of the canvas.
    y0 = by + int(bh * 0.04)
    y1 = by + int(bh * 0.62)
    x0 = bx + int(bw * 0.04)
    x1 = bx + int(bw * 0.96)
    centre_x = bx + bw / 2.0

    # A pupil is a small but not tiny fraction of the animal's width. This band is what rules
    # out both speck pairs and large dark markings.
    min_r = max(4.0, bw * 0.008)
    max_r = bw * 0.105
    # Eyes sit well inside the silhouette. An upper bound is essential: without it a mirrored
    # pair of ear tips or front paws satisfies every symmetry term and wins outright.
    min_span = bw * 0.10
    max_span = bw * 0.52
    ideal_span = bw * 0.27

    percentiles = (0.4, 0.8, 1.5, 2.5, 4.0, 6.0, 9.0, 13.0)
    dark = _blob_candidates(gray, x0, y0, x1, y1, percentiles, want_dark=True)
    pair, score = _best_symmetric_pair(
            dark, centre_x, min_r, max_r, min_span, max_span, ideal_span, gray)

    if pair is None or score > 1.2:
        bright = _blob_candidates(gray, x0, y0, x1, y1, (0.15, 0.4, 0.9, 1.8, 3.0), want_dark=False)
        # Catchlights are far smaller than pupils, so they get their own size band and are then
        # grown to an estimated pupil radius.
        bpair, bscore = _best_symmetric_pair(
            bright, centre_x, max(2.0, bw * 0.004), bw * 0.030, min_span, max_span, ideal_span)
        if bpair is not None and (pair is None or bscore < score * 0.85):
            grown = bw * 0.030
            pair = (
                (bpair[0][0], bpair[0][1], bpair[0][2], grown),
                (bpair[1][0], bpair[1][1], bpair[1][2], grown),
            )
            score = bscore

    if pair is None:
        raise SystemExit("could not locate two pupils — set them by hand")

    left, right = pair
    radius = (left[3] + right[3]) / 2.0
    return (left[1], left[2]), (right[1], right[2]), radius


def build_masks(base_path: Path, out_dir: Path, debug: bool = False,
                override: dict | None = None) -> dict[str, Path]:
    img = Image.open(base_path).convert("RGB")
    w, h = img.size
    if override:
        # Hand-set pupils for a species the detector cannot see (see PUPIL_OVERRIDES).
        left = (override["left"][0] * w, override["left"][1] * h)
        right = (override["right"][0] * w, override["right"][1] * h)
        pupil_r = override["radius"] * w
    else:
        left, right, pupil_r = find_pupils(img)

    span = right[0] - left[0]           # inter-pupil distance: the unit of measure
    # Eye mask radius comes from the *measured* pupil blob, not a fraction of the span.
    # The sclera is roughly 2x the pupil, plus headroom for the lid and a feather margin.
    eye_r = max(pupil_r * 2.4, span * 0.16)
    eye_y = (left[1] + right[1]) / 2.0
    cx = (left[0] + right[0]) / 2.0

    shapes: dict[str, list[tuple[float, float, float, float]]] = {
        # Both eyes in one mask: doubled pupils / slit pupils must change together or the
        # asymmetry reads as a rendering bug rather than an anomaly.
        "eyes": [
            (left[0] - eye_r, eye_y - eye_r, left[0] + eye_r, eye_y + eye_r),
            (right[0] - eye_r, eye_y - eye_r, right[0] + eye_r, eye_y + eye_r),
        ],
        # Mouth sits below the eye line on these kawaii proportions; wide but shallow so
        # the mask covers the smile line without eating the chin or the body seam.
        "mouth": [
            (cx - span * 0.52, eye_y + span * 0.16, cx + span * 0.52, eye_y + span * 0.62),
        ],
        # Forehead: the gap above and between the eyes, where a third eye can appear.
        "forehead": [
            (cx - span * 0.26, eye_y - span * 0.62, cx + span * 0.26, eye_y - span * 0.16),
        ],
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    written: dict[str, Path] = {}
    for name, boxes in shapes.items():
        mask = Image.new("L", (w, h), 0)
        draw = ImageDraw.Draw(mask)
        for box in boxes:
            draw.ellipse(box, fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(FEATHER_PX))
        path = out_dir / f"{name}.png"
        mask.save(path)
        written[name] = path

    if debug:
        overlay = img.copy()
        d = ImageDraw.Draw(overlay, "RGBA")
        colors = {"eyes": (255, 60, 60, 90), "mouth": (60, 255, 120, 90), "forehead": (90, 140, 255, 90)}
        for name, boxes in shapes.items():
            for box in boxes:
                d.ellipse(box, fill=colors[name])
        for pt in (left, right):
            d.ellipse((pt[0] - 5, pt[1] - 5, pt[0] + 5, pt[1] + 5), fill=(255, 255, 0, 255))
        dbg = out_dir / "_debug_overlay.png"
        overlay.save(dbg)
        written["_debug"] = dbg

    print(f"pupils: L={left[0]:.0f},{left[1]:.0f}  R={right[0]:.0f},{right[1]:.0f}  span={span:.0f}  pupil_r={pupil_r:.0f}  eye_r={eye_r:.0f}")
    for name, path in written.items():
        print(f"  {name}: {path}")
    return written


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    build_masks(Path(sys.argv[1]), Path(sys.argv[2]), "--debug" in sys.argv)
