"""The roster: which species, and every anomaly that can happen to them.

Single source of truth for content. The generator reads it to make images, and the manifest
builder reads it to write game/data/roster.json, so art and data can never disagree about what
exists.

FIVE ANOMALY CHANNELS. Variety comes from having genuinely different *kinds* of wrong, not
from more of one kind — a player who has learned to scan the eyes should still be caught out.

    visual    inpainted art on the creature          needs: look
    skeleton  inpainted art on the X-ray plate       needs: X-ray tool + handbook
    sound     a different audio clip                 needs: stethoscope + handbook
    behaviour zero art; the animation is wrong       needs: patience
    data      zero art; the paperwork contradicts    needs: read the chart

Tier 1 obvious / 2 medium / 3 subtle. Tier drives which nights an anomaly can appear on.
"""

from __future__ import annotations

# --- species ---------------------------------------------------------------------------
#
# `look` is spliced into the base prompt. Kept short and concrete: Krea 2 follows plain
# descriptive clauses well and drifts when the prompt gets florid.
#
# `bones` describes the skeleton so each species reads as its own radiograph rather than a
# generic one — this is what makes the handbook's skeleton page meaningful.
SPECIES: list[dict] = [
    {"id": "axolotl",   "look": "a pale pink axolotl with feathery external gill fronds and a wide gentle mouth",
     "bones": "a short broad amphibian skeleton with a rounded skull, long flexible spine and four small splayed limbs"},
    {"id": "cat",       "look": "a small grey tabby kitten with upright pointed ears",
     "bones": "a slender feline skeleton with a rounded skull, sharp canine teeth and a long tail"},
    {"id": "rabbit",    "look": "a cream lop rabbit with long soft drooping ears",
     "bones": "a light skeleton with very long ear cartilage, large hind leg bones and prominent front incisors"},
    {"id": "owl",       "look": "a small round tawny owl with huge forward facing eyes",
     "bones": "a compact bird skeleton with a large eye socket ring, hooked beak, keeled breastbone and folded wing bones"},
    {"id": "fox",       "look": "a young red fox with a narrow muzzle and large triangular ears",
     "bones": "a slim canine skeleton with a long narrow snout and fine leg bones"},
    {"id": "frog",      "look": "a plump green tree frog with round toe pads and a wide mouth",
     "bones": "a squat amphibian skeleton with a broad flat skull, no ribs to speak of and very long folded hind legs"},
    {"id": "hedgehog",  "look": "a small hedgehog with a spiny back and a tiny pointed snout",
     "bones": "a small rounded skeleton with a short snout, and a dense halo of fine spine quills",
     "hint": "spines"},
    {"id": "hamster",   "look": "a golden hamster with round cheeks and tiny ears",
     "bones": "a very small rodent skeleton with large cheek pouches and prominent incisors"},
    {"id": "fawn",      "look": "a spotted deer fawn with big dark eyes and slender ears",
     "bones": "a delicate skeleton with very long thin leg bones and a narrow elongated skull"},
    {"id": "bat",       "look": "a small brown fruit bat with large translucent ears and folded wings",
     "bones": "a skeleton with enormously elongated finger bones spreading the wing membrane"},
    {"id": "snake",     "look": "a small pale green snake coiled upright with smooth scales and round eyes",
     "bones": "an extremely long ribbed spine with hundreds of fine curved ribs and a small hinged skull"},
    {"id": "duckling",  "look": "a fluffy yellow duckling with a rounded orange bill",
     "bones": "a light bird skeleton with a broad flat bill, keeled breastbone and webbed foot bones"},
    {"id": "turtle",    "look": "a small turtle with a domed patterned shell and a wrinkled neck",
     "bones": "a skeleton fused to a domed bony shell of plates, with a retractable neck",
     "hint": "shell"},
    {"id": "ferret",    "look": "a cream ferret with a long body, dark eye mask and small round ears",
     "bones": "a very long slender spine with short limbs"},
    {"id": "moth",      "look": "a large fuzzy pale moth with feathered antennae and round wings",
     "bones": "a delicate insect exoskeleton with segmented thorax, thin veined wing struts and feathered antennae",
     "hint": "insect"},
    {"id": "raccoon",   "look": "a young raccoon with a dark eye mask and rounded ears",
     "bones": "a stocky skeleton with a short broad skull and dexterous long finger bones"},
    {"id": "goatkid",   "look": "a white goat kid with small budding horns and floppy ears",
     "bones": "a skeleton with small horn buds on the skull and slender cloven hoof bones"},
    {"id": "capybara",  "look": "a large calm capybara with a blunt square snout and small round ears",
     "bones": "a heavy rodent skeleton with a deep blunt skull and huge continuously growing incisors"},
    {"id": "gecko",     "look": "a small spotted gecko with large lidless eyes and wide toe pads",
     "bones": "a fine lizard skeleton with a long tapering tail and splayed toe bones"},
    {"id": "crow",      "look": "a young crow with glossy black feathers and a straight strong beak",
     "bones": "a light bird skeleton with a long straight beak, keeled breastbone and hollow bones"},
]


