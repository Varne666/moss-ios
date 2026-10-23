"""Portable checks; this does not replace the Xcode build or physical-device testing."""
from pathlib import Path
import ast,json,re,plistlib,struct
root=Path(__file__).resolve().parents[1]
required=['project.yml','Moss/MossApp.swift','Moss/Models.swift','Moss/Engine/Pipeline.swift','Moss/Engine/Decoder.swift','Moss/Engine/Transformer.swift','Moss/Engine/TextEncoder.swift','Moss/Services/ModelManager.swift','Moss/Services/GalleryStore.swift','Moss/Services/AppModel.swift','INSTALL-ON-IPHONE.txt','.github/workflows/build.yml','Tests/MossTests.swift']
for name in required:assert (root/name).is_file(),f'Missing {name}'
manifest=json.loads((root/'Moss/Resources/model-manifest.json').read_text())
paths=set()
for f in manifest['files']:
 p=Path(f['path']);assert not p.is_absolute() and '..' not in p.parts
 assert f['path'] not in paths;paths.add(f['path'])
 assert re.fullmatch(r'[a-f0-9]{64}',f['sha256'])
 assert f['bytes']>0 and f['url'].startswith('https://huggingface.co/')
 assert '/resolve/' in f['url'] and re.search(r'/resolve/[a-f0-9]{40}/',f['url'])
assert sum(f['bytes'] for f in manifest['files'] if f['component'] not in ('adapter','kromoss'))==12075713035
assert sum(f['bytes'] for f in manifest['files'] if f['component']=='adapter')==1189176800
assert sum(f['bytes'] for f in manifest['files'] if f['component']=='kromoss')==10164655808
assert len([f for f in manifest['files'] if f['component']=='transformer' and f['path'].endswith('.safetensors')])==2
assert len([f for f in manifest['files'] if f['component']=='text' and f['path'].endswith('.safetensors')])==2
asset=root/'Moss/Assets.xcassets/AppIcon.appiconset'
for image in json.loads((asset/'Contents.json').read_text())['images']:
 data=(asset/image['filename']).read_bytes()
 assert data[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('>II',data[16:24])==(1024,1024)
 assert data[25] in (2,0), 'Icons must be opaque RGB or grayscale'
for p in root.rglob('*.json'):json.loads(p.read_text())
for p in root.rglob('*.xcprivacy'):plistlib.loads(p.read_bytes())
for p in (root/'scripts').glob('*.py'):ast.parse(p.read_text(),filename=str(p))
for p in (root/'Moss').rglob('*.swift'):
 assert not re.search(r'\b(TODO|FIXME|fatalError)\b',p.read_text()),f'Unfinished source in {p}'
print(f'PASS: manifest, pinned file identities, {len(paths)} model files, icons, privacy manifest, source presence, and Python syntax.')
print('Apple compilation, Swift tests, signing, memory use, speed, and image quality require their separate checks.')
