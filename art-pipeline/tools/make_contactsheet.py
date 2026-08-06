"""Contact sheets for reviewing generated candidates, and the pick recorder.

Reviewing 60 candidate renders one file at a time is not viable, and neither is judging a 1536px
render scaled to a thumbnail. So: one sheet per species showing its seeds side by side at a size
where the eyes and mouth are actually legible, since those are the regions every anomaly edits.

    python make_contactsheet.py base                     # one sheet per species
    python make_contactsheet.py base --grid              # single overview sheet, all species
    python make_contactsheet.py pick axolotl 2           # record seed #2 as the axolotl's base
    python make_contactsheet.py autopick                 # record seed #1 for anything unpicked
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import roster_spec as spec

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "raw"
QA = ROOT / "qa"
PICKS = ROOT / "picks.json"

BG = (18, 20, 24)
LABEL = (255, 235, 120)


def candidates(stage: str, species_id: str) -> list[Path]:
    return sorted((RAW / stage).glob(f"{species_id}_*.png"))


def load_picks() -> dict:
    return json.loads(PICKS.read_text(encoding="utf-8")) if PICKS.exists() else {}


def save_picks(picks: dict) -> None:
    PICKS.write_text(json.dumps(picks, indent=2, sort_keys=True), encoding="utf-8")


def sheet_for(stage: str, species_id: str, cell: int = 420) -> Path | None:
    files = candidates(stage, species_id)
    if not files:
        return None
    sheet = Image.new("RGB", (cell * len(files) + 8 * (len(files) - 1), cell + 26), BG)
    d = ImageDraw.Draw(sheet)
    for i, f in enumerate(files):
        im = Image.open(f).convert("RGB").resize((cell, cell), Image.LANCZOS)
        sheet.paste(im, (i * (cell + 8), 26))
        d.text((i * (cell + 8) + 6, 6), f"{i + 1}", fill=LABEL)
    d.text((6, 6), f"{species_id}   (pick 1-{len(files)})", fill=LABEL)
    QA.mkdir(parents=True, exist_ok=True)
    out = QA / f"sheet_{stage}_{species_id}.png"
    sheet.save(out)
    return out


def grid(stage: str, cell: int = 190) -> Path:
    """One overview sheet: first candidate of every species, to judge roster coherence."""
    rows: list[tuple[str, list[Path]]] = []
    for sp in spec.SPECIES:
        files = candidates(stage, sp["id"])
        if files:
            rows.append((sp["id"], files))
    cols = 5
    n_rows = (len(rows) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell, n_rows * (cell + 22)), BG)
    d = ImageDraw.Draw(sheet)
    for i, (sid, files) in enumerate(rows):
        x = (i % cols) * cell
        y = (i // cols) * (cell + 22)
        im = Image.open(files[0]).convert("RGB").resize((cell, cell), Image.LANCZOS)
        sheet.paste(im, (x, y + 22))
        d.text((x + 4, y + 4), f"{sid} ({len(files)})", fill=LABEL)
    QA.mkdir(parents=True, exist_ok=True)
    out = QA / f"grid_{stage}.png"
    sheet.save(out)
    print(f"{len(rows)}/{len(spec.SPECIES)} species have renders -> {out}")
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("base")
    s.add_argument("--grid", action="store_true")
    s.add_argument("--only")

    p = sub.add_parser("pick")
    p.add_argument("species")
    p.add_argument("index", type=int)

    sub.add_parser("autopick")

    args = ap.parse_args()

    if args.cmd == "base":
        if args.grid:
            grid("base")
            return
        wanted = {x.strip() for x in args.only.split(",")} if args.only else None
        made = 0
        for sp in spec.SPECIES:
            if wanted and sp["id"] not in wanted:
                continue
            out = sheet_for("base", sp["id"])
            if out:
                made += 1
                print(f"  {out}")
        print(f"{made} sheets")

    elif args.cmd == "pick":
        files = candidates("base", args.species)
        if not files:
            raise SystemExit(f"no candidates for {args.species}")
        if not 1 <= args.index <= len(files):
            raise SystemExit(f"index must be 1-{len(files)}")
        picks = load_picks()
        picks[args.species] = str(files[args.index - 1]).replace("\\", "/")
        save_picks(picks)
        print(f"{args.species} -> {files[args.index - 1].name}")

    elif args.cmd == "autopick":
        # First candidate for anything not yet chosen. Seeds are species-derived so candidate 1
        # is stable, which makes this a legitimate default rather than a coin flip — and any
        # species can be overridden later with `pick` without disturbing the others.
        picks = load_picks()
        added = 0
        for sp in spec.SPECIES:
            if sp["id"] in picks:
                continue
            files = candidates("base", sp["id"])
            if files:
                picks[sp["id"]] = str(files[0]).replace("\\", "/")
                added += 1
        save_picks(picks)
        print(f"autopicked {added}; {len(picks)}/{len(spec.SPECIES)} species now have a base")


if __name__ == "__main__":
    main()
