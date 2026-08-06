"""Mass-produce roster art. Each stage is separately runnable and resumable.

    python generate_roster.py bases   [--seeds 3] [--only axolotl,cat]
    python generate_roster.py xrays               [--only ...]
    python generate_roster.py sounds                              # prints ElevenLabs briefs

Stages are separate on purpose: `bases` needs a human to pick the best seed per species before
anything downstream can run, and everything downstream derives from that pick. Picks are
recorded in picks.json, so a rerun never re-does settled work.

Renders land in ComfyUI's output dir and are copied into art-pipeline/raw/<stage>/.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import comfy
import roster_spec as spec

ROOT = Path(__file__).resolve().parents[1]      # art-pipeline/
RAW = ROOT / "raw"
PICKS = ROOT / "picks.json"


def load_picks() -> dict:
    if PICKS.exists():
        return json.loads(PICKS.read_text(encoding="utf-8"))
    return {}


def save_picks(picks: dict) -> None:
    PICKS.write_text(json.dumps(picks, indent=2, sort_keys=True), encoding="utf-8")


def selected(only: str | None) -> list[dict]:
    if not only:
        return spec.SPECIES
    wanted = {s.strip() for s in only.split(",")}
    return [sp for sp in spec.SPECIES if sp["id"] in wanted]


def collect(subfolder: str, dest: Path) -> int:
    """Copy renders out of ComfyUI's output tree into the pipeline's raw area."""
    src = comfy.OUTPUT_DIR / subfolder
    if not src.exists():
        return 0
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(src.glob("*.png")):
        target = dest / f.name
        if not target.exists():
            shutil.copy2(f, target)
            n += 1
    return n


# --- stages ---------------------------------------------------------------------------

def stage_bases(args) -> None:
    species = selected(args.only)
    print(f"bases: {len(species)} species x {args.seeds} seeds at {comfy.RES}px")
    for i, sp in enumerate(species):
        # Seed derived from the species id so a rerun reproduces the same candidates and the
        # human's pick stays meaningful.
        seed = abs(hash(sp["id"])) % 1_000_000
        graph = comfy.txt2img(
            spec.base_prompt(sp),
            prefix=f"pawward/roster/base/{sp['id']}",
            seed=seed,
            batch=args.seeds,
        )
        comfy.enqueue(graph)
        print(f"  [{i + 1}/{len(species)}] {sp['id']} queued (seed {seed})", flush=True)
    comfy.wait_for_queue()
    n = collect("pawward/roster/base", RAW / "base")
    print(f"collected {n} new files -> {RAW / 'base'}")
    print("\nNEXT: review the contact sheet, then record picks:")
    print("  python make_contactsheet.py base")


def stage_xrays(args) -> None:
    """X-rays are derived from each species' CHOSEN base via img2img.

    Deriving rather than generating from scratch is what keeps the plate recognisably the same
    animal: at denoise 0.78 the silhouette and pose survive while the interior becomes bone.
    """
    picks = load_picks()
    species = [sp for sp in selected(args.only) if sp["id"] in picks]
    missing = [sp["id"] for sp in selected(args.only) if sp["id"] not in picks]
    if missing:
        print(f"skipping (no pick recorded): {', '.join(missing)}")
    if not species:
        raise SystemExit("no picks recorded yet — run bases and record picks first")

    print(f"xrays: {len(species)} species")
    for sp in species:
        base = Path(picks[sp["id"]])
        if not base.exists():
            print(f"  !! {sp['id']}: picked file missing: {base}")
            continue
        uploaded = comfy.upload_image(base, f"pw_base_{sp['id']}.png")
        graph = comfy.img2img(
            uploaded,
            spec.xray_prompt(sp),
            prefix=f"pawward/roster/xray/{sp['id']}",
            seed=abs(hash("xray" + sp["id"])) % 1_000_000,
            denoise=0.78,
            style=False,          # radiographs are not watercolour; the style LoRA fights it
        )
        comfy.enqueue(graph)
        print(f"  {sp['id']} queued", flush=True)
    comfy.wait_for_queue()
    n = collect("pawward/roster/xray", RAW / "xray")
    print(f"collected {n} new files -> {RAW / 'xray'}")


def stage_sounds(_args) -> None:
    """Sound cues are shared across the roster, so this just prints the briefs to generate.

    ElevenLabs is reached through an MCP tool rather than an HTTP key here, so this stage is a
    worklist rather than an automated call.
    """
    print("normal:")
    print(f"  {SOUND_TARGET / 'heart_normal.mp3'}\n    {spec.SOUND_NORMAL['prompt']}\n")
    for s in spec.SOUND:
        print(f"{s['id']} (tier {s['tier']}):")
        print(f"  {SOUND_TARGET / ('heart_' + s['id'] + '.mp3')}\n    {s['prompt']}\n")


SOUND_TARGET = Path("game/assets/audio/sfx")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="stage", required=True)

    b = sub.add_parser("bases")
    b.add_argument("--seeds", type=int, default=3)
    b.add_argument("--only")
    b.set_defaults(func=stage_bases)

    x = sub.add_parser("xrays")
    x.add_argument("--only")
    x.set_defaults(func=stage_xrays)

    s = sub.add_parser("sounds")
    s.set_defaults(func=stage_sounds)

    args = ap.parse_args()
    if not comfy.alive():
        raise SystemExit("ComfyUI is not responding on " + comfy.HOST)
    args.func(args)


if __name__ == "__main__":
    main()
