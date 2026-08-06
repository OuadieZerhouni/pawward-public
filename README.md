# PawWard

A 2D iOS game. You work night shifts at an animal clinic. Cute creature patients arrive at
your intake window; most are fine, some are subtly *wrong*. Compare each patient against its
chart and stamp **ADMIT** or **REJECT**. Three strikes ends the shift.

Creepy-cute, zero gore, 13+. Godot 4.7, portrait, free with ads + a Pro unlock.

Strategy, market evidence and revenue arithmetic: [`../NICHE-PAWWARD-PLAN.md`](../NICHE-PAWWARD-PLAN.md).
Build decisions and why they were made: [`docs/decisions.md`](docs/decisions.md).

## The five anomaly channels

Difficulty escalates by giving the player more ways to **look**, not more patients. Each channel
is a different kind of wrong, so learning to check the eyes does not make you safe.

| Channel | Revealed by | Examples | Art cost |
|---|---|---|---|
| `visual` | looking | third eye, doubled pupils, too many teeth, slit pupils | inpainted variant |
| `skeleton` | X-ray + handbook | swallowed key, second skull, extra ribs, hollow limb | inpainted on the plate |
| `sound` | stethoscope + handbook | two heartbeats, clockwork, hollow silence, a whisper | shared clips, none per species |
| `behaviour` | patience | never blinks, eyes do not follow, does not breathe | none |
| `data` | reading the chart | chart species or name contradicts the patient | none |

Tools unlock per night in `game/data/difficulty.json` (3 handbook, 4 X-ray, 5 stethoscope), and
each unlock night **guarantees** a patient who needs the new tool — taught by necessity, not by a
tutorial box.

**The handbook is load-bearing.** "One rib too many" is unguessable without a reference for the
normal count. Channel selection is therefore hard-gated on the tools the player owns and is never
widened on a miss: an anomaly with no instrument to detect it is an unwinnable patient. Tests in
`game/tests/` enforce exactly this.

## Layout

| Path | What |
|---|---|
| `game/` | the Godot project — open **this** folder in Godot, not the repo root |
| `game/data/` | `roster.json` + `difficulty.json` — the content and balance contracts |
| `art-pipeline/` | asset production; deliberately outside `game/` so raw art never enters Godot's importer |
| `art-pipeline/tools/` | the pipeline scripts (see below) |
| `art-pipeline/masks/` | per-creature masks — committed, cheap, reusable |
| `art-pipeline/raw/` | ComfyUI output and attempts — gitignored, reproducible |
| `docs/` | decision log, store copy |
| `builds/` | export output — gitignored |

## Running it

```sh
GODOT=/c/Users/ouadi/tools/godot/Godot_v4.7.1-stable_win64_console.exe

# import + compile check (catches script errors, no window)
"$GODOT" --headless --path game --import

# run headless for N frames — any script error shows up here
"$GODOT" --headless --path game --quit-after 120

# render a PNG of the current scene (needs a real GL context, so no --headless)
"$GODOT" --path game --resolution 540x960 --quit-after 200 -- --shot /abs/path/out.png
```

`--shot` is a capture hook on the scene script: it renders 30 frames then writes a PNG and
quits. It makes visual changes verifiable without a human at the keyboard, and it is the
harness the App Store screenshots will come from later.

The current main scene is `scenes/AliveTest.tscn`, the Phase 0 harness. It loads real art
from `assets/creatures/axolotl_01/` when present and falls back to procedural placeholders,
so the animation can be judged before any slicing is done. Hold **SPACE** to flip between
base and anomaly, **1/2/3** to pick which anomaly, **G** to toggle grain.

## Art pipeline

One creature = one base render + N anomaly variants + blink/mouth micro-frames, sliced into
full-canvas registered layers.

Every layer PNG is the **full canvas** with transparency, so all layers register with each
other for free and no offset bookkeeping is needed. That is what makes an art anomaly a
per-layer texture swap, which in turn means an anomalous patient animates *identically* to
a healthy one — players have to look at the creature, not at its motion.

### Three layers, and no manual slicing

Of the four idle motions, only the **pupils** need separated geometry — breathing and sway act on
the whole sprite about its feet, and blink/mouth are full-frame texture swaps. So a creature is:

```text
game/assets/creatures/<species>/
  body.png              whole creature, rendered with BLANK eyes
  pupil_l.png           pupil disc, full canvas so it registers for free
  pupil_r.png
  frame_blink.png       eyes closed    (full-frame body swap)
  frame_mouthopen.png   mouth open     (full-frame body swap)
  anom_<id>.png         visual anomaly (full-frame body swap)
  slice.json            measured pupil positions, radius and travel
game/assets/xray/
  <species>.png             the healthy plate (also the handbook reference)
  <species>_<anomaly>.png   skeleton anomalies
```

The blank-eyed body is itself generated, by inpainting the pupils away. That is not cosmetic: if
the body kept its painted pupils they would show through whenever the tracking pupils moved.

Everything above is produced automatically — the plan's 20 × 20 minutes of hand-slicing in Krita
is gone.

### Generating

