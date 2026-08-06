"""Produce every asset for the picked roster, and write the game manifest.

Resumable: each stage skips work whose output already exists, so it can be re-run after a crash
or after adding a species without redoing settled renders.

    python produce.py masks      # eye/mouth/forehead masks from each picked base
    python produce.py frames     # blank-eyes body + blink + mouth-open, per creature
    python produce.py xrays      # radiograph derived from each base
    python produce.py visual     # visual anomaly variants
    python produce.py skeleton   # skeleton anomaly variants on the plates
    python produce.py slice      # cut body + pupil layers into the game assets folder
    python produce.py manifest   # write game/data/roster.json
    python produce.py all        # everything above, in order

Stage order matters: masks before frames/visual, xrays before skeleton, everything before slice
and manifest.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).parent))
import comfy
import roster_spec as spec
from make_masks import build_masks
from slice_creature import slice_creature

ROOT = Path(__file__).resolve().parents[1]          # art-pipeline/
RAW = ROOT / "raw"
MASKS = ROOT / "masks"
WORK = ROOT / "export" / "work"
PICKS = ROOT / "picks.json"

GAME = ROOT.parent / "game"
ASSETS = GAME / "assets" / "creatures"
XRAY_ASSETS = GAME / "assets" / "xray"
MANIFEST = GAME / "data" / "roster.json"

STYLE_TAIL = ", soft watercolor storybook illustration, muted desaturated palette, clean crisp painted edges"


def picks() -> dict:
    if not PICKS.exists():
        raise SystemExit("no picks.json — run make_contactsheet.py autopick first")
    return json.loads(PICKS.read_text(encoding="utf-8"))


def species_list(only: str | None) -> list[dict]:
    chosen = picks()
    out = [sp for sp in spec.SPECIES if sp["id"] in chosen]
    if only:
        wanted = {x.strip() for x in only.split(",")}
        out = [sp for sp in out if sp["id"] in wanted]
    return out


def base_path(sid: str) -> Path:
    return Path(picks()[sid])


def collect(subfolder: str, dest: Path, rename: dict | None = None) -> int:
    """Copy renders out of ComfyUI's output tree, optionally renaming by prefix."""
    src = comfy.OUTPUT_DIR / subfolder
    if not src.exists():
        return 0
    dest.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(src.glob("*.png")):
        name = f.name
        if rename:
            # ComfyUI appends _00001_ to the prefix; map back to a stable name.
            stem = f.stem.rsplit("_", 2)[0]
            if stem in rename:
                name = rename[stem]
        target = dest / name
        if not target.exists():
            shutil.copy2(f, target)
            n += 1
    return n


# --- stages ---------------------------------------------------------------------------

def stage_masks(args) -> None:
    made = 0
    for sp in species_list(args.only):
        out = MASKS / sp["id"]
        if (out / "eyes.png").exists() and not args.force:
            continue
        try:
            build_masks(base_path(sp["id"]), out, debug=True,
                        override=spec.PUPIL_OVERRIDES.get(sp["id"]))
            made += 1
        except SystemExit as e:
            print(f"  !! {sp['id']}: {e}")
    print(f"masks: {made} generated")


def _mask_name(sid: str, kind: str) -> str:
    return f"pw_{sid}_{kind}.png"


