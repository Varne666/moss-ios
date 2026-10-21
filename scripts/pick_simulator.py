"""Print the UDID of the best available iPhone simulator (prefers the newest iOS runtime, then Pro Max)."""
import json
import re
import subprocess
import sys

devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]


def runtime_version(runtime: str) -> tuple:
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


candidates = [
    (runtime_version(runtime), "Pro Max" in d["name"], d["name"], d["udid"])
    for runtime, entries in devices.items()
    if "iOS" in runtime and runtime_version(runtime) >= (26, 0)
    for d in entries
    if d.get("isAvailable") and d["name"].startswith("iPhone")
]
if not candidates:
    sys.exit("No iOS 26+ iPhone simulator is installed on this runner.")
candidates.sort(reverse=True)
print(candidates[0][3])
