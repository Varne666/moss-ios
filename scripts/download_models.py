"""Download the manifest's model files (CI only) and verify each SHA-256. Usage: download_models.py DEST [--adapter]"""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
dest = Path(sys.argv[1])
want_adapter = "--adapter" in sys.argv
want_kromoss = "--kromoss" in sys.argv
manifest = json.loads((root / "Moss/Resources/model-manifest.json").read_text())
for f in manifest["files"]:
    if f["component"] == "adapter" and not want_adapter:
        continue
    if f["component"] == "kromoss" and not want_kromoss:
        continue
    target = dest / f["path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    if not (target.exists() and target.stat().st_size == f["bytes"]):
        subprocess.run(["curl", "-fL", "--retry", "5", "--retry-all-errors", "-sS", "-o", str(target), f["url"]], check=True)
    digest = hashlib.sha256()
    with open(target, "rb") as handle:
        while chunk := handle.read(64 << 20):
            digest.update(chunk)
    if target.stat().st_size != f["bytes"] or digest.hexdigest() != f["sha256"]:
        sys.exit(f"Checksum mismatch: {f['path']}")
    print(f"verified {f['path']} ({f['bytes']:,} bytes)", flush=True)
