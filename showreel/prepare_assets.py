"""Prepare installed-app icons and privacy-safe existing product captures.
Original files are read-only. Never reads runtime task files or private desktop.
"""
import hashlib
import json
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parent
OUT=ROOT/'output/v2/assets'
OUT.mkdir(parents=True,exist_ok=True)
items=[]


def save(name,im,source,changes):
    dest=OUT/(name+'.png')
    im.save(dest)
    items.append({'name':name,'source':str(source),'changes':changes,
                  'size':im.size,'sha256':hashlib.sha256(dest.read_bytes()).hexdigest()})


apps=[('codex','Codex','electron.icns'),('claude','Claude','electron.icns'),
      ('workbuddy','WorkBuddy','icon.icns'),('doubao','Doubao','app.icns')]
for name,app,icon in apps:
    src=Path('/Applications')/(app+'.app')/'Contents/Resources'/icon
    raw=OUT/(name+'-source.png')
    subprocess.run(['/usr/bin/sips','-s','format','png',str(src),'--out',str(raw)],check=True,capture_output=True)
    im=Image.open(raw).convert('RGBA')
    bbox=im.getchannel('A').getbbox()
    if bbox:im=im.crop(bbox)
    im.thumbnail((256,256),Image.Resampling.LANCZOS)
    tile=Image.new('RGBA',(256,256))
    tile.alpha_composite(im,((256-im.width)//2,(256-im.height)//2))
    save(name,tile,src,'original installed application icon; transparent padding trimmed; aspect preserved')

media=REPO/'docs/media/real-product-ui'
for name,file,box in [('small','01-small-state-20261008.jpg',(465,0,1055,80)),
                      ('medium','02-middle-state-preview-20261008.jpg',(300,0,1220,80))]:
    src=media/file;im=Image.open(src).convert('RGBA').crop(box)
    # Flood-fill connected white exterior only: white app icons stay intact.
    px=im.load();stack=[(0,0),(im.width-1,0),(0,im.height-1),(im.width-1,im.height-1)];seen=set()
    while stack:
        x,y=stack.pop()
        if (x,y) in seen or not(0<=x<im.width and 0<=y<im.height):continue
        seen.add((x,y));r,g,b,a=px[x,y]
        if min(r,g,b)>210:
            px[x,y]=(r,g,b,0);stack.extend([(x-1,y),(x+1,y),(x,y-1),(x,y+1)])
    save(name,im,src,'crop + remove exterior white screenshot background only; contents unchanged')

src=REPO/'docs/media/alpha-overview-20261008-v2/assets/four-agent-overview-20261008-210709.png'
im=Image.open(src).convert('RGBA')
d=ImageDraw.Draw(im)
# Cursor outside content is a capture artifact; same removal used by existing poster.
d.rectangle((582,0,616,36),fill=(0,0,0,255))
# Title / ids / local times / private URL: opaque, explicit redaction, no fabricated text.
for box in [(132,422,414,490),(132,557,414,661),(132,738,420,833),
            (602,422,940,490),(1114,457,1280,500)]:
    d.rectangle(box,fill=(18,18,18,255))
    x,y,x2,y2=box
    for yy in range(y+10,y2-8,19):d.line((x+10,yy,x2-12,yy),fill=(45,45,45,255),width=3)
save('overview',im,src,'cursor removed in empty margin; conversation titles, URL, identifiers and local times explicitly redacted; original states/buttons/layout kept')

for name,file,box in [('settings','01-agent-island-settings.png',(0,0,1440,780)),
                      ('controls','02-agent-connection.png',(56,192,1387,610)),
                      ('connections','02-agent-connection.png',(56,675,1387,1200))]:
    src=media/file
    save(name,Image.open(src).convert('RGBA').crop(box),src,'read-only crop of archived product settings screenshot; no task-content read')

(OUT/'manifest.json').write_text(json.dumps({'capture_date':'2026-10-08','items':items},indent=2,ensure_ascii=False))
print(json.dumps({'assets':len(items),'destination':str(OUT)},ensure_ascii=False))