def stage_frames(args) -> None:
    """Blank-eyes body, eyes-closed blink frame, mouth-open frame.

    Blank eyes is not cosmetic: the pupils become their own layers, so if the body kept its
    painted pupils they would show through whenever the tracking pupils moved.
    """
    todo = []
    for sp in species_list(args.only):
        sid = sp["id"]
        eyes = MASKS / sid / "eyes.png"
        mouth = MASKS / sid / "mouth.png"
        if not eyes.exists():
            print(f"  skip {sid}: no masks")
            continue
        img = comfy.upload_image(base_path(sid), f"pw_{sid}_base.png")
        m_eyes = comfy.upload_image(eyes, _mask_name(sid, "eyes"))
        m_mouth = comfy.upload_image(mouth, _mask_name(sid, "mouth")) if mouth.exists() else None

        jobs = [
            ("blank", m_eyes, spec.BLANK_EYES_CLAUSE, 0.92),
            ("blink", m_eyes, spec.BLINK_CLAUSE, 0.90),
        ]
        if m_mouth:
            jobs.append(("mouth", m_mouth, spec.MOUTH_CLAUSE, 0.80))

        for kind, mask_name, clause, denoise in jobs:
            prefix = f"pawward/prod/frames/{sid}__{kind}"
            comfy.enqueue(comfy.inpaint(img, mask_name, clause + STYLE_TAIL, prefix,
                                        seed=abs(hash(sid + kind)) % 1_000_000,
                                        denoise=denoise))
            todo.append(f"{sid}/{kind}")
    print(f"frames: {len(todo)} queued")
    comfy.wait_for_queue()
    print(f"collected {collect('pawward/prod/frames', RAW / 'frames')} files")


def stage_xrays(args) -> None:
    n = 0
    for sp in species_list(args.only):
        sid = sp["id"]
        img = comfy.upload_image(base_path(sid), f"pw_{sid}_base.png")
        comfy.enqueue(comfy.img2img(
            img, spec.xray_prompt(sp), f"pawward/prod/xray/{sid}__plate",
            seed=abs(hash("xray" + sid)) % 1_000_000, denoise=0.78, style=False))
        n += 1
    print(f"xrays: {n} queued")
    comfy.wait_for_queue()
    print(f"collected {collect('pawward/prod/xray', RAW / 'xray')} files")


def stage_visual(args) -> None:
    """Visual anomalies. Track A edits full frame; track B needs a native-resolution crop."""
    queued = 0
    for sp in species_list(args.only):
        sid = sp["id"]
        base = base_path(sid)
        img = comfy.upload_image(base, f"pw_{sid}_base.png")
        for an in spec.VISUAL:
            mask = MASKS / sid / f"{an['mask']}.png"
            if not mask.exists():
                continue
            prefix = f"pawward/prod/visual/{sid}__{an['id']}"
            if an["track"] == "A":
                m = comfy.upload_image(mask, _mask_name(sid, an["mask"]))
                comfy.enqueue(comfy.inpaint(
                    img, m, an["clause"] + STYLE_TAIL, prefix,
                    seed=abs(hash(sid + an["id"])) % 1_000_000, denoise=an["denoise"]))
            else:
                # Track B: crop around the mask, upscale, inpaint, and composite back later.
                crop_dir = WORK / sid / an["id"]
                crop_dir.mkdir(parents=True, exist_ok=True)
                _cut(base, mask, crop_dir)
                ci = comfy.upload_image(crop_dir / "crop.png", f"pw_{sid}_{an['id']}_crop.png")
                cm = comfy.upload_image(crop_dir / "crop_mask.png",
                                        f"pw_{sid}_{an['id']}_cropmask.png")
                # Verbatim when authored; assembling is what broke this before.
                text = an.get("full_prompt") or (
                    an.get("closeup", "").format(look=sp["look"]) + ", " + an["clause"] + STYLE_TAIL)
                comfy.enqueue(comfy.inpaint(
                    ci, cm, text.strip(", "),
                    prefix + "_cropped",
                    seed=abs(hash(sid + an["id"])) % 1_000_000, denoise=an["denoise"]))
            queued += 1
    print(f"visual: {queued} queued")
    comfy.wait_for_queue()
    print(f"collected {collect('pawward/prod/visual', RAW / 'visual')} files")
    _composite_track_b(args)


