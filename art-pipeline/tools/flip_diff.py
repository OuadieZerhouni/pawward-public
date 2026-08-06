"""The art-pipeline QA gate: does an anomaly variant register with its base, and did the
anomaly actually land?

Two independent failure modes, two independent checks:

  REGISTRATION — every pixel outside the mask must be identical to the base. If it drifts,
  the whole layer-override architecture breaks: a patient would visibly "re-render" when an
  anomaly is applied, and players would spot anomalies by the shimmer instead of by looking.
  Because the ComfyUI graph ends in ImageCompositeMasked over the untouched base, this
  should be *exactly* zero — so a failure here means the graph is wrong, not that the model
  had a bad day.

  DELTA — the region inside the mask must actually differ from the base. A variant that
  passes registration by simply not changing anything is the silent failure this catches.

Exit code is 0 only when every checked pair passes, so this can gate a batch.

Usage:
    python flip_diff.py --base BASE.png --mask MASK.png --variant VAR.png [--variant ...]
                        [--out-dir DIR] [--log qa-log.md]
"""

from __future__ import annotations

import argparse
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image

# Outside-mask tolerance. The composite makes this exact, so the budget is deliberately
# tiny — just enough to absorb PNG round-tripping, not enough to hide a real re-render.
OUTSIDE_MEAN_MAX = 1.0 / 255.0
OUTSIDE_PEAK_MAX = 8.0 / 255.0
# Inside-mask minimum: below this the "anomaly" is invisible and the pair is a no-op.
INSIDE_MEAN_MIN = 2.0 / 255.0
# The feather ring is intentionally blended, so exclude it from the registration check by
# treating anything partially masked as inside.
MASK_INSIDE_THRESHOLD = 2


def _load_rgb(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.float32) / 255.0


def check_pair(base_path: Path, mask_path: Path, variant_path: Path, out_dir: Path | None) -> dict:
    base = _load_rgb(base_path)
    variant = _load_rgb(variant_path)
    mask = np.asarray(Image.open(mask_path).convert("L"))

    if base.shape != variant.shape:
        return {
            "variant": variant_path.name,
            "passed": False,
            "reason": f"size mismatch: base {base.shape[:2]} vs variant {variant.shape[:2]}",
        }
    if mask.shape != base.shape[:2]:
        return {
            "variant": variant_path.name,
            "passed": False,
            "reason": f"mask size {mask.shape} does not match base {base.shape[:2]}",
        }

    inside = mask >= MASK_INSIDE_THRESHOLD
    outside = ~inside
    delta = np.abs(variant - base).max(axis=2)   # worst channel per pixel

    outside_mean = float(delta[outside].mean()) if outside.any() else 0.0
    outside_peak = float(delta[outside].max()) if outside.any() else 0.0
    inside_mean = float(delta[inside].mean()) if inside.any() else 0.0
    inside_peak = float(delta[inside].max()) if inside.any() else 0.0

    reasons = []
    if outside_mean > OUTSIDE_MEAN_MAX:
        reasons.append(f"outside-mask drift (mean {outside_mean * 255:.2f}/255)")
    if outside_peak > OUTSIDE_PEAK_MAX:
        reasons.append(f"outside-mask peak (max {outside_peak * 255:.1f}/255)")
    if inside_mean < INSIDE_MEAN_MIN:
        reasons.append(f"anomaly did not land (inside mean {inside_mean * 255:.2f}/255)")

    result = {
        "variant": variant_path.name,
        "passed": not reasons,
        "reason": "; ".join(reasons) if reasons else "ok",
        "outside_mean_255": outside_mean * 255,
        "outside_peak_255": outside_peak * 255,
        "inside_mean_255": inside_mean * 255,
        "inside_peak_255": inside_peak * 255,
        "changed_px_outside": int((delta[outside] > OUTSIDE_PEAK_MAX).sum()) if outside.any() else 0,
    }

    if out_dir is not None:
        out_dir.mkdir(parents=True, exist_ok=True)
        # Heat map of where the image changed, so a registration failure is diagnosable at a
        # glance instead of by squinting at two files.
        heat = np.zeros((*delta.shape, 3), dtype=np.uint8)
        heat[..., 0] = np.clip(delta * 255 * 6, 0, 255).astype(np.uint8)      # red: any change
        heat[..., 1] = (inside.astype(np.uint8) * 40)                          # green: mask area
        Image.fromarray(heat).save(out_dir / f"{variant_path.stem}_diff.png")

        # Base | variant strip at phone scale, for the human 5-second test.
        strip_h = 640
        scale = strip_h / base.shape[0]
        strip_w = int(base.shape[1] * scale)
        pair = Image.new("RGB", (strip_w * 2 + 8, strip_h), (18, 20, 24))
        pair.paste(Image.open(base_path).convert("RGB").resize((strip_w, strip_h), Image.LANCZOS), (0, 0))
        pair.paste(
            Image.open(variant_path).convert("RGB").resize((strip_w, strip_h), Image.LANCZOS),
            (strip_w + 8, 0),
        )
        pair.save(out_dir / f"{variant_path.stem}_pair.png")

    return result


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, type=Path)
    ap.add_argument("--mask", required=True, type=Path)
    ap.add_argument("--variant", required=True, action="append", type=Path)
    ap.add_argument("--out-dir", type=Path, default=None)
    ap.add_argument("--log", type=Path, default=None, help="append a markdown row per pair")
    args = ap.parse_args(argv)

    results = [check_pair(args.base, args.mask, v, args.out_dir) for v in args.variant]

    width = max(len(r["variant"]) for r in results)
    print(f"{'variant'.ljust(width)}  verdict  outside(mean/peak)  inside(mean/peak)")
    for r in results:
        verdict = "PASS" if r["passed"] else "FAIL"
        if "outside_mean_255" in r:
            print(
                f"{r['variant'].ljust(width)}  {verdict:5}  "
                f"{r['outside_mean_255']:6.3f}/{r['outside_peak_255']:6.2f}   "
                f"{r['inside_mean_255']:6.2f}/{r['inside_peak_255']:6.1f}   {r['reason']}"
            )
        else:
            print(f"{r['variant'].ljust(width)}  {verdict:5}  {r['reason']}")

    if args.log is not None:
        args.log.parent.mkdir(parents=True, exist_ok=True)
        new = not args.log.exists()
        with args.log.open("a", encoding="utf-8") as fh:
            if new:
                fh.write("# Art QA log\n\nAutomated flip-test results. A human 5-second test still\n")
                fh.write("has to pass on top of these numbers.\n\n")
                fh.write("| when (UTC) | base | variant | verdict | outside mean/255 | inside mean/255 | note |\n")
                fh.write("|---|---|---|---|---|---|---|\n")
            stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")
            for r in results:
                om = f"{r.get('outside_mean_255', float('nan')):.3f}"
                im = f"{r.get('inside_mean_255', float('nan')):.2f}"
                mark = "PASS" if r["passed"] else "**FAIL**"
                fh.write(f"| {stamp} | {args.base.name} | {r['variant']} | {mark} | {om} | {im} | {r['reason']} |\n")

    failed = [r for r in results if not r["passed"]]
    if failed:
        print(f"\n{len(failed)}/{len(results)} FAILED")
        return 1
    print(f"\nall {len(results)} passed registration + delta checks")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
