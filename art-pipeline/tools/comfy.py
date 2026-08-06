"""Minimal ComfyUI HTTP client and the PawWard graph builders.

Mass production is driven from here rather than one tool call per image: a full roster is
several hundred renders, and a script that builds graphs from a species table is both cheaper
and reproducible. Everything is core-node only — no custom node packs required.

Krea 2 Turbo settings are frozen (see ../prompts/SCAFFOLD.md). Two things about this model
that are easy to get wrong and are encoded here so they cannot drift:
  * There is no negative prompt. At cfg 1 the negative slot takes a ConditioningZeroOut of the
    positive, so guards must be phrased positively.
  * EmptyLatentImage is correct (not EmptySD3LatentImage), per the verified pack graph.
"""

from __future__ import annotations

import hashlib
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

HOST = "http://127.0.0.1:8188"

UNET = "krea2_turbo_nvfp4.safetensors"
CLIP = "qwen3vl_4b_fp8_scaled.safetensors"
VAE = "qwen_image_vae.safetensors"
STYLE_LORA = "krea2_softwatercolor.safetensors"
STYLE_STRENGTH = 0.85

# 1536 rather than 1024: measured side by side, 1536 gains visible watercolour paper grain,
# delicate ink linework, eyelid lines and skin freckles that 1024 renders flat.
RES = 1536
STEPS = 8
CFG = 1.0
SAMPLER = "er_sde"
SCHEDULER = "simple"


# --- HTTP -----------------------------------------------------------------------------

def post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        f"{HOST}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def get(path: str) -> dict:
    with urllib.request.urlopen(f"{HOST}{path}", timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def alive() -> bool:
    try:
        get("/system_stats")
        return True
    except Exception:
        return False


def enqueue(graph: dict) -> str:
    return post("/prompt", {"prompt": graph})["prompt_id"]


def upload_image(path: Path, name: str | None = None) -> str:
    """Multipart upload into ComfyUI's input/ directory, named by CONTENT hash.

    ComfyUI caches LoadImage on the filename, so re-uploading different content under a name the
    server has already seen can return the PREVIOUS decode. That silently wasted a whole re-run of
    the third_eye anomaly: 20 renders came back byte-identical to the failed originals, which then
    got mis-diagnosed as a generation problem.

    Hashing the content makes the name change exactly when the pixels change: identical input still
    hits the cache (which is the point of it), and changed input can never be served stale. The
    caller's `name` is kept as a readable prefix.
    """
    digest = hashlib.sha1(path.read_bytes()).hexdigest()[:10]
    stem = Path(name).stem if name else path.stem
    name = f"{stem}_{digest}.png"
    boundary = "----pawward"
    body = b"".join([
        f"--{boundary}\r\n".encode(),
        f'Content-Disposition: form-data; name="image"; filename="{name}"\r\n'.encode(),
        b"Content-Type: image/png\r\n\r\n",
        path.read_bytes(),
        f"\r\n--{boundary}\r\n".encode(),
        b'Content-Disposition: form-data; name="overwrite"\r\n\r\ntrue\r\n',
        f"--{boundary}--\r\n".encode(),
    ])
    req = urllib.request.Request(
        f"{HOST}/upload/image", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))["name"]


def wait_for_queue(poll: float = 3.0, quiet: bool = False) -> None:
    """Block until the ComfyUI queue is fully drained."""
    last = -1
    while True:
        try:
            q = get("/queue")
        except Exception:
            time.sleep(poll)
            continue
        pending = len(q.get("queue_pending", [])) + len(q.get("queue_running", []))
        if pending != last and not quiet:
            print(f"  queue: {pending} remaining", flush=True)
            last = pending
        if pending == 0:
            return
        time.sleep(poll)


# --- graph fragments ------------------------------------------------------------------