def _cut(base_path_: Path, mask_path: Path, out_dir: Path, fill: float = 2.3) -> None:
    """Crop a working window around the mask, sized RELATIVE TO THE MASK.

    Sizing the window in absolute pixels is a trap. The axolotl proof-of-concept used a 384px box
    on a 1024 base, which put the forehead mask at ~42% of the working canvas and produced a clean
    third eye. Scaling that box by resolution for the 1536 roster dropped the mask to ~27% of the
    canvas, and every third_eye came back with an unchanged forehead — the same "a small mask is
    too little of the latent to build a new feature in" wall as before, reached from a different
    direction.

    `fill` is how many mask-widths across the window should be, so the region of interest occupies
    a consistent fraction of the frame on every species at any base resolution.
    """
    import numpy as np
    base = Image.open(base_path_).convert("RGB")
    mask = Image.open(mask_path).convert("L")
    m = np.asarray(mask)
    ys, xs = np.nonzero(m > 8)
    if len(xs) == 0:
        raise SystemExit(f"empty mask: {mask_path}")
    cx, cy = (xs.min() + xs.max()) // 2, (ys.min() + ys.max()) // 2
    mask_side = max(int(xs.max() - xs.min()), int(ys.max() - ys.min())) + 1

    box_size = int(mask_side * fill)
    box_size = max(96, min(box_size, base.width, base.height))
    half = box_size // 2
    x0 = max(0, min(int(cx) - half, base.width - box_size))
    y0 = max(0, min(int(cy) - half, base.height - box_size))
    box = (x0, y0, x0 + box_size, y0 + box_size)

    base.crop(box).resize((1024, 1024), Image.LANCZOS).save(out_dir / "crop.png")
    mask.crop(box).resize((1024, 1024), Image.LANCZOS).save(out_dir / "crop_mask.png")
    (out_dir / "box.txt").write_text(",".join(map(str, box)), encoding="utf-8")


def _composite_track_b(args) -> None:
    """Paste track-B crops back onto their bases through the full-resolution mask."""
    n = 0
    for sp in species_list(args.only):
        sid = sp["id"]
        for an in spec.VISUAL:
            if an["track"] != "B":
                continue
            crop_dir = WORK / sid / an["id"]
            box_file = crop_dir / "box.txt"
            gen = next((RAW / "visual").glob(f"{sid}__{an['id']}_cropped*.png"), None)
            if gen is None or not box_file.exists():
                continue
            base = Image.open(base_path(sid)).convert("RGB")
            mask = Image.open(MASKS / sid / f"{an['mask']}.png").convert("L")
            box = tuple(int(v) for v in box_file.read_text(encoding="utf-8").split(","))
            side = box[2] - box[0]
            canvas = base.copy()
            canvas.paste(Image.open(gen).convert("RGB").resize((side, side), Image.LANCZOS),
                         (box[0], box[1]))
            out = Image.composite(canvas, base, mask)
            out.save(RAW / "visual" / f"{sid}__{an['id']}.png")
            n += 1
    print(f"track-B composited: {n}")


def stage_skeleton(args) -> None:
    """Skeleton anomalies, inpainted on each species' plate.

    Masks are proportional rectangles rather than detected features: a radiograph has no eyes to
    key off, and the regions of interest (abdomen, skull, ribcage, spine, a limb) sit at stable
    fractions of the plate for a front-facing animal.
    """
    queued = 0
    for sp in species_list(args.only):
        sid = sp["id"]
        plate = next((RAW / "xray").glob(f"{sid}__plate*.png"), None)
        if plate is None:
            print(f"  skip {sid}: no plate")
            continue
        pi = comfy.upload_image(plate, f"pw_{sid}_plate.png")
        with Image.open(plate) as im:
            w, h = im.size
        for an in spec.SKELETON:
            mdir = MASKS / sid
            mdir.mkdir(parents=True, exist_ok=True)
            mpath = mdir / f"bone_{an['id']}.png"
            if not mpath.exists():
                rx, ry, rw, rh = an["region"]
                m = Image.new("L", (w, h), 0)
                ImageDraw.Draw(m).ellipse(
                    [rx * w, ry * h, (rx + rw) * w, (ry + rh) * h], fill=255)
                m.filter(ImageFilter.GaussianBlur(14)).save(mpath)
            mi = comfy.upload_image(mpath, f"pw_{sid}_bone_{an['id']}.png")
            comfy.enqueue(comfy.inpaint(
                pi, mi,
                f"veterinary radiograph x-ray plate, {an['clause']}, glowing pale white bone on a "
                f"deep blue black background, clinical x-ray film, no text",
                f"pawward/prod/bones/{sid}__{an['id']}",
                seed=abs(hash(sid + an["id"] + "bone")) % 1_000_000,
                denoise=an["denoise"], style=False))
            queued += 1
    print(f"skeleton: {queued} queued")
    comfy.wait_for_queue()
    print(f"collected {collect('pawward/prod/bones', RAW / 'bones')} files")


