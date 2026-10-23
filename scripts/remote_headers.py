"""Print safetensors header summaries of remote files using HTTP range requests (CI only)."""
import json
import re
import struct
import sys
import urllib.request
from collections import Counter

def fetch(url, start, end):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}", "User-Agent": "moss-ci"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read(), r.geturl(), r.status

for url in sys.argv[1:]:
    print("=" * 100); print(url)
    try:
        head, final, status = fetch(url, 0, 7)
        (n,) = struct.unpack("<Q", head[:8])
        print("status", status, "final host", final.split("/")[2], "header bytes", n)
        raw, _, _ = fetch(final, 8, 8 + n - 1)
        header = json.loads(raw)
    except Exception as e:
        print("FAILED:", repr(e)); continue
    meta = header.pop("__metadata__", None)
    print("metadata:", json.dumps(meta)[:3000] if meta else None)
    print("tensors:", len(header), "dtypes:", Counter(v["dtype"] for v in header.values()))
    total = sum(v["data_offsets"][1] - v["data_offsets"][0] for v in header.values())
    print("data bytes:", total)
    pattern = Counter(re.sub(r"\.\d+\.", ".N.", k) for k in header)
    for k, c in sorted(pattern.items()):
        sample = next(name for name in header if re.sub(r"\.\d+\.", ".N.", name) == k)
        print(f"  {c:4d} x {k}  {header[sample]['dtype']} {header[sample]['shape']}")
