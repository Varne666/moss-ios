"""Regenerate the original vector icon and its three opaque iOS appearance assets."""
from pathlib import Path
import json
import cairosvg
root=Path(__file__).resolve().parents[1]
asset=root/'Moss/Assets.xcassets/AppIcon.appiconset'
design=root/'Design';design.mkdir(exist_ok=True)
forms='''<path d="M492 776 C478 661 503 532 548 342" fill="none" stroke="STEM" stroke-width="43" stroke-linecap="round"/>
<path d="M511 641 C363 651 284 570 299 423 C437 419 516 493 511 641Z" fill="LEAF"/>
<path d="M510 533 C523 373 616 292 758 317 C751 465 664 547 510 533Z" fill="LEAF"/>
<path d="M544 402 C449 340 436 246 507 160 C604 218 618 315 544 402Z" fill="TOP"/>'''
colors={'light':('#F3F2EC','#5C7652','#5C7652','#80936F'),'dark':('#151A14','#A1B88B','#829C6D','#B2C59D'),'tinted':('#202020','#DEDEDE','#BEBEBE','#EEEEEE')}
images=[]
for appearance,(bg,stem,leaf,top) in colors.items():
 body=forms.replace('STEM',stem).replace('LEAF',leaf).replace('TOP',top)
 svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect width="1024" height="1024" fill="{bg}"/><g transform="translate(-6 40)">{body}</g></svg>'
 (design/f'Moss-{appearance}.svg').write_text(svg)
 filename=f'Moss-{appearance}.png'
 cairosvg.svg2png(bytestring=svg.encode(),write_to=str(asset/filename),output_width=1024,output_height=1024)
 entry={'filename':filename,'idiom':'universal','platform':'ios','size':'1024x1024'}
 if appearance!='light':entry['appearances']=[{'appearance':'luminosity','value':appearance}]
 images.append(entry)
(asset/'Contents.json').write_text(json.dumps({'images':images,'info':{'author':'xcode','version':1}},indent=2)+'\n')
(root/'Moss/Assets.xcassets/Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}})+'\n')
print('Created SVG originals and light, dark, tinted 1024-pixel assets.')