def stage_slice(args) -> None:
    """Cut body + pupil layers and copy every final asset into the game."""
    done = 0
    for sp in species_list(args.only):
        sid = sp["id"]
        out = ASSETS / sid
        blank = next((RAW / "frames").glob(f"{sid}__blank*.png"), None)
        try:
            slice_creature(sid, base_path(sid), blank, out)
        except SystemExit as e:
            print(f"  !! {sid}: {e}")
            continue

        # Frames and anomaly art are used whole, so they are copied rather than sliced.
        for kind, name in (("blink", "frame_blink.png"), ("mouth", "frame_mouthopen.png")):  # masters are PNG
            src = next((RAW / "frames").glob(f"{sid}__{kind}*.png"), None)
            if src:
                _copy_cutout(src, out / name, base_path(sid))
        for an in spec.VISUAL:
            src = (RAW / "visual" / f"{sid}__{an['id']}.png")
            if not src.exists():
                src = next((RAW / "visual").glob(f"{sid}__{an['id']}_0*.png"), None)
            if src and src.exists():
                _copy_cutout(src, out / f"anom_{an['id']}.png", base_path(sid))

        XRAY_ASSETS.mkdir(parents=True, exist_ok=True)
        plate = next((RAW / "xray").glob(f"{sid}__plate*.png"), None)
        if plate:
            shutil.copy2(plate, XRAY_ASSETS / f"{sid}.png")
        for an in spec.SKELETON:
            src = next((RAW / "bones").glob(f"{sid}__{an['id']}*.png"), None)
            if src:
                shutil.copy2(src, XRAY_ASSETS / f"{sid}_{an['id']}.png")
        done += 1
    print(f"slice: {done} creatures written to {ASSETS}")


def _copy_cutout(src: Path, dest: Path, reference: Path) -> None:
    """Copy a full-frame render with the same background cutout the body layer got."""
    from slice_creature import _alpha_from_backdrop
    im = Image.open(src).convert("RGB")
    ref = Image.open(reference).convert("RGB")
    if im.size != ref.size:
        im = im.resize(ref.size, Image.LANCZOS)
    out = im.convert("RGBA")
    out.putalpha(_alpha_from_backdrop(im))
    dest.parent.mkdir(parents=True, exist_ok=True)
    out.save(dest)


def _short_marks(sp: dict, limit: int = 40) -> str:
    """The species' distinguishing features, short enough for one chart line."""
    text = sp["look"].split(" with ", 1)[-1] if " with " in sp["look"] else sp["look"]
    if len(text) <= limit:
        return text
    # Prefer cutting at a clause boundary. A blunt character cut left dangling conjunctions on the
    # chart ("a long body, dark eye mask and small"), which reads as a truncation bug.
    head = text[:limit]
    if "," in head:
        return head.rsplit(",", 1)[0]
    # " and " is the other natural clause boundary; cutting mid-phrase left "...and a wide".
    if " and " in head:
        return head.rsplit(" and ", 1)[0]
    words = head.split()
    while words and words[-1] in ("and", "with", "a", "an", "the", "or"):
        words.pop()
    return " ".join(words)


