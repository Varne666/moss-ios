"""Package the archived app as unsigned IPAs and check their contents."""
from pathlib import Path
import plistlib
import shutil
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
app = root / "build/Moss.xcarchive/Products/Applications/Moss.app"
if not app.is_dir():
    sys.exit("The archive does not contain Moss.app. Read the archive log.")
info = plistlib.loads((app / "Info.plist").read_bytes())
if not (app / info["CFBundleExecutable"]).is_file():
    sys.exit("The app executable is missing.")
if not list(app.rglob("*.metallib")):
    sys.exit("The MLX Metal shader library is missing. Do not install this build.")
extension = app / "PlugIns/MossActivity.appex"
if not (extension / "MossActivity").is_file():
    sys.exit("The Live Activity extension is missing from the app.")
out = root / "build/Download"
out.mkdir(parents=True, exist_ok=True)


def package(name: str, skip_plugins: bool) -> None:
    with zipfile.ZipFile(out / name, "w", zipfile.ZIP_DEFLATED) as z:
        for file in sorted(app.rglob("*")):
            relative = file.relative_to(app)
            if skip_plugins and relative.parts[0] == "PlugIns":
                continue
            if file.is_file():
                z.write(file, Path("Payload/Moss.app") / relative)


package("Moss-unsigned.ipa", skip_plugins=False)
package("Moss-unsigned-no-live-activity.ipa", skip_plugins=True)
shutil.copy2(root / "Moss/Moss.entitlements", out / "Requested-memory-entitlements.plist")
shutil.copy2(root / "INSTALL-ON-IPHONE.txt", out / "INSTALL-ON-IPHONE.txt")
print("Created Moss-unsigned.ipa (with Live Activity) and Moss-unsigned-no-live-activity.ipa.")