# --- pupil overrides -------------------------------------------------------------------
#
# Automatic pupil detection finds an eye as a dark centre inside a LIGHTER ring, which is what an
# eye actually is, and gets 19 of 20 species right. It cannot get the raccoon: its dark facial
# mask surrounds the eyes, so the bright surround the detector keys on simply is not there.
#
# Normalised (x, y) of each pupil plus the pupil radius as a fraction of image width. Add an
# entry for any future species the detector misses rather than loosening the detector, which
# regresses the ones it already gets right.
PUPIL_OVERRIDES: dict[str, dict] = {
    "raccoon": {"left": (0.385, 0.415), "right": (0.618, 0.415), "radius": 0.022},
}


# --- visual anomalies (inpainted on the creature) ---------------------------------------
#
# `track` A = modify something already there (full frame, moderate denoise).
# `track` B = ADD something that is not there (needs a native-resolution crop at denoise 1.0;
#             full-frame inpainting will not build a new feature in a small mask at any denoise).
VISUAL: list[dict] = [
    # Track B prompts are authored as ONE sentence and used verbatim — never assembled from a
    # species description plus a clause.
    #
    # Assembling produced "...forehead of a grey tabby kitten WITH UPRIGHT POINTED EARS, one large
    # extra round eye...", where the `with` binds to the ears and the eye is left as a trailing
    # clause competing with the species features. That silently failed on all 20 species. Binding
    # the new feature into the subject ("a forehead WITH one large extra eye") works on every one.
    # The species is left out entirely: the crop already shows whose forehead it is, and naming its
    # other features only gives the model something else to render.
    {"id": "third_eye", "tier": 1, "mask": "forehead", "track": "B", "denoise": 1.0,
     "clause": "ONE large extra round eye in the centre of the forehead",
     "full_prompt": "soft watercolor storybook illustration, extreme close up of an animal's "
                    "forehead WITH ONE large extra round eye in the centre of it, big glossy dark "
                    "pupil with a single white highlight, thin dark painted eyelid outline around "
                    "it, staring straight at the viewer, muted palette, clean crisp painted "
                    "edges"},
    {"id": "too_many_teeth", "tier": 2, "mask": "mouth", "track": "A", "denoise": 0.70,
     "clause": "mouth open in a smile slightly too wide, a few too many small even white teeth "
               "in a neat row"},
    {"id": "doubled_pupils", "tier": 2, "mask": "eyes", "track": "A", "denoise": 0.95,
     "clause": "each eye contains TWO separate round dark pupils side by side, four dark pupils "
               "in total, unsettling wrong eyes"},
    {"id": "slit_pupils", "tier": 3, "mask": "eyes", "track": "A", "denoise": 0.85,
     "clause": "the pupils are narrow vertical slits like a goat's instead of round"},
    {"id": "asymmetric_eyes", "tier": 3, "mask": "eyes", "track": "A", "denoise": 0.80,
     "clause": "one eye is noticeably larger than the other and sits slightly lower"},
]


# --- skeleton anomalies (inpainted on the X-ray plate) ----------------------------------
#
# Masks here are proportions of the plate rather than pupil-derived, because a radiograph has
# no eyes to key off. Given as (x, y, w, h) in 0-1 units.
SKELETON: list[dict] = [
    {"id": "foreign_object", "tier": 1, "region": [0.30, 0.45, 0.40, 0.30], "denoise": 1.0,
     "clause": "a bright solid white foreign object shaped like a small key swallowed inside the "
               "abdomen, dense and opaque on the radiograph"},
    {"id": "second_skull", "tier": 1, "region": [0.28, 0.05, 0.44, 0.34], "denoise": 1.0,
     "clause": "a second smaller skull nested inside the head, two overlapping jaws visible"},
    {"id": "extra_ribs", "tier": 2, "region": [0.22, 0.38, 0.56, 0.30], "denoise": 0.85,
     "clause": "far too many ribs, crowded together in an uneven count, some ribs forked at the tip"},
    {"id": "extra_vertebra", "tier": 3, "region": [0.38, 0.30, 0.24, 0.45], "denoise": 0.85,
     "clause": "the spine has one extra vertebra and a slight unnatural kink where it joins"},
    {"id": "hollow_limb", "tier": 3, "region": [0.04, 0.42, 0.32, 0.36], "denoise": 0.85,
     "clause": "one limb bone is hollow and darker than the others, with no marrow shadow inside"},
]