## Extensions the pipeline may have produced, best first. Everything that looks up an asset goes
## through here rather than assuming a suffix — assuming ".png" is exactly what broke the manifest
## and the clinic backdrop when the roster was converted to WebP.
IMAGE_EXTS = (".webp", ".png")


def _find(directory: Path, stem: str) -> Path | None:
    for ext in IMAGE_EXTS:
        candidate = directory / f"{stem}{ext}"
        if candidate.exists():
            return candidate
    return None


def _mask_bbox(mask_path: Path) -> list[int] | None:
    """Bounding box of a mask, as [x, y, w, h] in canvas pixels."""
    if not mask_path.exists():
        return None
    import numpy as np
    m = np.asarray(Image.open(mask_path).convert("L"))
    ys, xs = np.nonzero(m > 8)
    if len(xs) == 0:
        return None
    pad = 12
    x0 = max(0, int(xs.min()) - pad)
    y0 = max(0, int(ys.min()) - pad)
    x1 = min(m.shape[1], int(xs.max()) + pad)
    y1 = min(m.shape[0], int(ys.max()) + pad)
    return [x0, y0, x1 - x0, y1 - y0]


def stage_manifest(args) -> None:
    """Write game/data/roster.json from whatever art actually exists on disk.

    Built from the filesystem rather than from intent, so the manifest can never promise a
    texture that was not produced — Roster would fall back to placeholder art for that creature
    and the mixed look would be obvious.
    """
    creatures = []
    for sp in species_list(args.only):
        sid = sp["id"]
        adir = ASSETS / sid
        slice_meta_path = adir / "slice.json"
        if not slice_meta_path.exists():
            print(f"  skip {sid}: not sliced")
            continue
        meta = json.loads(slice_meta_path.read_text(encoding="utf-8"))

        def res(stem: str) -> str | None:
            """Resolve an asset by STEM, whatever image extension it happens to have."""
            found = _find(adir, stem)
            return f"res://assets/creatures/{sid}/{found.name}" if found else None

        layers = {}
        for key in ("body", "pupil_l", "pupil_r"):
            path = res(key)
            if path:
                layers[key] = path
        frames = {}
        for key, stem in (("blink", "frame_blink"), ("mouth_open", "frame_mouthopen")):
            path = res(stem)
            if path:
                frames[key] = path

        xr = _find(XRAY_ASSETS, sid)
        anomalies = []

        for an in spec.VISUAL:
            p = res(f"anom_{an['id']}")
            if p:
                entry = {"id": an["id"], "tier": an["tier"], "kind": "layer_swap",
                         "overrides": {"body": p}}
                # The mask that produced the variant is exactly the region that changed, so it is
                # the right thing for the hint to highlight. Without this the rewarded
                # second-opinion hint silently highlights nothing.
                rect = _mask_bbox(MASKS / sid / f"{an['mask']}.png")
                if rect:
                    entry["hint_rect"] = rect
                anomalies.append(entry)
        if xr is not None:
            for an in spec.SKELETON:
                bp = _find(XRAY_ASSETS, f"{sid}_{an['id']}")
                if bp is not None:
                    anomalies.append({"id": an["id"], "tier": an["tier"], "kind": "skeleton",
                                      "xray": f"res://assets/xray/{bp.name}"})
        for an in spec.SOUND:
            anomalies.append({"id": an["id"], "tier": an["tier"], "kind": "sound",
                              "params": {"cue": "heart_" + an["id"]}})
        for an in spec.BEHAVIOUR:
            anomalies.append({"id": an["id"], "tier": an["tier"], "kind": "behavior",
                              "params": an["params"]})
        for an in spec.DATA:
            anomalies.append({"id": an["id"], "tier": an["tier"], "kind": "data",
                              "params": an["params"]})

        label = sid.replace("goatkid", "goat kid").replace("fawn", "deer fawn").title()
        creatures.append({
            "id": sid,
            "species": sid,
            "pack": "core",
            "name_pool": ["Mochi", "Pip", "Bubbles", "Sable", "Wren", "Olive", "Juno", "Moss"],
            "layers": layers,
            "frames": frames,
            "xray": f"res://assets/xray/{xr.name}" if xr is not None else "",
            "rig": {
                "pupils": meta["pupils"],
                "pupil_radius": meta["pupil_radius"],
                "pupil_travel": meta["pupil_travel"],
            },
            "anomalies": anomalies,
            "chart": {
                "species_label": label,
                # Just the distinguishing features, trimmed: this is a chart line, not prose.
                "marks": _short_marks(sp),
                "notes_pool": ["Brought in after dark", "Very quiet on arrival",
                               "Would not settle in the carrier"],
            },
            "handbook": {
                "heart": "A steady, even double thump with calm breathing underneath.",
                "features": [
                    "Exactly two eyes, both the same size",
                    "Round pupils, one per eye",
                    "A closed, even mouth with no extra teeth",
                    "Breathes slowly and evenly",
                    "Blinks every few seconds and follows movement",
                    sp["bones"].capitalize(),
                ],
            },
        })

    out = {
        "schema_version": 2,
        "_comment": [
            "GENERATED by art-pipeline/tools/produce.py manifest - do not hand-edit.",
            "Built from the art that actually exists on disk, so it can never promise a texture",
            "that was not produced.",
            "",
            "Layers are body + pupil_l + pupil_r. Blink and mouth are full-frame body swaps.",
            "Anomaly kinds: layer_swap (visual) / skeleton (x-ray) / sound / behavior / data.",
        ],
        "creatures": creatures,
    }
    MANIFEST.write_text(json.dumps(out, indent=2), encoding="utf-8")
    tally: dict[str, int] = {}
    for c in creatures:
        for a in c["anomalies"]:
            tally[a["kind"]] = tally.get(a["kind"], 0) + 1
    print(f"manifest: {len(creatures)} creatures -> {MANIFEST}")
    print("  anomalies by kind: " + ", ".join(f"{k}={v}" for k, v in sorted(tally.items())))


