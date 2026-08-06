# Decision log

Running record of choices that are expensive to reverse, and the evidence behind them.
Newest last. The strategy rationale lives in `../../NICHE-PAWWARD-PLAN.md`; this file is
about *how it got built*.

---

## 2026-08-06 — Phase 0

### Engine: Godot 4.7.1
Godot 4.7.1-stable was already installed with export templates. A 2D game built from
layered sprites, tweens and full-screen shaders is Godot's strongest suit, and the
"alive and slightly unsettling" feel is the product itself. Flutter 3.44.8 is also
installed and Flame could carry the loop, but its shader/scene tooling is well behind and
the trade would swap a plugin-maturity risk for a game-feel risk. Unity isn't installed
and buys nothing here.

### Renderer: Compatibility (`gl_compatibility`)
Broadest iOS device reach, and every PawWard effect is a `canvas_item` shader that works
there. Revisit only if a shader genuinely needs RenderingDevice features.

### iOS delivery: cloud CI, no Mac
Operator decision. Codemagic free tier (500 macOS min/month) runs Godot headless on a Mac
runner to export, sign and upload; signing automated with an App Store Connect API key.
MacinCloud (~$1/hr) budgeted for the few interactive sessions. **Unproven — must be
validated with a signed empty-shell TestFlight build at the end of week 2, before week 3
depends on it.**

### Age rating: 13+, general audience (NOT Kids category)
Apple removed the 12+ tier in the July 2025 overhaul (now 4+/9+/13+/16+/18+). "Infrequent
mild horror themes" sits comfortably at 13+. The Kids category is actively undesirable:
Guideline 1.3 bars IDFA transmission and limits ads to human-reviewed contextual ads from
kid-certified networks, which is incompatible with ATT + personalized AdMob. Store listing
must not read as child-directed.

### Name: "PawWard" — clear, with one caveat
iTunes exact/prefix search returns **zero collisions** for PawWard (also clear: Nightpaw,
Wrongfur, Oddvet, Pawnight, Furwatch). Caveat worth an operator decision: a *fuzzy* App
Store search for "PawWard" surfaces a wall of **PAW Patrol** titles. That's not a
trademark collision on the exact mark, but it is (a) ASO noise from a dominant kids brand
and (b) mild kid-directed adjacency, which cuts against the 13+ / non-Kids posture above.
Alternatives above are all free if the operator wants distance from it.

### Inpaint model: none needed — this replaced the FLUX.1-Fill plan
The plan called for downloading FLUX.1-Fill (~11GB) as an inpaint model, flagging
"inpaint style continuity" as risk #2: a different architecture cannot carry the
`krea2_softwatercolor` LoRA, so anomaly regions would lose the watercolor grain and the
seam would be visible.

Krea 2 Turbo (12B DiT, native ComfyUI, `CLIPLoader type=krea2` + Qwen3-VL encoder + Qwen
image VAE) has no inpaint variant — and does not need one. The variant pipeline is:

    VAEEncode(base) -> SetLatentNoiseMask(feathered mask) -> KSampler(same model + SAME LoRA)
      -> VAEDecode -> ImageCompositeMasked(destination=base, source=generated, mask)

Two properties fall out of this, both better than the original plan:

1. **Registration passes by construction, not by luck.** The final composite takes
   outside-mask pixels from the original file, so they are byte-identical. Measured:
   outside-mask mean delta **0.001/255** across all three test anomalies (peak 1/255 is
   PNG rounding). The original plan hoped a Fill model would preserve them.
2. **Style continuity is maximal**, because the variant is painted by the exact model and
   LoRA that painted the base. Verified: seams are invisible at 3x zoom, watercolor grain
   continuous across every mask boundary.

Risk #2 in the plan is therefore closed, and an 11GB download plus a VRAM-juggling problem
(risk #8) both disappear. Still needed for Phase 1: an ESRGAN upscaler (no
`upscale_models` present locally).

