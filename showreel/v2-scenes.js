/* V2 keeps the original timings, replacing schematic product scenes with
   actual, privacy-redacted 2026-10-08 UI. Cursor gestures are illustrative. */
'use strict';
s2=function(g,t){
  const stage=t<.5?0:t<1?1:2,elapsed=t-[0,.5,1][stage],p=out(elapsed/.27);
  const name=['small','medium','overview'][stage],w=stage===0?590:760;
  rr(g,300,177,1320,592,28,'#11161a','#445055',1.5);
  line(g,318,206,1602,206,'#4e5b62',1);text(g,'Finder',336,201,15,'#a3aeb3');text(g,'界面存档 · 2026.10.08',1583,201,15,P.muted,400,'right');
  g.save();g.translate(960,208);g.scale(.96+.04*p,.96+.04*p);shot(g,name,-w/2,0,w,p);g.restore();
  if(stage===2){arrow(g,1093,280,1.2);text(g,'会话信息已脱敏',1530,736,17,P.muted,400,'right')}
  else text(g,stage===1?'真实中态预览，非任务事件':'真实小态界面',960,675,24,P.muted,300,'center');
  ['最小态','事件预览','悬停详情'].forEach((n,i)=>{const xx=635+i*325;circle(g,xx-88,785,4,i===stage?P.mint:'#486052');text(g,n,xx,794,24,i===stage?P.white:P.muted,400,'center')});
  chrome(g,2,t);bottom(g,2,t);
};
s3=function(g,t){
  const x=180,y=271,w=450,h=320;
  for(let i=0;i<=4;i++){line(g,x+i*w/4,y,x+i*w/4,y+h,'#2d3539');line(g,x,y+i*h/4,x+w,y+i*h/4,'#2d3539')}
  text(g,'RESPONSE / POSITION',180,231,21,P.muted,400,'left','Menlo, monospace');
  const a=[.18,.92],b=[.26,1];line(g,x,y+h,x+a[0]*w,y+(1-a[1])*h,'#84dbf365',2);line(g,x+w,y,x+b[0]*w,y+(1-b[1])*h,'#84dbf365',2);
  [a,b].forEach(k=>circle(g,x+k[0]*w,y+(1-k[1])*h,10,P.bg,P.ice,3));
  const draw=out(t/.5);g.beginPath();for(let i=0;i<=100*draw;i++){let p=i/100;let xx=x+bez(p,a[0],b[0])*w,yy=y+h-bez(p,a[1],b[1])*h;i?g.lineTo(xx,yy):g.moveTo(xx,yy)}g.strokeStyle=P.mint;g.lineWidth=4;g.stroke();
  const cycle=(t%.75)/.75,progress=expo(cycle);circle(g,x+cycle*w,y+h-progress*h,11,P.white);
  shot(g,'settings',800,235,945,out(t/.5));text(g,'真实设置页',800,203,24,P.muted,300);arrow(g,884,532,1.15);
  text(g,'响应快，收起稳。',400,688,29,'#bcc8cc',300,'center');chrome(g,3,t);bottom(g,3,t);
};
s6=function(g,t){
  // Implicit field, analytic normals, neutral metallic studio reflections.
  // Drops merge into one slender silver surface; no HUD sticker over a blob.
  const join=smooth(t/1.4),spread=mix(145,85,join);
  const blobs=[{x:480-spread,y:245+Math.sin(t*2)*12,r:71},{x:480,y:245,r:77},{x:480+spread,y:245-Math.sin(t*2)*12,r:71}];
  const ar=metaImage.data;
  for(let y=0;y<540;y++)for(let x=0;x<960;x++){
    let f=0,gx=0,gy=0;for(const b of blobs){let dx=x-b.x,dy=y-b.y,d=dx*dx+dy*dy+16,r=b.r*b.r;f+=r/d;gx-=2*r*dx/(d*d);gy-=2*r*dy/(d*d)}
    const k=(y*960+x)*4;if(f>.99){const edge=clamp((f-.99)*25),v=clamp(f-1,0,2),den=Math.hypot(gx,gy)+.002,nx=gx/den,ny=gy/den;
      const rib=Math.pow(.5+.5*Math.cos(ny*4.1+nx*1.4+v*.8),12),rim=Math.exp(-v*8),shine=clamp(32+rib*165+rim*42+(-ny+nx*.3)*17,0,245);
      ar[k]=shine;ar[k+1]=shine+4;ar[k+2]=shine+9;ar[k+3]=edge*255;
    }else ar[k]=ar[k+1]=ar[k+2]=ar[k+3]=0;
  }metaCtx.putImageData(metaImage,0,0);g.drawImage(metaCanvas,0,0,W,H);
  tracked(g,'SOFT SIGNAL. PRECISE PRESENCE.',960,270,25,5,'#c8d1d5','center');text(g,'聚合，而不堆叠。',960,735,39,P.white,300,'center');
  chrome(g,6,t);bottom(g,6,t);
};
s8=function(g,t){
  const active=t<.4;const en=out((t-.08)/.45),ww=1250,x=(W-ww)/2,y=298;
  if(active){g.save();g.globalAlpha=.22*(1-t/.4);for(let i=0;i<8;i++)line(g,x-40,325+i*43,x+ww+40,325+i*43,'#a9bfc7',2);g.restore()}
  shot(g,'controls',x,y,ww,en);tracked(g,'MAKE IT YOURS.',960,226,32,7,P.white,'center');
  const p=out((t-.35)/.5),bx=x+253*ww/1331,by=y+190*ww/1331;
  arrow(g,mix(x+900,bx,p),mix(y+360,by,p),1.15);if(t>.9)ring(g,bx,by,t-.9);
  text(g,'真实按钮：预览小态 / 预览中态 / 恢复自动尺寸',960,771,25,P.muted,300,'center');
  chrome(g,8,t);bottom(g,8,t);
};
s9=function(g,t){
  text(g,'0.2',310,430,145,P.white,500,'center');text(g,'秒',457,427,34,P.muted,300);text(g,'悬停 · 展开',310,504,34,'#b6c7c3',300,'center');
  const en=out((t-.15)/.45),w=860,x=815,y=170,hh=w*assets.overview.height/assets.overview.width;
  // Nested spatial outlines retain the infinite zoom, while real UI is intact.
  for(let k=3;k>=1;k--){const z=Math.pow(2,(t*.45)%1),sc=z/Math.pow(2,k+1);rr(g,420-350*sc,620-160*sc,700*sc,300*sc,18,'#11161b','#75859040',1)}
  shot(g,'overview',x,y,w,en);
  const p=out((t-.05)/.65);arrow(g,mix(1820,1250,p),mix(745,224,p),1.25);if(t>.8)ring(g,1250,224,t-.8);
  text(g,'真实任务总览 · 会话信息已脱敏',x+w/2,y+hh+37,22,P.muted,300,'center');chrome(g,9,t);bottom(g,9,t);
};
s10=function(g,t){
  const en=out(t/.5);g.save();g.translate(-425,55+35*(1-en));g.scale(.8,.8);g.globalAlpha=en;
  for(let k=-5;k<=5;k++){const a=iso(k*96,-400),b=iso(k*96,400),c=iso(-400,k*96),d=iso(400,k*96);line(g,...a,...b,'#2d383c');line(g,...c,...d,'#2d383c')}
  const houses=[[-280,-190,100,100,130],[-65,-285,110,95,205],[135,-180,105,105,150],[-290,75,110,100,100],[-65,25,150,150,255],[220,60,95,115,125]];
  houses.sort((a,b)=>a[0]+a[1]-b[0]-b[1]);houses.forEach((d,i)=>building(g,...d.slice(0,4),d[4]*out((t-i*.06)/.55),i===3?'#aec8bb':'#45555c'));g.restore();
  shot(g,'connections',940,249,840,en);text(g,'真实 Agent 接入页面',940,216,24,P.muted,300);chrome(g,10,t);bottom(g,10,t);
};
s11=function(g,t){
  const en=out(t/.7);g.save();g.translate(414,445);g.scale(.68,.68);g.beginPath();
  for(let i=0;i<=Math.floor(5000*en);i++){let p=i/5000,u=p*TAU*13,decay=Math.exp(-p*1.15);let x=(Math.sin(u*2+t*.18)*330+Math.sin(u*2.015+1.3)*106)*decay;let y=(Math.sin(u*3+Math.PI/2)*230+Math.sin(u*3.018+.3+t*.15)*70)*decay;i?g.lineTo(x,y):g.moveTo(x,y)}
  g.strokeStyle='#b9ded1';g.lineWidth=1.4;g.stroke();g.restore();text(g,'24 小时',409,250,58,P.white,500,'center');tracked(g,'THE TRACE OF WORK',409,705,21,4,P.muted,'center');
  const x=870,y=194,w=820;shot(g,'overview',x,y,w,en);
  const px=x+1182*w/assets.overview.width,py=y+364*w/assets.overview.width;arrow(g,px+15,py+17,1.05);if(t>.65)ring(g,px,py,t-.65);
  text(g,'查看任务 · 查看已返回步骤 · 打开应用',x+w/2,786,24,P.muted,300,'center');chrome(g,11,t);bottom(g,11,t);
};
