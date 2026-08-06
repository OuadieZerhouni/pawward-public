# Prompt scaffold — DESIGN LAW

Consistency across the 20-creature roster comes from **freezing this scaffold and the LoRA
settings, and varying only `[species]`**. Do not "improve" the scaffold per-creature — a drifting
scaffold means a roster that doesn't look like one game.

## Base creature (txt2img)

Model stack: `krea2_turbo_nvfp4` + `krea2_softwatercolor` @ 0.85 · qwen3vl_4b encoder · qwen_image_vae
Sampler: **8 steps, cfg 1.0, er_sde, simple, denoise 1.0** (Krea 2 Turbo is distilled — more
steps or higher cfg over-cooks it). 1024×1024.

**Negative prompts do not work here.** At cfg 1 the negative is a `ConditioningZeroOut` of the
positive, so all guards must be phrased positively in the prompt itself.

```
soft watercolor storybook illustration of a cute [SPECIES] animal patient, front view facing
the viewer, symmetrical head-on pose, waist-up portrait centred in frame, big glossy round eyes,
gentle neutral expression, mouth closed, soft warm lamplight from above, muted desaturated
palette, clean crisp edges, plain flat dark charcoal background, single character alone,
exactly two eyes, no props, no text, no border
```

### Why the prompt has no clinic window
The intake window frame, chart, and backdrop are **separate game assets** composited in Godot.
The creature must render as a clean isolated subject so `remove_background` yields a usable
cutout. Never bake scenery into a creature.

### Why front-facing only
Single front-facing pose is a design law (see the plan). It removes diffusion's cross-pose
consistency weakness from the entire project and makes anomaly inpainting registration trivial.

## Anomaly variants (masked img2img + hard composite)

Krea 2 has **no inpaint checkpoint**, and it does not need one. The variant pipeline is:

1. `VAEEncode` the chosen base → `SetLatentNoiseMask` with the feathered anomaly mask
2. `KSampler`, same model + same LoRA as the base, prompt = anomaly clause (see denoise below)
3. `VAEDecode`
4. **`ImageCompositeMasked`** the result back over the untouched base using the same mask

Step 4 is the important one: **outside-mask pixels come from the original file, so the
flip test passes by construction** rather than by luck. Measured drift outside the mask:
0.001/255 (PNG rounding only). Using the same model + LoRA that made the base is what keeps
the watercolor grain continuous *inside* the mask — verified seamless at 3× zoom.

### Two tracks — verified 2026-08-06, do not skip this distinction

**Track A — modifying a feature that already exists.** Full frame. Denoise by how big a
change you want: **0.7** for a mouth reshape, **0.95** for clearly-wrong eyes. Entirely in
ComfyUI.

**Track B — adding a feature that isn't there.** Full-frame inpainting **fails**, at any
denoise: a forehead mask is ~150×140px on a 1024 canvas, too small a fraction of the latent
for the model to build a new feature inside it. Asking for a third eye full-frame at denoise
1.0 moved the region by 4.2/255 and produced nothing. Crop to native resolution instead —
384px crop upscaled to 1024 (2.67×), denoise 1.0 — and the same prompt moved it 37.9/255 and
produced a clean style-matched eye. Use `art-pipeline/tools/composite_patch.py`.

### Anomaly clauses (append to the scaffold)
| Tier | id | Mask | Track | Denoise | Clause |
|---|---|---|---|---|---|
| 2 | `doubled_pupils` | eyes | A | 0.95 | `each eye contains TWO separate round black pupils side by side, four dark pupils in total, unsettling wrong eyes` |
| 2 | `too_many_teeth` | mouth | A | 0.70 | `mouth open in a smile slightly too wide, a few too many small even white teeth in a neat row` |
| 1 | `third_eye` | forehead | **B** | 1.00 | `ONE large extra round eye in the centre of the forehead, glossy black pupil with a single white highlight, thin dark painted eyelid outline` |
| 3 | `pupil_shape` | eyes | A | 0.85 | `pupils are narrow vertical slits instead of round` |

Track B clauses should describe the region as an **extreme close-up** ("extreme close up of a
pale cream axolotl forehead with…") since the model sees only the crop.

Tier 1 = big mask/obvious · Tier 2 = medium · Tier 3 = small mask/subtle.
`behavior` and `data` anomalies (wrong shadow, never blinks, dead eyes, chart mismatch) need
**no art at all** — see the roster manifest. Lean on these when the art budget is tight; they
are free content and `never_blinks` / `dead_eyes` are among the most unsettling in the set.

Always gate with `flip_diff.py`, then confirm by eye at phone scale.