# --- sound anomalies (stethoscope) ------------------------------------------------------
#
# Shared across the whole roster rather than authored per species: a heartbeat does not need to
# be species-specific to be recognisably WRONG, and 20 bespoke clips would be waste. The
# handbook tells the player what normal sounds like.
SOUND_NORMAL = {
    "id": "normal", "prompt":
        "A calm steady small animal heartbeat heard through a stethoscope, soft regular double "
        "thump, gentle breathing underneath, warm and muffled, close and intimate, no music."}

SOUND: list[dict] = [
    {"id": "two_hearts", "tier": 1,
     "prompt": "Two separate animal heartbeats overlapping out of sync through a stethoscope, "
               "one faster than the other, muffled and wet, unsettling, no music."},
    {"id": "clockwork", "tier": 2,
     "prompt": "A faint mechanical clockwork ticking and tiny gear whirring heard through a "
               "stethoscope where a heartbeat should be, dry and precise, muffled, no music."},
    {"id": "hollow", "tier": 2,
     "prompt": "A hollow empty echoing space heard through a stethoscope, faint distant dripping, "
               "no heartbeat at all, cavernous and dry, unsettling, no music."},
    {"id": "whisper", "tier": 3,
     "prompt": "Through a stethoscope, a heartbeat with a very faint distorted human whisper "
               "buried underneath it, almost inaudible, unintelligible, eerie, no music."},
    {"id": "too_fast", "tier": 3,
     "prompt": "A small animal heartbeat racing far too fast through a stethoscope, rapid "
               "fluttering double thumps, panicked, muffled, no music."},
]


# --- zero-art anomalies -----------------------------------------------------------------

BEHAVIOUR: list[dict] = [
    {"id": "too_still", "tier": 2, "params": {"breathing_disabled": True}},
    {"id": "never_blinks", "tier": 3, "params": {"blink_disabled": True}},
    {"id": "dead_eyes", "tier": 3, "params": {"pupil_tracking_disabled": True}},
]

DATA: list[dict] = [
    {"id": "chart_species", "tier": 2, "params": {"field": "species"}},
    {"id": "chart_name", "tier": 3, "params": {"field": "name"}},
]


# --- prompts ----------------------------------------------------------------------------

BASE_PROMPT = (
    "soft watercolor storybook illustration of {look}, a cute animal patient, front view facing "
    "the viewer, symmetrical head-on pose, waist-up portrait centred in frame, big glossy round "
    "eyes, gentle neutral expression, mouth closed, soft warm lamplight from above, muted "
    "desaturated palette, delicate ink linework, visible watercolor paper grain, fine painted "
    "detail, clean crisp edges, plain flat dark charcoal background, single character alone, "
    "exactly two eyes, no props, no text, no border"
)

XRAY_PROMPT = (
    "veterinary radiograph x-ray plate showing {bones}, glowing pale white bones on a deep blue "
    "black background, clinical x-ray film, soft radiographic glow, faint translucent body "
    "outline around the skeleton, symmetrical front view, centred, no text, no labels, no border"
)

BLINK_CLAUSE = "both eyes gently closed, smooth closed eyelids with a soft curved lash line"
MOUTH_CLAUSE = "mouth slightly open in a small soft oh shape, relaxed"
BLANK_EYES_CLAUSE = (
    "both eyes are plain blank glossy white domes with NO pupils and no dark markings at all, "
    "smooth empty white eyeballs"
)


def base_prompt(sp: dict) -> str:
    return BASE_PROMPT.format(look=sp["look"])


def xray_prompt(sp: dict) -> str:
    return XRAY_PROMPT.format(bones=sp["bones"])


def species_by_id(sid: str) -> dict:
    for sp in SPECIES:
        if sp["id"] == sid:
            return sp
    raise KeyError(sid)