### Krea 2 settings — frozen
8 steps, cfg 1.0, `er_sde`, `simple`, denoise 1.0 for bases; 1024x1024.
**Negative prompts do not exist here**: at cfg 1 the negative input is a
`ConditioningZeroOut` of the positive, so every guard ("no text", "exactly two eyes") has
to be phrased positively inside the prompt.

### Anomaly production is two-track — the main Phase 0 finding
First pass, all full-frame at denoise 0.65–0.85: `too_many_teeth` excellent, `doubled_pupils`
barely moved, `third_eye` absent. Raising `doubled_pupils` to denoise 0.95 fixed it. Raising
`third_eye` to denoise 1.0 did **not** — the forehead stayed empty.

Diagnosis: at 1024x1024 the forehead mask is ~150x140px. That is too small a fraction of the
latent for the model to construct a *new* feature inside it, regardless of denoise or prompt
explicitness. Modifying something already there is a much weaker ask than inventing something.

Fix, verified: crop 384px around the mask, upscale to 1024 (2.67x effective resolution),
inpaint at denoise 1.0, downscale, composite through the original full-res mask. Inside-mask
delta went 4.2 -> 37.9/255 and produced a clean, style-matched third eye with a correct
catchlight and eyelid line.

    Track A  modify existing feature   full frame, denoise 0.65-0.95   ComfyUI only
    Track B  add new feature           crop -> 1024 -> denoise 1.0     + composite_patch.py

Track B is packaged in `art-pipeline/tools/composite_patch.py`; it reproduces the hand-run
result byte-identically. Compositing in PIL rather than ComfyUI also drops outside-mask drift
from 0.001/255 (PNG round-trip) to exactly 0.000.

## 2026-08-06 (later) — scope expansion: inspection tools

Operator asked for maximum art quality and for new ways to *discover* an anomaly, suggesting a
skeleton scan. Both accepted, and the deadline was explicitly dropped in favour of quality
("forget about the number of weeks"). Roster stays at 20.

### Five anomaly channels, not one
The structural idea worth taking from Papers, Please is not the stamping — it is that difficulty
escalates by handing the player **more ways to look**. So anomalies arrive through five
independent channels: `visual` (look), `skeleton` (X-ray), `sound` (stethoscope), `behaviour`
(patience), `data` (chart). A player who has learned to scan the eyes is still caught by the ones
they cannot see, which is variety that more art alone cannot buy.

Tools unlock per night from `difficulty.json`, and each unlock night guarantees a patient who
needs the new tool — taught by necessity rather than a tutorial box.

### The handbook is load-bearing
"One rib too many" is unguessable without a reference for the normal count. This is exactly the
unwinnable-patient trap the chart-name lie had before the wristband existed, and it would have
recurred for every subtle skeleton and sound anomaly. So the handbook ships as a *requirement* of
those channels, not as a nice-to-have, and channel selection is hard-gated on the night's unlocked
tools and **never widened on a miss**.

The handbook shows the page for the species the CHART claims, not the true species — so a species
lie can be caught through the book as well as by eye.

### 1536 replaces 1024
Measured side by side at 1:1 on the same seed: 1536 gains visible watercolour paper grain,
delicate ink linework, eyelid lines and skin freckles that 1024 renders flat. Free quality, so it
is now the standard.

### X-ray plates are derived from each creature's base
img2img at denoise 0.78 keeps the plate recognisably the same animal rather than a stock skeleton.
Three of twenty (snake, crow, capybara) drifted to near-human anatomy and were re-run at 0.88 with
explicitly exclusionary phrasing ("no limbs and no shoulder girdle") — which has to go in the
*positive* prompt, since there is no negative prompt at cfg 1.

### Slicing is automatic — the manual Krita pass is gone
The plan budgeted 20 minutes per creature to hand-slice eight layers, twenty times. Almost all of
it was unnecessary: of the four idle motions, only the **pupils** need separated geometry.

    breathing   whole sprite, scale.y about its feet     no layers
    sway        whole sprite, small rotation             no layers
    blink       full-frame body texture swap             no layers
    mouth       full-frame body texture swap             no layers
    pupils      must translate independently             <- the only requirement