def _stack(with_style_lora: bool = True) -> dict:
    """Loaders + the model path. Returns nodes keyed 1-4."""
    nodes = {
        "1": {"class_type": "UNETLoader",
              "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader",
              "inputs": {"clip_name": CLIP, "type": "krea2", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
    }
    if with_style_lora:
        nodes["4"] = {"class_type": "LoraLoaderModelOnly",
                      "inputs": {"model": ["1", 0], "lora_name": STYLE_LORA,
                                 "strength_model": STYLE_STRENGTH}}
    return nodes


def _model_ref(with_style_lora: bool) -> list:
    return ["4", 0] if with_style_lora else ["1", 0]


def _conditioning(prompt: str) -> dict:
    return {
        "5": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["2", 0], "text": prompt}},
        "6": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["5", 0]}},
    }


def _sampler(latent: list, seed: int, steps: int, denoise: float, style: bool) -> dict:
    return {
        "8": {"class_type": "KSampler", "inputs": {
            "model": _model_ref(style), "positive": ["5", 0], "negative": ["6", 0],
            "latent_image": latent, "seed": seed, "steps": steps, "cfg": CFG,
            "sampler_name": SAMPLER, "scheduler": SCHEDULER, "denoise": denoise}},
        "9": {"class_type": "VAEDecode", "inputs": {"samples": ["8", 0], "vae": ["3", 0]}},
    }


def _save(prefix: str) -> dict:
    return {"10": {"class_type": "SaveImage",
                   "inputs": {"images": ["9", 0], "filename_prefix": prefix}}}


# --- public graph builders ------------------------------------------------------------

def txt2img(prompt: str, prefix: str, seed: int, batch: int = 1,
            res: int = RES, style: bool = True, steps: int = STEPS) -> dict:
    g = _stack(style)
    g.update(_conditioning(prompt))
    g["7"] = {"class_type": "EmptyLatentImage",
              "inputs": {"width": res, "height": res, "batch_size": batch}}
    g.update(_sampler(["7", 0], seed, steps, 1.0, style))
    g.update(_save(prefix))
    return g


def img2img(image_name: str, prompt: str, prefix: str, seed: int, denoise: float,
            style: bool = True, steps: int = 10) -> dict:
    """Whole-frame restyle. Used for the X-ray view, which inherits the creature's pose."""
    g = _stack(style)
    g.update(_conditioning(prompt))
    g["20"] = {"class_type": "LoadImage", "inputs": {"image": image_name}}
    g["23"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["20", 0], "vae": ["3", 0]}}
    g.update(_sampler(["23", 0], seed, steps, denoise, style))
    g.update(_save(prefix))
    return g


def inpaint(image_name: str, mask_name: str, prompt: str, prefix: str, seed: int,
            denoise: float, style: bool = True, steps: int = 10) -> dict:
    """Masked edit that ends in a hard composite over the untouched original.

    ImageCompositeMasked is what makes registration exact by construction: outside-mask
    pixels come from the source file and never make a VAE round trip.
    """
    g = _stack(style)
    g.update(_conditioning(prompt))
    g["20"] = {"class_type": "LoadImage", "inputs": {"image": image_name}}
    g["21"] = {"class_type": "LoadImage", "inputs": {"image": mask_name}}
    g["22"] = {"class_type": "ImageToMask", "inputs": {"image": ["21", 0], "channel": "red"}}
    g["23"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["20", 0], "vae": ["3", 0]}}
    g["24"] = {"class_type": "SetLatentNoiseMask",
               "inputs": {"samples": ["23", 0], "mask": ["22", 0]}}
    g.update(_sampler(["24", 0], seed, steps, denoise, style))
    g["25"] = {"class_type": "ImageCompositeMasked", "inputs": {
        "destination": ["20", 0], "source": ["9", 0], "x": 0, "y": 0,
        "resize_source": False, "mask": ["22", 0]}}
    g["10"] = {"class_type": "SaveImage",
               "inputs": {"images": ["25", 0], "filename_prefix": prefix}}
    return g


def remove_bg(image_name: str, prefix: str) -> dict:
    """Cut the creature out. Kept here so the whole pipeline speaks one dialect."""
    return {
        "1": {"class_type": "LoadImage", "inputs": {"image": image_name}},
        "2": {"class_type": "ImageRemoveBackground", "inputs": {"image": ["1", 0]}},
        "3": {"class_type": "SaveImage",
              "inputs": {"images": ["2", 0], "filename_prefix": prefix}},
    }


OUTPUT_DIR = Path("C:/ComfyStack/ComfyUI/output")