def stage_track_b_redo(args) -> None:
    """Fold in re-run track-B crops from prod/visual2 and composite them over their bases.

    Kept separate from `visual` so a re-run cannot overwrite the originals until its output has
    been looked at — the first pass produced 20 unchanged foreheads and silently replacing files
    would have hidden that.
    """
    # collect() never overwrites — correct when resuming an interrupted batch, wrong here: the
    # whole point of a re-run is to replace output that was reviewed and rejected.
    src = comfy.OUTPUT_DIR / "pawward/prod/visual4"
    n = 0
    if src.exists():
        for f in sorted(src.glob("*.png")):
            shutil.copy2(f, RAW / "visual" / f.name)
            n += 1
    print(f"collected {n} re-run files (overwriting)")
    _composite_track_b(args)


STAGES = {
    "masks": stage_masks, "frames": stage_frames, "xrays": stage_xrays,
    "visual": stage_visual, "skeleton": stage_skeleton, "trackb": stage_track_b_redo,
    "slice": stage_slice, "manifest": stage_manifest,
}
ORDER = ["masks", "frames", "xrays", "visual", "skeleton", "slice", "manifest"]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=list(STAGES) + ["all"])
    ap.add_argument("--only")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    needs_gpu = args.stage in ("frames", "xrays", "visual", "skeleton", "all")
    if needs_gpu and not comfy.alive():
        raise SystemExit("ComfyUI is not responding on " + comfy.HOST)

    for name in (ORDER if args.stage == "all" else [args.stage]):
        print(f"\n=== {name} ===", flush=True)
        STAGES[name](args)


if __name__ == "__main__":
    main()
