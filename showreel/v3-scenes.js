/* Product-led V3: archived UI is enlarged proportionally; crop lenses are
   literal source pixels, not reconstructed controls. All motion depends on t. */
'use strict';
function cropLens(g,name,source,x,y,w,h,p=1){
  g.save();g.globalAlpha=clamp(p);g.shadowColor='#00000080';g.shadowBlur=24;
  rr(g,x,y,w,h,22,'#161b1e','#a7b7bd55',1.5);g.shadowBlur=0;
  g.beginPath();g.roundRect(x+2,y+2,w-4,h-4,20);g.clip();
  g.drawImage(assets[name],...source,x+2,y+2,w-4,h-4);g.restore();
}
s2=function(g,t){
  const stage=t<.5?0:t<1?1:2,p=out((t-[0,.5,1][stage])/.25);
  if(stage<2){
    rr(g,260,180,1400,560,28,'#11171b','#405057',1.5);
    line(g,280,210,1640,210,'#344147');
    const w=stage?1040:850;shot(g,stage?'medium':'small',960-w/2,210,w,p);
  }else{
    shot(g,'overview',480,135,960,p);arrow(g,1170,224,1.2);
  }
  chrome(g,2,t);bottom(g,2,t);
};
s3=function(g,t){
  const x=155,y=280,w=380,h=300;
  for(let i=0;i<=4;i++){line(g,x+i*w/4,y,x+i*w/4,y+h,'#2d3539');line(g,x,y+i*h/4,x+w,y+i*h/4,'#2d3539')}
  const a=[.18,.92],b=[.26,1];
  line(g,x,y+h,x+a[0]*w,y+(1-a[1])*h,'#84dbf365',2);
  line(g,x+w,y,x+b[0]*w,y+(1-b[1])*h,'#84dbf365',2);
  [a,b].forEach(k=>circle(g,x+k[0]*w,y+(1-k[1])*h,9,P.bg,P.ice,3));
  g.beginPath();for(let i=0;i<=100*out(t/.5);i++){const p=i/100,xx=x+bez(p,a[0],b[0])*w,yy=y+h-bez(p,a[1],b[1])*h;i?g.lineTo(xx,yy):g.moveTo(xx,yy)}
  g.strokeStyle=P.mint;g.lineWidth=4;g.stroke();
  const cycle=(t%.75)/.75;circle(g,x+cycle*w,y+h-expo(cycle)*h,11,P.white);
  shot(g,'settings',650,170,1160,out(t/.45));
  const p=out((t-.4)/.35);arrow(g,720,470+20*(1-p),1.15);if(t>.75)ring(g,720,470,t-.75);
  chrome(g,3,t);bottom(g,3,t);
};
s6=function(g,t){
  // Metaballs continuously morph into a rounded island silhouette. No UI sticker.
  const join=smooth((t-.45)/1.15),spread=mix(160,70,join);
  const blobs=[{x:480-spread,y:250+Math.sin(t*2)*13,r:64},{x:480,y:250,r:74},{x:480+spread,y:250-Math.sin(t*2)*13,r:64}];
  const ar=metaImage.data;
  for(let y=0;y<540;y++)for(let x=0;x<960;x++){
    let f=0,gx=0,gy=0;
    for(const b of blobs){const dx=x-b.x,dy=y-b.y,d=dx*dx+dy*dy+16,r=b.r*b.r;f+=r/d;gx-=2*r*dx/(d*d);gy-=2*r*dy/(d*d)}
    const qx=Math.abs(x-480)-170,qy=Math.abs(y-250)-23;
    const sdf=Math.hypot(Math.max(qx,0),Math.max(qy,0))+Math.min(Math.max(qx,qy),0)-27;
    f=mix(f,1-sdf/35,join);
    const k=(y*960+x)*4;
    if(f>1){
      const edge=clamp((f-1)*24),v=clamp(f-1,0,3),den=Math.hypot(gx,gy)+.002;
      const ny=mix(gy/den,-(y-250)/50,join),nx=mix(gx/den,-(x-480)/400,join);
      const ribbon=Math.pow(clamp(.5+.5*Math.cos(ny*2.7+nx*.6)),10);
      const shine=clamp(38+160*ribbon+48*Math.exp(-v*8)-ny*15,0,245);
      ar[k]=shine;ar[k+1]=shine+3;ar[k+2]=shine+7;ar[k+3]=edge*255;
    }else ar[k]=ar[k+1]=ar[k+2]=ar[k+3]=0;
  }
  metaCtx.putImageData(metaImage,0,0);g.drawImage(metaCanvas,0,0,W,H);
  // A single quiet signal appears inside the final form, tying material to product.
  g.save();g.globalAlpha=smooth((t-1.4)/.4);[0,1,2].forEach(i=>rr(g,935+i*22,477-i*5,9,36+i*7,5,[P.mint,P.white,P.ice][i]));g.restore();
  chrome(g,6,t);bottom(g,6,t);
};
s8=function(g,t){
  const x=260,y=220,w=1400,en=out(t/.4);
  shot(g,'controls',x,y,w,en);
  // One short, low-amplitude glitch only, followed by a stable physical zoom lens.
  if(t<.24){g.save();g.globalAlpha=.13*(1-t/.24);for(let i=0;i<5;i++)line(g,x-12,y+60+i*52,x+w+12,y+60+i*52,P.ice,1.5);g.restore()}
  const focus=out((t-.5)/.35);
  cropLens(g,'controls',[25,165,1285,63],310,645,1300,92,focus);
  const px=550,py=668,p=out((t-.4)/.6);arrow(g,mix(1450,px,p),mix(470,py,p),1.2);if(t>1)ring(g,px,py,t-1);
  chrome(g,8,t);bottom(g,8,t);
};
s9=function(g,t){
  text(g,'0.2',365,397,155,P.white,500,'center');text(g,'秒',528,395,34,P.muted,300);
  const en=out((t-.2)/.4);shot(g,'overview',780,140,1000,en);
  for(let k=3;k>=1;k--){const z=Math.pow(2,(t*.6)%1),sc=z/Math.pow(2,k+1);rr(g,390-370*sc,615-130*sc,740*sc,260*sc,20,'#11171b','#75859045',1)}
  const p=out(t/.2);arrow(g,mix(1780,1180,p),mix(600,216,p),1.2);if(t>.2)ring(g,1180,216,t-.2);
  chrome(g,9,t);bottom(g,9,t);
};
s10=function(g,t){
  const en=out(t/.45);g.save();g.translate(-420,240+20*(1-en));g.scale(.6,.6);g.globalAlpha=en;
  for(let k=-3;k<=3;k++){const a=iso(k*96,-350),b=iso(k*96,350),c=iso(-350,k*96),d=iso(350,k*96);line(g,...a,...b,'#2d383c');line(g,...c,...d,'#2d383c')}
  const houses=[[-280,-190,100,100,130],[-65,-285,110,95,205],[135,-180,105,105,150],[-290,75,110,100,100],[-65,25,150,150,255],[220,60,95,115,125]];
  houses.sort((a,b)=>a[0]+a[1]-b[0]-b[1]);houses.forEach((d,i)=>building(g,...d.slice(0,4),d[4]*out((t-i*.04)/.5),i===3?'#aec8bb':'#45555c'));g.restore();
  shot(g,'connections',640,240,1180,en);chrome(g,10,t);bottom(g,10,t);
};
s11=function(g,t){
  const en=out(t/.6);g.save();g.translate(370,420);g.scale(.5,.5);g.beginPath();
  for(let i=0;i<=Math.floor(5000*en);i++){const p=i/5000,u=p*TAU*13,decay=Math.exp(-p*1.15),x=(Math.sin(u*2+t*.18)*330+Math.sin(u*2.015+1.3)*106)*decay,y=(Math.sin(u*3+Math.PI/2)*230+Math.sin(u*3.018+.3+t*.15)*70)*decay;i?g.lineTo(x,y):g.moveTo(x,y)}
  g.strokeStyle='#b9ded1';g.lineWidth=1.4;g.stroke();g.restore();
  text(g,'24 小时',370,230,62,P.white,500,'center');
  shot(g,'overview',780,140,1000,en);
  cropLens(g,'overview',[1137,332,132,62],225,628,300,140,out((t-.5)/.35));
  arrow(g,400,685,1.15);if(t>1)ring(g,400,685,t-1);
  chrome(g,11,t);bottom(g,11,t);
};
// Distinct transitions share the same radius, centered horizontal footprint,
// and restrained edge light. Individual motions remain different by request.
composite=function(g,old,newer,kind,p){
  const q=smooth(p);g.drawImage(old,0,0);g.save();
  const mask=(x,y,w,h,r=34)=>{g.beginPath();g.roundRect(x,y,Math.max(.1,w),Math.max(.1,h),r);g.clip();g.drawImage(newer,0,0)};
  switch(kind){
    case 0: mask(960-980*q,540-560*q,1960*q,1120*q,Math.min(34,550*q));break;
    case 1: g.drawImage(old,-W*q,0);g.drawImage(newer,W*(1-q),0);break;
    case 2: g.drawImage(newer,0,0);g.translate(960,540);g.scale(Math.max(.001,1-q),1);g.drawImage(old,-960,-540);break;
    case 3: mask(960-1100*q,-140+120*(1-q),2200*q,1400,34);break;
    case 4: g.translate(960,540);g.scale(1+q*.35,1+q*.35);g.globalAlpha=1-q;g.drawImage(old,-960,-540);g.restore();g.save();g.globalAlpha=q;g.drawImage(newer,0,0);break;
    case 5: g.globalAlpha=q;g.filter=`blur(${(1-q)*7}px)`;g.drawImage(newer,0,0);break;
    case 6: mask(-80,540-600*q,2080,1200*q,32);break;
    case 7: mask(0,0,1920*q,1080,26);break;
    case 8: for(let k=0;k<3;k++){const y=k*360,dx=(1-q)*(k%2?W:-W);g.drawImage(newer,0,y,W,360,dx,y,W,360)}break;
    case 9: mask(960-1100*q,-80,2200*q,1200*q,34);break;
    case 10: g.drawImage(newer,0,0);g.translate(W*q,H*q*.12);g.globalAlpha=1-q*.5;g.drawImage(old,0,0);break;
    case 11: mask(W*(1-q),0,W*q,H,26);line(g,W*(1-q),160,W*(1-q),920,'#a5bbb560',2);break;
  }g.restore();
};
