from pathlib import Path
import shutil,zipfile,plistlib,sys
root=Path(__file__).resolve().parents[1]
app=root/'build/Moss.xcarchive/Products/Applications/Moss.app'
if not app.is_dir():sys.exit('The archive does not contain Moss.app. Read the archive log.')
info=plistlib.loads((app/'Info.plist').read_bytes())
if not (app/info['CFBundleExecutable']).is_file():sys.exit('The app executable is missing.')
if not list(app.rglob('*.metallib')):sys.exit('The MLX Metal shader library is missing. Do not install this build.')
out=root/'build/Download';out.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(out/'Moss-unsigned.ipa','w',zipfile.ZIP_DEFLATED) as z:
 for file in sorted(app.rglob('*')):
  if file.is_file():z.write(file,Path('Payload/Moss.app')/file.relative_to(app))
shutil.copy2(root/'Moss/Moss.entitlements',out/'Requested-memory-entitlements.plist')
shutil.copy2(root/'INSTALL-ON-IPHONE.txt',out/'INSTALL-ON-IPHONE.txt')
print('Created build/Download/Moss-unsigned.ipa. This still requires Signulous signing.')