So a creature is three layers: a body rendered with BLANK eyes (itself produced by inpainting the
pupils away) plus two pupil discs cut at the detected positions. `Patient` was refactored from
eight layers to three. Fewer moving parts, no inter-slice seams, and zero hand work.

Cost: no independent head sway. At 0.011 rad it is indistinguishable from whole-sprite sway, so
this is a good trade.

### Pupil detection: four attempts, and why the last one worked
Worth recording because the first three all failed for the same reason — they described *where a
dark thing might be* rather than *what an eye is*.

| version | approach | result |
|---|---|---|
| v1 | two largest compact dark blobs in a fixed image band | 13/20 — lost to a raccoon's eye mask, a frog's wide-set eyes |
| v2 | + symmetry scoring over candidate pairs | 18/20 but sloppy — symmetric *specks* outscored real eyes, returning 5px "pupils" |
| v3 | + creature-bbox search region, pupil size band | **10/20, worse** — the threshold sweep stopped at the first pair found, so a pupil's dark core was offered and rejected while the fuller blob was never generated |
| v4 | + accumulate all thresholds, eye-separation prior, **sclera-ring contrast** | **19/20** |

The decisive feature is sclera contrast: a pupil is a dark centre inside a **lighter** ring. An ear
tip, a paw shadow or a dark facial marking is not. Symmetry and size are useful filters; only this
one describes the thing being looked for.

The raccoon remains the single failure — its dark facial mask removes the bright surround
entirely. That gets a hand-set entry in `PUPIL_OVERRIDES` rather than a looser detector, which
would regress the nineteen that work.

### Shipping size: WebP at per-role resolution
The roster at 1536 RGBA PNG came to **945MB** of game assets. The plan targets under 200MB of
download and install conversion falls away well before that, so this was a blocker, not a polish
item.

Lossy WebP with alpha at quality 88 plus per-role resolution took it to **98MB (10.4%)**. WebP is
safe here specifically because the art is watercolour — no hard edges or flat colour fields for it
to ruin. Resolution is set by what each asset is actually used for: the body and its anomalies keep
1536 because they carry the 2.6x inspection zoom; X-ray plates are only ever seen at hatch size or
212px in the handbook; blink and mouth frames flash for a tenth of a second. 1536 PNG masters stay
in `art-pipeline/` as the source of truth.

### The assume-the-extension bug, three times
Changing the asset format broke three separate things that had each hardcoded `.png`, and every
failure was silent in a different way:

1. **The clinic backdrop** path was a `const`. The whole room stopped loading and the creature
   floated in black.
2. **The manifest builder** matched art by `.png`, so it dropped all 200 art-based anomalies AND
   every creature's layers. That would have sent the entire roster back to placeholder art with no
   error logged anywhere — the worst kind, because the game still runs and still looks *plausible*.
3. **The `.gitignore`** rule for slicer debug composites named `.png`, so they came back into the
   tracked assets the moment the format changed.

All three now resolve by **stem** across a known extension list. The lesson is narrow and worth
keeping: an asset reference should name what the thing IS, not what container it currently happens
to be in — and a lookup that can fail silently should be a lookup that logs.

### Masks are derived, not hand-painted (fast path)

`art-pipeline/tools/make_masks.py` finds the two pupils and derives eye/mouth/forehead
masks from the inter-pupil span. Since every creature is front-facing and symmetrical by
design law, this is reproducible across the roster and keeps a tier-2 mask meaning the
same thing on every species — ~5 min/creature of operator time saved, 20 times over.

Pupils are found as *compact* dark blobs via connected components, not by thresholding
dark pixels: the gill and outline linework is exactly as dark as a pupil, and a plain
threshold lands the centroid on the linework instead of the eye (first attempt did exactly
that, putting eye masks 2.5x too large and 40px too high). Hand-painted masks remain the
fallback for irregular species (moth, crow) — always check `_debug_overlay.png`.