Krea 2 Turbo, settings frozen: **8 steps, cfg 1.0, `er_sde`, `simple`, 1024x1024**, with
`krea2_softwatercolor` at 0.85. Reusable graph: `art-pipeline/prompts/krea2_base_txt2img.json`.

There are **no negative prompts** — at cfg 1 the negative input is a `ConditioningZeroOut`
of the positive, so guards like "exactly two eyes" must be phrased positively in the prompt.

### Anomaly variants — two tracks

Anomalies are produced by masked img2img with the *same model and LoRA* that painted the
base, then hard-composited back through the mask. Outside-mask pixels come from the original
file, so registration is exact by construction rather than by luck (measured: 0.000–0.001/255).

**Track A — modify a feature that already exists** (wrong eyes, wrong grin, wrong paws).
Full frame, denoise 0.65–0.95, entirely in ComfyUI, ending in `ImageCompositeMasked`.

**Track B — add a feature that isn't there** (third eye, extra limb). Full-frame inpainting
*does not work* for this: the mask is too small a fraction of the latent and the model will
not build a new feature inside it at any denoise. Crop to native resolution first:

```sh
python art-pipeline/tools/composite_patch.py cut  --base B.png --mask M.png --size 384 --out-dir DIR
#   ...inpaint DIR/crop.png in ComfyUI at denoise 1.0 with DIR/crop_mask.png...
python art-pipeline/tools/composite_patch.py paste --base B.png --mask M.png --patch GEN.png \
    --box-file DIR/box.txt --out VARIANT.png
```

### Producing the roster

`produce.py` drives every stage and is resumable, so adding a species never redoes settled work.
Stage order matters: masks before frames/visual, xrays before skeleton, everything before slice.

```sh
cd art-pipeline/tools
python generate_roster.py bases --seeds 3      # candidates for every species
python make_contactsheet.py base --grid        # review; then `pick <species> <n>` or `autopick`
python produce.py all                          # masks -> frames -> xrays -> anomalies -> slice -> manifest
```

`roster_spec.py` is the single source of content truth — species, their skeletons, and every
anomaly in all five channels. The generator reads it to make images and the manifest builder reads
it to write `game/data/roster.json`, so art and data cannot disagree about what exists.

The manifest is built from **what is actually on disk**, never from intent: it can therefore never
promise a texture that was not produced (Roster would silently fall back to placeholder art for
that creature and the mixed look would be obvious).

### Tools

```sh
# derive eye/mouth/forehead masks by locating the pupils; ALWAYS eyeball the overlay after
python art-pipeline/tools/make_masks.py BASE.png art-pipeline/masks/<id> --debug

# the QA gate: registration (outside mask must be identical) + delta (anomaly must land)
python art-pipeline/tools/flip_diff.py --base B.png --mask M.png \
    --variant V1.png --variant V2.png --out-dir art-pipeline/qa --log art-pipeline/qa/qa-log.md

# cut body + pupil layers from a finished render
python art-pipeline/tools/slice_creature.py <species> --base B.png --blank BLANK.png --out-dir DIR
```

Pupil detection finds an eye as **a dark centre inside a lighter ring**, which is what an eye
actually is; thresholds and symmetry alone plateaued at 14/20 (see `docs/decisions.md`). It gets
19 of 20 species. The raccoon's dark facial mask defeats it, so that one has a hand-set entry in
`PUPIL_OVERRIDES` — add an entry there for any future miss rather than loosening the detector,
which regresses the ones that work.

### Driving the game without a human

```sh
GODOT=/c/Users/ouadi/tools/godot/Godot_v4.7.1-stable_win64_console.exe
"$GODOT" --headless --path game --import                      # compile check
"$GODOT" --headless --path game res://tests/TestRunner.tscn   # unit tests
"$GODOT" --headless --path game --quit-after 4000 -- --autoplay 5   # play a full shift
# screenshots need a GL context, so no --headless:
/c/Users/ouadi/tools/godot/Godot_v4.7.1-stable_win64.exe --path game --resolution 540x960 \
  --quit-after 400 -- --play 5 --force-channel skeleton --auto-tool xray --shot C:/out.png
```

`--autoplay` judges every patient correctly and asserts a clean sweep, which catches "the loop is
subtly unwinnable" — something unit tests on the shift builder cannot see. Tests must run as a
**scene**: autoloads do not exist under `--script`.

`flip_diff.py` exits non-zero if any pair fails, so it can gate a batch. Passing it is
necessary but **not sufficient** — a human still has to confirm the anomaly is findable in
about five seconds when warned and missable at a glance when not.

## Scope laws

Cut anything that threatens these. They exist because the schedule is the strategy.

- No dialogue system, no branching meta-story, no multiplayer, no procedural creatures.
- Single front-facing pose for every creature. This removes diffusion's cross-pose weakness
  from the entire project and is why roster consistency is free.
- **Ads never mid-shift.** Interstitials live on the shift-end screen only. Mid-task ads are
  the most common complaint across every incumbent studied in the niche research.
- Original brand. No reference anywhere — including code comments and the bundle id — to the
  Roblox mode that created the demand. Genre-riding is the strategy; name-riding is not.
