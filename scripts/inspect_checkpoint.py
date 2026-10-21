"""Print configs and selected safetensors header entries of downloaded weights (CI only). Usage: inspect_checkpoint.py MODELS_DIR"""
import json
import re
import struct
import sys
from pathlib import Path

models = Path(sys.argv[1])
for config in sorted(models.rglob("*config*.json")):
    print(f"== {config.relative_to(models)}")
    print(config.read_text()[:4000])
tok = json.loads((models / "tokenizer/tokenizer.json").read_text())
print("== tokenizer: normalizer", tok.get("normalizer"), "\npre_tokenizer", json.dumps(tok.get("pre_tokenizer"))[:600])
print("ignore_merges", tok["model"].get("ignore_merges"), "added", [(t["content"], t["lstrip"], t["rstrip"], t["normalized"]) for t in tok["added_tokens"]][:40])
interesting = re.compile(r"^(layers\.(0|3|22|31|41)\.|text_embedder|time_embedding|shared_block|video_|final_|embed_tokens|norm\.|running_|post_quant|decoder\.(conv_in|conv_out|mid_block\.attentions)|diffusion_model\.layers\.0\.)")
for shard in sorted(models.rglob("*.safetensors")):
    with open(shard, "rb") as handle:
        (length,) = struct.unpack("<Q", handle.read(8))
        header = json.loads(handle.read(length))
    meta = header.pop("__metadata__", None)
    print(f"== {shard.relative_to(models)}: {len(header)} tensors, metadata={meta}")
    for name in sorted(header):
        if interesting.match(name):
            print(f"  {name} {header[name]['dtype']} {header[name]['shape']}")
    dtypes = {}
    for v in header.values():
        dtypes[v["dtype"]] = dtypes.get(v["dtype"], 0) + 1
    print("  dtypes:", dtypes)
