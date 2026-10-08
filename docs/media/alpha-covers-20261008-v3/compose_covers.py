from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

LOCAL=Path(__file__).resolve().parent
IN_PROJECT=LOCAL.name=='alpha-covers-20261008-v3'
MEDIA=LOCAL.parent if IN_PROJECT else Path('/Users/wangpengfei/Documents/Obsidian Vault/作品集/linglongtai-hud/docs/media')
OUT=LOCAL if IN_PROJECT else Path('/private/tmp/agent-island-posters-20261008-v3')
FONT='/System/Library/Fonts/Hiragino Sans GB.ttc'
OUT.mkdir(exist_ok=True)

def text(draw, xy, value, size, color):
    draw.multiline_text(xy,value,font=ImageFont.truetype(FONT,size,index=0),fill=color,spacing=18)

def capture(path,box):
    with Image.open(path) as source:
        shot=source.convert('RGBA').crop(box)
    px=shot.load()
    for y in range(shot.height):
        for direction in (range(shot.width),range(shot.width-1,-1,-1)):
            for x in direction:
                if min(px[x,y][:3])<=235: break
                px[x,y]=(0,0,0,0)
    return shot

def poster(name,heading,body,note,shot,dark=False):
    bg=(12,16,18) if dark else (244,245,241)
    fg=(242,245,244) if dark else (21,28,28)
    muted=(149,158,157) if dark else (104,112,110)
    canvas=Image.new('RGBA',(1920,1080),bg+(255,))
    x,y,w=855,257,990
    h=round(w*1964/3024)
    shadow=Image.new('RGBA',canvas.size)
    ImageDraw.Draw(shadow).rounded_rectangle((x-14,y-14,x+w+14,y+h),42,fill=(0,0,0,60))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(22)))
    draw=ImageDraw.Draw(canvas)
    draw.rounded_rectangle((x-8,y-8,x+w+8,y+h+8),24,fill=(91,97,95),outline=(166,171,168),width=2)
    draw.rounded_rectangle((x-4,y-4,x+w+4,y+h+4),21,fill=(11,15,15))
    base='states-base-v1.png' if dark else 'focus-base-v1.png'
    with Image.open(MEDIA/'alpha-covers-20261007-v1'/base) as image:
        # Reuse only wallpaper; none of the old generated notch survives.
        from PIL import ImageOps
        wallpaper=ImageOps.fit(image.convert('RGBA').crop((290,650,1080,1080)),(w,h),method=Image.Resampling.LANCZOS)
    mask=Image.new('L',(w,h))
    ImageDraw.Draw(mask).rounded_rectangle((0,0,w,h),18,fill=255)
    wallpaper.putalpha(mask)
    canvas.alpha_composite(wallpaper,(x,y))
    # Screenshots are 2x captures; every state shares a 3024 px screen scale.
    scale=w/3024
    shot=shot.resize((round(shot.width*scale),round(shot.height*scale)),Image.Resampling.LANCZOS)
    canvas.alpha_composite(shot,(x+(w-shot.width)//2,y))
    draw=ImageDraw.Draw(canvas)
    base_y=y+h+12
    draw.polygon([(x-28,base_y),(x+w+28,base_y),(x+w+15,base_y+20),(x-15,base_y+20)],fill=(112,118,116))
    draw.line((x-26,base_y,x+w+26,base_y),fill=(196,200,198),width=2)
    draw.rounded_rectangle((x+w//2-70,base_y,x+w//2+70,base_y+7),4,fill=(65,70,68))
    text(draw,(84,86),'Agent 灵动岛',29,fg)
    text(draw,(84,133),'MULTI-AGENT · macOS',16,muted)
    text(draw,(84,280),heading,76,fg)
    text(draw,(88,600),body,29,muted)
    text(draw,(88,807),note,22,muted)
    text(draw,(84,1000),'真实产品界面合成 · 非整屏实拍',19,muted)
    canvas.convert('RGB').save(OUT/name)

small=capture(MEDIA/'real-product-ui/01-small-state-20261008.jpg',(465,0,1055,80))
middle_source=MEDIA/'real-product-ui/02-middle-state-preview-20261008.jpg' if IN_PROJECT else Path('/private/tmp/agent-island-middle-preview-updated-crop.jpg')
medium=capture(middle_source,(300,0,1220,80))
overview=capture(MEDIA/'real-product-ui/03-task-overview-20261008.jpg',(100,0,1420,910))
poster('01-hero-agent-island.png','你的 Agent，\n在忙什么？\n一眼看见。','把多个 Agent 的任务状态\n收进 Mac 顶部的一座岛。','小态 · 低干扰地保留状态\n真实数据截图，不推测进度',small)
poster('02-status-awareness.png','少切窗口，\n看清关键状态。','重要变化横向展开，\n长任务随后收回小态。','中态 · 当前版本界面\n此图为「中态预览」，非任务事件',medium)
poster('03-ambient-states.png','悬停展开，\n看清详情。','连续悬停 0.2 秒展开，\n移开后回到对应状态。','最近 24 小时任务记录\n查看会话线索与已返回步骤',overview,True)
sheet=Image.new('RGB',(960,1620))
for i,name in enumerate(('01-hero-agent-island.png','02-status-awareness.png','03-ambient-states.png')):
    with Image.open(OUT/name) as im:
        sheet.paste(im.resize((960,540),Image.Resampling.LANCZOS),(0,i*540))
sheet.save(OUT/'00-poster-preview.jpg',quality=95)
