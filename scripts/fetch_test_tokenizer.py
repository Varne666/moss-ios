from pathlib import Path
import hashlib,json,urllib.request
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'Moss/Resources/model-manifest.json').read_text())
f=next(f for f in manifest['files'] if f['path']=='tokenizer/tokenizer.json')
with urllib.request.urlopen(f['url'],timeout=120) as response:data=response.read()
assert len(data)==f['bytes'] and hashlib.sha256(data).hexdigest()==f['sha256'], 'Tokenizer checksum mismatch'
(root/'Tests/tokenizer.json').write_bytes(data)
print('Verified test tokenizer downloaded (about 20 MB). No model weights are downloaded by the build.')
