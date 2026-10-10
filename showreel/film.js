/* Quiet Power. Every pixel is a pure function of t and immutable seeded data.
   No external assets, requestAnimationFrame, timers, physics accumulation or audio state. */
'use strict';
const W=1920,H=1080,TAU=Math.PI*2;
const P={bg:'#090c0e',white:'#f7f7f4',mint:'#79f2b5',ice:'#84dbf3',muted:'#7f9292'};
const canvas=document.getElementById('film'),ctx=canvas.getContext('2d',{alpha:false});
const layerA=document.createElement('canvas'),layerB=document.createElement('canvas');
layerA.width=layerB.width=W;layerA.height=layerB.height=H;
const A=layerA.getContext('2d'),B=layerB.getContext('2d');
const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),mix=(a,b,p)=>a+(b-a)*p;
const smooth=x=>{x=clamp(x);return x*x*(3-2*x)};
const out=x=>1-Math.pow(1-clamp(x),4);
const expo=x=>x<=0?0:1-Math.pow(2,-10*clamp(x));
const back=x=>{x=clamp(x)-1;return 1+2.35*x*x*x+1.35*x*x};
const pulse=t=>Math.exp(-14*((t%0.5+0.5)%0.5));
function rng(seed){return ()=>{seed|=0;seed=seed+0x6D2B79F5|0;let x=Math.imul(seed^seed>>>15,1|seed);x=x+Math.imul(x^x>>>7,61|x)^x;return ((x^x>>>14)>>>0)/4294967296}}
const random=rng(10092026);
const dots=Array.from({length:9000},()=>({u:random(),v:random(),z:random(),a:random()*TAU,r:random(),s:random()}));
const cloud=Array.from({length:5500},(_,i)=>{const y=1-2*(i+0.5)/5500,r=Math.sqrt(1-y*y),a=i*Math.PI*(3-Math.sqrt(5));return {x:Math.cos(a)*r,y,z:Math.sin(a)*r,k:random()}});
const noise=document.createElement('canvas');noise.width=480;noise.height=270;
const ng=noise.getContext('2d'),nd=ng.createImageData(480,270);
for(let i=0;i<nd.data.length;i+=4){const v=100+random()*110;nd.data[i]=nd.data[i+1]=nd.data[i+2]=v;nd.data[i+3]=15}ng.putImageData(nd,0,0);
let particleTargets=[];
const metaCanvas=document.createElement('canvas');metaCanvas.width=480;metaCanvas.height=270;
const metaCtx=metaCanvas.getContext('2d'),metaImage=metaCtx.createImageData(480,270);

function text(g,s,x,y,size=32,color=P.white,weight=400,align='left',font='Helvetica Neue, PingFang SC, sans-serif'){
  g.fillStyle=color;g.font=`${weight} ${size}px ${font}`;g.textAlign=align;g.textBaseline='alphabetic';g.fillText(s,x,y);
}
function tracked(g,s,x,y,size,spacing,color=P.white,align='left'){
  g.font=`500 ${size}px Helvetica Neue, PingFang SC, sans-serif`;const widths=[...s].map(c=>g.measureText(c).width);const sum=widths.reduce((a,b)=>a+b,0)+spacing*(widths.length-1);
  if(align==='center')x-=sum/2;g.fillStyle=color;g.textAlign='left';g.textBaseline='alphabetic';[...s].forEach((c,i)=>{g.fillText(c,x,y);x+=widths[i]+spacing});
}
function rr(g,x,y,w,h,r,fill,stroke=null,lw=1){g.beginPath();g.roundRect(x,y,w,h,r);if(fill){g.fillStyle=fill;g.fill()}if(stroke){g.strokeStyle=stroke;g.lineWidth=lw;g.stroke()}}
function line(g,x,y,x2,y2,color,lw=1){g.beginPath();g.moveTo(x,y);g.lineTo(x2,y2);g.strokeStyle=color;g.lineWidth=lw;g.stroke()}
function circle(g,x,y,r,fill,stroke=null,lw=1){g.beginPath();g.arc(x,y,Math.max(.01,r),0,TAU);if(fill){g.fillStyle=fill;g.fill()}if(stroke){g.strokeStyle=stroke;g.lineWidth=lw;g.stroke()}}
function glow(g,x,y,r,color,alpha=.25){g.save();g.globalAlpha=alpha;let z=g.createRadialGradient(x,y,0,x,y,r);z.addColorStop(0,color);z.addColorStop(1,`${color}00`);g.fillStyle=z;g.fillRect(x-r,y-r,r*2,r*2);g.restore()}
function bg(g,t,light=false){
  g.setTransform(1,0,0,1,0,0);g.globalAlpha=1;g.globalCompositeOperation='source-over';g.filter='none';g.fillStyle=light?P.white:P.bg;g.fillRect(0,0,W,H);
  if(!light){glow(g,1430+Math.sin(t*.4)*80,600,900,P.mint,.075);glow(g,300,780,620,P.ice,.045)}
  g.save();g.globalAlpha=light?.20:.10;g.drawImage(noise,0,0,W,H);g.restore();
}
const captions=[
 ['轻一点。','一个信号，让工作被看见。','SQUASH / STRETCH'],
 ['你，继续专注。','Agent 在工作，不必来回切换。','KINETIC TYPE'],
 ['恰到好处地出现','小态持续 · 事件展开 · 悬停详情','SHAPE MORPH'],
 ['动得刚刚好','进入、停留、收起。每一步都有分寸。','EASING LAB'],
 ['多 Agent，一个岛','Codex · Claude · Work Buddy · 豆包','9,000 PARTICLES'],
 ['状态，有迹可循','只呈现事件，不推测进度。','3D POINT CLOUD'],
 ['重要时，再出现','开始 · 需要关注 · 本轮结束','LIQUID METABALLS'],
 ['并行，不凌乱','写代码、查资料、整理工作。','SWISS GRID WAVE'],
 ['决定，仍然在你','需要确认时提醒，保留你的掌控。','CONTROLLED GLITCH'],
 ['轻悬停，见详情','0.2 秒，展开任务总览。','INFINITE ZOOM'],
 ['多应用，一处掌握','macOS 顶部的轻量 Agent 状态层。','ISOMETRIC CITY'],
 ['每一步，都可回看','最近 24 小时的任务记录。','SINGLE-LINE HARMONIC'],
 ['看见 · 专注 · 掌控','你的 Agent 管家。','BEAT-CUT RECAP']
];
function chrome(g,i,t,light=false){
  const col=light?'#536865':P.muted,fg=light?P.bg:P.white;const en=out(t/.4);
  g.save();g.globalAlpha=en;tracked(g,'AGENT DYNAMIC ISLAND',92,74,20,3,fg);
  text(g,`${String(i+1).padStart(2,'0')} / 13`,1828,74,20,col,400,'right','Menlo, monospace');
  line(g,92,101,1828,101,light?'#cbd6d1':'#283132',1);
  text(g,captions[i][2],92,1010,20,col,400,'left','Menlo, monospace');
  text(g,'macOS  /  ALPHA  /  代码重绘演示',1828,1010,19,col,400,'right');g.restore();
}
function bottom(g,i,t,light=false){const en=out((t-.12)/.42);g.save();g.globalAlpha=en;g.translate(0,25*(1-en));text(g,captions[i][0],92,858,74,light?P.bg:P.white,600);text(g,captions[i][1],96,918,29,light?'#4b625d':'#b6c7c3',300);g.restore()}
function topTitle(g,s,x,y,t,size=90){const en=expo((t-.08)/.55);g.save();g.globalAlpha=en;g.translate(0,35*(1-en));text(g,s,x,y,size,P.white,600);g.restore()}
function notchPath(g,x,y,w,h){const s=Math.min(w*.075,h*.24),r=Math.min(h*.28,w*.08);g.beginPath();g.moveTo(x,y);g.quadraticCurveTo(x+s,y,x+s,y+s);g.lineTo(x+s,y+h-r);g.quadraticCurveTo(x+s,y+h,x+s+r,y+h);g.lineTo(x+w-s-r,y+h);g.quadraticCurveTo(x+w-s,y+h,x+w-s,y+h-r);g.lineTo(x+w-s,y+s);g.quadraticCurveTo(x+w-s,y,x+w,y);g.closePath()}
function brand(g,x,y,s){g.save();notchPath(g,x-s*.46,y-s*.24,s*.92,s*.50);g.fillStyle='#0a0c0d';g.fill();let gr=g.createLinearGradient(0,y-s*.25,0,y+s*.25);gr.addColorStop(0,P.white);gr.addColorStop(1,'#9aaba4');g.strokeStyle=gr;g.lineWidth=s*.035;g.stroke();[.16,.25,.12].forEach((h,i)=>rr(g,x+(i-1)*s*.14-s*.035,y-h*s/2+s*.028,s*.07,h*s,s*.04,[P.mint,P.white,P.ice][i]));g.restore()}
function mark(g,x,y,size,label='C',col=P.mint){rr(g,x-size/2,y-size/2,size,size,size*.3,'#1a2926',`${col}88`,1.5);text(g,label,x,y+size*.17,size*.39,col,600,'center')}
function island(g,x,y,w,h,t,mode='medium',agent='Claude',status='处理中'){
  g.save();g.shadowColor='#00000088';g.shadowBlur=45;g.shadowOffsetY=18;notchPath(g,x-w/2,y,w,h);g.fillStyle='#020506';g.fill();g.shadowColor='transparent';
  notchPath(g,x-w/2,y,w,h);g.strokeStyle='#d7e9e125';g.lineWidth=1.5;g.stroke();
  if(mode==='small'){
    mark(g,x-w/2+48,y+h*.51,34,'C');[0,1,2].forEach(k=>rr(g,x+w/2-70+k*9,y+h*.53-8*(.5+.5*Math.sin(t*TAU*2+k)),4,9+8*(.5+.5*Math.sin(t*TAU*2+k)),2,P.mint));
  }else{
    const lx=x-w/2+58;mark(g,lx,y+37,35,agent==='Codex'?'C':'CL');text(g,agent,lx+28,y+46,23,P.white,500);
    circle(g,x,y+24,4,'#101c20');text(g,status,x+w/2-45,y+46,23,status.includes('确认')?P.mint:'#c5d9d0',500,'right');
    if(mode==='detail'){
      line(g,x-w/2+36,y+76,x+w/2-36,y+76,'#23302f');text(g,'任务总览',x-w/2+38,y+113,24,P.white,500);text(g,'最近 24 小时',x+w/2-38,y+113,18,P.muted,400,'right');
      const rows=[['C','Codex','检查代码','进行中'],['CL','Claude','整理研究','本轮已结束'],['W','Work Buddy','汇总工作','本轮已结束']];
      rows.forEach((r,i)=>{const yy=y+162+i*63;mark(g,x-w/2+52,yy-5,31,r[0],i?P.ice:P.mint);text(g,r[1],x-w/2+80,yy,20,P.white,500);text(g,r[2],x-w/2+240,yy,19,'#a1b7ae');text(g,r[3],x+w/2-38,yy,18,i?P.muted:P.mint,400,'right')});
    }
  }g.restore();
}
function ball(g,x,y,r,sx=1,sy=1){g.save();g.translate(x,y);g.scale(sx,sy);glow(g,0,0,r*3,P.mint,.18);let q=g.createRadialGradient(-r*.35,-r*.5,r*.06,0,0,r);q.addColorStop(0,'#dcffeb');q.addColorStop(.42,P.mint);q.addColorStop(1,'#2d8864');circle(g,0,0,r,q);g.restore()}
function device(g,t){
  rr(g,1050,240,740,440,23,'#141c1f','#81948b',2);rr(g,1064,254,712,412,15,'#0b1215');
  for(let y=310;y<610;y+=46)line(g,1120,y,1655,y,'#203034',1);
  for(let i=0;i<9;i++)rr(g,1120,325+i*28,130+(i%3)*67,5,3,i%3===0?'#79f2b550':'#9faea525');
  notchPath(g,1290,255,260,34);g.fillStyle='#010303';g.fill();
  const base=g.createLinearGradient(0,680,0,710);base.addColorStop(0,'#91a39a');base.addColorStop(1,'#263831');
  g.beginPath();g.moveTo(1038,680);g.lineTo(1802,680);g.lineTo(1844,708);g.lineTo(997,708);g.closePath();g.fillStyle=base;g.fill();
  rr(g,1380,680,80,8,4,'#1b2926');
}
function s0(g,t){
  topTitle(g,'Agent 在工作。',92,337,t,94);topTitle(g,'你不必盯着。',92,455,t-.20,94);
  text(g,'QUIET POWER.',98,538,30,P.mint,400);device(g,t);
  const cyc=Math.max(0,t-.12)*1.5,ph=cyc%1;const y=636-292*4*ph*(1-ph);
  const impact=Math.exp(-120*Math.pow(Math.min(ph,1-ph),2));const stretch=1+.20*Math.abs(1-2*ph);
  const x=1420+Math.sin(t*2)*100;
  glow(g,x,654,100,P.mint,.12);g.save();g.globalAlpha=.25;g.scale(1,.15);circle(g,x,646/.15,60+impact*35,P.mint);g.restore();
  ball(g,x,y,42,1+impact*.32,stretch-impact*.43);
  const en=out((t-.4)/.5);g.save();g.globalAlpha=en;line(g,1120,756,1720,756,'#2a3c34',2);text(g,'从一个轻量信号开始',1420,735,25,'#a7bdb1',300,'center');g.restore();
  chrome(g,0,t);bottom(g,0,t);
}
function s1(g,t){
  const chars=[...'你，继续专注。'];g.font='600 143px PingFang SC, sans-serif';const widths=chars.map(c=>g.measureText(c).width),sum=widths.reduce((a,b)=>a+b,0);let x=(W-sum)/2;
  chars.forEach((c,i)=>{const p=back((t-.10-i*.10)/.45);g.save();g.globalAlpha=clamp(p);g.translate(x+widths[i]/2,510+130*(1-p));g.rotate((1-p)*(i%2?-.15:.15));text(g,c,0,0,143,i===3?P.mint:P.white,600,'center','PingFang SC, sans-serif');g.restore();x+=widths[i]});
  const p=out((t-.7)/.55);line(g,270,573,270+1380*p,573,'#79f2b565',2);tracked(g,'LET YOUR AGENTS WORK.',960,648,34,8,'#a5beb1','center');
  for(let i=0;i<4;i++){const x=735+i*150,en=out((t-.45-i*.09)/.45);g.save();g.globalAlpha=en;mark(g,x,720+22*(1-en),44,['C','CL','W','D'][i],i%2?P.ice:P.mint);g.restore()}
  chrome(g,1,t);g.save();g.globalAlpha=out((t-.35)/.5);text(g,'少一次切换，多一分心流。',960,881,36,'#b6c7c3',300,'center');g.restore();
}
function s2(g,t){
  let stage=t<.65?0:t<1.3?1:2;const p=out(((t% .65)-.03)/.36);let w=stage===0?mix(240,365,p):stage===1?mix(365,650,p):mix(650,810,p);let h=stage===2?mix(78,350,p):78;
  rr(g,265,225,1390,495,29,'#14201f','#365249',1.5);
  for(let i=0;i<3;i++){rr(g,318+i*430,390,360,265,15,i===0?'#182623':'#17221f','#2b3d34');text(g,['写代码','查资料','整理工作'][i],344+i*430,438,24,'#91a69d');for(let k=0;k<5;k++)rr(g,344+i*430,477+k*24,240-(k%3)*40,5,2,'#33483e')}
  island(g,960,225,w,h,t,stage===0?'small':stage===1?'medium':'detail');
  const names=['最小态','事件态','悬停详情'];names.forEach((n,i)=>{const xx=635+i*325;circle(g,xx-73,750,4,i===stage?P.mint:'#486052');text(g,n,xx,760,24,i===stage?P.white:P.muted,400,'center')});
  chrome(g,2,t);bottom(g,2,t);
}
function bez(p,a,b){return 3*(1-p)*(1-p)*p*a+3*(1-p)*p*p*b+p*p*p}
function s3(g,t){
  const x=320,y=240,w=690,h=430;
  for(let i=0;i<=4;i++){line(g,x+i*w/4,y,x+i*w/4,y+h,'#293a33');line(g,x,y+i*h/4,x+w,y+i*h/4,'#293a33')}
  text(g,'RESPONSE / POSITION',320,206,21,P.muted,400,'left','Menlo, monospace');
  const a=[.18,.92],b=[.26,1];line(g,x,y+h,x+a[0]*w,y+(1-a[1])*h,'#84dbf365',2);line(g,x+w,y,x+b[0]*w,y+(1-b[1])*h,'#84dbf365',2);
  [a,b].forEach(k=>circle(g,x+k[0]*w,y+(1-k[1])*h,10,P.bg,P.ice,3));
  const draw=out(t/.5);g.beginPath();for(let i=0;i<=100*draw;i++){let p=i/100;let xx=x+bez(p,a[0],b[0])*w,yy=y+h-bez(p,a[1],b[1])*h;i?g.lineTo(xx,yy):g.moveTo(xx,yy)}g.strokeStyle=P.mint;g.lineWidth=5;g.stroke();
  const cycle=(t%.75)/.75,progress=expo(cycle);circle(g,x+cycle*w,y+h-progress*h,14,P.white);line(g,x+cycle*w,y+h-progress*h,x+cycle*w,y+h,'#79f2b530',1);
  rr(g,1160,250,500,400,26,'#14211b','#365340');text(g,'PRECISION IN MOTION',1200,305,24,P.mint,500);text(g,'轻盈，并非轻率。',1200,385,41,P.white,500);
  island(g,1410,452,220+260*progress,70,t,'small');text(g,'响应快，收起稳。',1410,594,25,'#a9c2b4',300,'center');
  chrome(g,3,t);bottom(g,3,t);
}
function s4(g,t){
  const p=out((t-.06)/1.14),depart=smooth((t-1.65)/.35)*.1;
  g.save();g.globalCompositeOperation='lighter';
  for(let i=0;i<9000;i++){const d=dots[i],tr=particleTargets[i],ox=960+Math.cos(d.a+t*.15)*(260+d.r*720),oy=485+Math.sin(d.a+t*.15)*(180+d.z*470);let x=mix(ox,tr[0],p),y=mix(oy,tr[1],p);x+=(x-960)*depart;y+=(y-490)*depart;g.globalAlpha=.35+d.s*.6;g.fillStyle=i%7===0?P.ice:P.mint;let r=1+d.s*1.1;g.fillRect(x,y,r,r)}g.restore();
  text(g,'9,000 SIGNALS. ONE FOCUS.',960,678,25,'#91c0a9',400,'center','Menlo, monospace');
  chrome(g,4,t);bottom(g,4,t);
}
function s5(g,t){
  const rot=t*.65+.4,c=Math.cos(rot),s=Math.sin(rot),rotX=-.2+Math.sin(t)*.12;
  const pts=cloud.map(d=>{let x=d.x*c+d.z*s,z=-d.x*s+d.z*c,y=d.y*Math.cos(rotX)-z*Math.sin(rotX);z=d.y*Math.sin(rotX)+z*Math.cos(rotX);const sc=900/(1100+z*350);return {x:1220+x*385*sc,y:460+y*385*sc,z,k:d.k}}).sort((a,b)=>b.z-a.z);
  g.save();g.globalCompositeOperation='lighter';pts.forEach(d=>{g.globalAlpha=.13+(1-d.z)*.27;g.fillStyle=d.k>.15?P.mint:P.ice;circle(g,d.x,d.y,1.2+(1-d.z)*.8,g.fillStyle)});g.restore();
  topTitle(g,'不是猜测。',100,355,t,96);topTitle(g,'是事件。',100,472,t-.17,96);
  const rows=['任务开始','执行事件','本轮已结束'];rows.forEach((s,i)=>{const en=out((t-.25-i*.14)/.5);g.save();g.globalAlpha=en;circle(g,126,582+i*47,5,P.mint);text(g,s,151,591+i*47,25,'#b2c7bc',300);g.restore()});
  chrome(g,5,t);bottom(g,5,t);
}
function s6(g,t){
  const blobs=Array.from({length:4},(_,i)=>({x:245+Math.cos(t*1.7+i*1.55)*(55+18*Math.sin(t*1.2)),y:122+Math.sin(t*1.35+i*1.8)*32,r:29+i*2}));
  const ar=metaImage.data;
  for(let y=0;y<270;y++)for(let x=0;x<480;x++){
    let f=0,gx=0,gy=0;for(const b of blobs){let dx=x-b.x,dy=y-b.y,d=dx*dx+dy*dy+30,r=b.r*b.r;f+=r/d;gx-=2*r*dx/(d*d);gy-=2*r*dy/(d*d)}
    const k=(y*480+x)*4;if(f>.94){const e=clamp((f-.94)*12),l=clamp(.55+(-gx-gy)*4),rim=Math.exp(-Math.abs(f-1)*8),spec=Math.pow(l,5);ar[k]=30+75*l+100*spec+40*rim;ar[k+1]=90+105*l+55*spec+20*rim;ar[k+2]=73+87*l+70*spec+30*rim;ar[k+3]=255*e}else{ar[k]=ar[k+1]=ar[k+2]=ar[k+3]=0}
  }metaCtx.putImageData(metaImage,0,0);g.drawImage(metaCanvas,0,30,W,H);
  const en=out((t-.1)/.4);g.save();g.globalAlpha=en;tracked(g,'A SIGNAL, NOT A DISTRACTION.',960,290,24,5,P.white,'center');g.restore();
  island(g,960,623,570,76,t,'medium','Claude',t<1?'处理中':'本轮已结束');
  chrome(g,6,t);bottom(g,6,t);
}
function s7(g,t){
  const dark=P.bg;const en=out(t/.42);
  for(let i=0;i<18;i++)for(let j=0;j<7;j++){const x=330+i*76,y=249+j*64,dis=Math.hypot(i-8,j-3),wave=Math.sin(dis*.6-t*4),h=10+30*(wave+1);g.save();g.globalAlpha=en;rr(g,x,y-h*.25,30,30+h,5,(i+j)%7===0?'#64c69b':dark);g.restore()}
  text(g,'01',93,295,30,'#506e60',500,'left','Menlo, monospace');text(g,'CODE',93,335,28,dark,600);text(g,'02',93,480,30,'#506e60',500,'left','Menlo, monospace');text(g,'RESEARCH',93,520,28,dark,600);
  rr(g,1510,250,250,455,18,'#e4eee7','#c5d7cb');['Codex','Claude','Work Buddy'].forEach((n,i)=>{text(g,n,1544,326+i*129,26,dark,500);text(g,['写代码','查资料','整理工作'][i],1544,367+i*129,23,'#557465',300)});
  line(g,92,754,1828,754,'#bbcfc1',2);chrome(g,7,t,true);bottom(g,7,t,true);
}
function s8(g,t){
  const a=Math.max(0,1-t/.55),active=t<.50||t>1.50&&t<1.67;
  if(active){g.save();g.globalAlpha=.35;for(let i=0;i<14;i++){let yy=210+i*37,shift=Math.sin(i*6+t*25)*(45*a+15);rr(g,480+shift,yy,900,3+(i%3)*2,0,i%2?P.mint:P.ice)}g.restore()}
  const shift=active?Math.sin(t*82)*7:0;
  rr(g,540+shift,243,840,440,32,'#111d19','#406b55',2);mark(g,605,301,48,'CL');text(g,'Claude Code',650,310,29,P.white,500);text(g,'单次审批演示',1327,309,20,P.muted,400,'right');
  text(g,'需要你的确认',596+shift,418,56,P.white,500);text(g,'核对完整参数后，再允许这一次。',598,474,26,'#afc9ba',300);
  const en=out((t-.35)/.5);g.save();g.globalAlpha=en;rr(g,600,548,347,70,35,'#79f2b519','#79f2b590',1.5);text(g,'仅允许这一次',773,594,26,P.mint,500,'center');rr(g,984,548,347,70,35,'#17251e','#446053',1.5);text(g,'回到原应用',1157,594,26,'#d9e7df',400,'center');g.restore();
  text(g,'Claude Code 中继需显式开启；其他 Agent 回原应用处理',960,741,22,P.muted,300,'center');
  chrome(g,8,t);bottom(g,8,t);
}
function s9(g,t){
  g.save();g.beginPath();g.rect(180,175,1560,550);g.clip();
  const z=Math.pow(2,(t*1.2)%1),base=920;
  for(let k=-1;k<=6;k++){const sc=z/Math.pow(2,k),w=base*sc;if(w<12||w>17000)continue;g.save();g.translate(960,450);g.scale(sc,sc);rr(g,-base/2,-265,base,530,32,'#111c18','#416b53',1.7/sc);notchPath(g,-130,-265,260,38);g.fillStyle='#020404';g.fill();for(let i=0;i<3;i++){rr(g,-395,-150+i*128,790,83,13,'#1c2b22');circle(g,-354,-109+i*128,13,[P.mint,P.ice,'#93ae9c'][i]);line(g,-318,-109+i*128,257,-109+i*128,'#4a6352',4)}g.restore()}
  g.restore();
  const en=out((t-.15)/.6);g.save();g.globalAlpha=en;rr(g,1420,538,280,101,21,'#14271e','#79f2b555',1.5);text(g,'0.2',1450,608,70,P.mint,500);text(g,'秒',1603,608,30,P.white,400);g.restore();
  circle(g,990,440,13,P.white);line(g,983,425,983,446,P.bg,2);line(g,983,446,996,435,P.bg,2);
  chrome(g,9,t);bottom(g,9,t);
}
function iso(x,z,y=0){return [960+(x-z)*.866,626+(x+z)*.43-y]}
function poly(g,points,fill,stroke=null){g.beginPath();points.forEach((p,i)=>i?g.lineTo(...p):g.moveTo(...p));g.closePath();g.fillStyle=fill;g.fill();if(stroke){g.strokeStyle=stroke;g.lineWidth=1;g.stroke()}}
function building(g,x,z,w,d,h,col){const a=iso(x,z,0),b=iso(x+w,z,0),c=iso(x+w,z+d,0),dd=iso(x,z+d,0),at=iso(x,z,h),bt=iso(x+w,z,h),ct=iso(x+w,z+d,h),dt=iso(x,z+d,h);poly(g,[a,b,bt,at],'#1c3126','#406a50');poly(g,[b,c,ct,bt],'#284934','#416f51');poly(g,[at,bt,ct,dt],col,'#8db79d');for(let yy=20;yy<h-15;yy+=28){let p=iso(x+w,z+12,yy),q=iso(x+w,z+d-12,yy);line(g,...p,...q,'#7cb99766',2)}}
function s10(g,t){
  const en=out(t/.5);g.save();g.translate(0,35*(1-en));g.globalAlpha=en;
  for(let k=-5;k<=5;k++){const a=iso(k*96,-500),b=iso(k*96,500),c=iso(-500,k*96),d=iso(500,k*96);line(g,...a,...b,'#233a2e');line(g,...c,...d,'#233a2e')}
  const houses=[[-280,-190,100,100,130],[-65,-285,110,95,205],[135,-180,105,105,150],[-290,75,110,100,100],[-65,25,150,150,255],[220,60,95,115,125]];
  houses.sort((a,b)=>a[0]+a[1]-b[0]-b[1]);houses.forEach((d,i)=>building(g,...d.slice(0,4),d[4]*out((t-i*.06)/.55),i===3?'#79f2b5':'#365d44'));
  const pts=[iso(-210,-130,135),iso(0,-220,210),iso(185,-130,160),iso(-230,120,110),iso(10,100,265),iso(260,110,140)];
  g.beginPath();pts.forEach((p,i)=>i?g.lineTo(...p):g.moveTo(...p));g.strokeStyle='#84dbf399';g.lineWidth=2;g.setLineDash([6,8]);g.stroke();g.setLineDash([]);pts.forEach((p,i)=>circle(g,p[0],p[1],5+pulse(t-i*.1)*4,P.mint));g.restore();
  island(g,960,205,520,74,t,'medium','Codex','3 项进行中');
  chrome(g,10,t);bottom(g,10,t);
}
function s11(g,t){
  const en=out(t/.70);g.save();g.translate(1215,449);g.beginPath();
  for(let i=0;i<=Math.floor(5000*en);i++){let p=i/5000,u=p*TAU*13,decay=Math.exp(-p*1.15);let x=(Math.sin(u*2+t*.18)*330+Math.sin(u*2.015+1.3)*106)*decay;let y=(Math.sin(u*3+Math.PI/2)*230+Math.sin(u*3.018+.3+t*.15)*70)*decay;i?g.lineTo(x,y):g.moveTo(x,y)}
  g.strokeStyle=P.mint;g.lineWidth=1.45;g.shadowColor='#79f2b54f';g.shadowBlur=7;g.stroke();g.restore();
  for(let i=0;i<4;i++){const x=300+i*430,p=smooth((t-i*.12)/.55);g.save();g.globalAlpha=p;line(g,x,616,x,703,'#3c5c49');circle(g,x,617,7,P.white);text(g,['任务开始','步骤返回','需要关注','本轮结束'][i],x,751,25,P.white,400,'center');text(g,['START','STEP','ATTENTION','END'][i],x,793,18,P.muted,400,'center','Menlo, monospace');g.restore()}
  text(g,'24',375,414,147,P.white,500,'center');tracked(g,'HOUR WINDOW',375,467,21,4,P.muted,'center');text(g,'工作的轨迹',375,551,33,'#b6c7c3',300,'center');
  chrome(g,11,t);bottom(g,11,t);
}
function recapIndex(t){const cuts=[0,.5,1,1.5];const shots=[4,2,5,10];let i=0;for(let k=0;k<cuts.length;k++)if(t>=cuts[k])i=k;return [shots[i],cuts[i]]}
function s12(g,t){
  if(t<1.5){const [shot,start]=recapIndex(t);renderScene(g,shot,.7+(t-start)*(1.5+start*2),false);g.save();rr(g,710,417,500,160,26,'#090c0eef','#79f2b540');text(g,['看见','专注','掌控'][Math.min(2,Math.floor(t/.5))],960,524,83,P.white,600,'center');g.restore();chrome(g,12,t)}
  else {bg(g,26);const p=out((t-1.5)/.5);text(g,'所有工作，汇于一处。',960,491,70,P.white,500,'center');ball(g,960,680-75*p,17);tracked(g,'ONE ISLAND. YOUR CONTROL.',960,760,23,6,P.muted,'center');chrome(g,12,t)}
}
function outro(g,t){
  const en=out((t-.06)/.62);g.save();g.globalAlpha=en;g.translate(0,30*(1-en));
  brand(g,960,356,190);tracked(g,'AGENT DYNAMIC ISLAND',960,672,28,6,P.muted,'center');text(g,'你的 Agent 管家',960,759,37,'#b9cfc1',300,'center');g.restore();
  const title='Agent 灵动岛';g.font='600 103px Helvetica Neue, PingFang SC, sans-serif';const tw=g.measureText(title).width;const titleX=(W-(tw+52))/2;g.save();g.globalAlpha=en;text(g,title,titleX,577,103,P.white,600);g.restore();
  const dotX=titleX+tw+29,fall=clamp((t-.10)/.88),y=mix(125,565,fall*fall);const landed=fall>=1;const squash=landed?Math.sin(Math.min((t-.98)*12,Math.PI))*Math.exp(-(t-.98)*10):0;
  ball(g,dotX,y,12,1+Math.max(0,squash)*.3,1-Math.max(0,squash)*.25);
  if(t>=.98){const ring=clamp((t-.98)/.6);g.save();g.globalAlpha=(1-ring)*.3;circle(g,dotX,565,16+ring*84,null,P.mint,1.5);g.restore()}
  const pp=smooth((t-1.35)/.65);g.save();g.globalAlpha=pp;line(g,630,834,1290,834,'#314d3b');text(g,'轻量感知   /   多 Agent 总览   /   用户掌控',960,885,24,'#8aa994',300,'center');text(g,'macOS · Alpha   |   BILL / AI NATIVE EXPERIENCE',960,997,18,P.muted,400,'center','Menlo, monospace');g.restore();
}
const scenes=[s0,s1,s2,s3,s4,s5,s6,s7,s8,s9,s10,s11,s12];
function renderScene(g,i,t,base=true){if(base)bg(g,i*2+t,i===7);else bg(g,i*2+t,i===7);g.save();scenes[i](g,t);g.restore()}
/* 12 distinct compositing transitions; each begins at an exact bar boundary.
   Incoming and outgoing are generated from their own local t, not prior frames. */
function composite(g,old,newer,kind,p){
  const q=smooth(p);g.drawImage(old,0,0);
  g.save();
  switch(kind){
    case 0: g.beginPath();g.arc(1420,530,2400*q,0,TAU);g.clip();g.drawImage(newer,0,0);break;
    case 1: g.clearRect(0,0,W,H);g.drawImage(old,-W*q,0);g.drawImage(newer,W*(1-q),0);break;
    case 2: g.drawImage(newer,0,0);g.translate(W/2,H/2);g.scale(1-q,1);g.drawImage(old,-W/2,-H/2);break;
    case 3: g.beginPath();g.moveTo(0,0);g.lineTo(W*q*2,0);g.lineTo(W*q*2-H*.5,H);g.lineTo(0,H);g.closePath();g.clip();g.drawImage(newer,0,0);break;
    case 4: g.translate(W/2,H/2);g.scale(1+q*1.3,1+q*1.3);g.globalAlpha=1-q;g.drawImage(old,-W/2,-H/2);g.restore();g.save();g.globalAlpha=q;g.drawImage(newer,0,0);break;
    case 5: g.globalAlpha=q;g.filter=`blur(${(1-q)*10}px)`;g.drawImage(newer,0,0);break;
    case 6: for(let k=0;k<7;k++){g.save();g.beginPath();g.arc(180+k*260,540+Math.sin(k*2)*155,800*q,0,TAU);g.clip();g.drawImage(newer,0,0);g.restore()}break;
    case 7: for(let k=0;k<8;k++){let z=clamp(p*1.5-k*.07);if(z>0)g.drawImage(newer,k*240,0,240,H,k*240,0,240,H*z)}break;
    case 8: for(let k=0;k<18;k++){let y=k*60,dx=(1-q)*(k%2?W:-W);g.drawImage(newer,0,y,W,60,dx,y,W,60)}break;
    case 9: g.beginPath();g.roundRect(W/2-100-1100*q,0,200+2200*q,100+1200*q,50);g.clip();g.drawImage(newer,0,0);break;
    case 10: g.drawImage(newer,0,0);g.translate(W*q,H*q*.35);g.globalAlpha=1-q*.4;g.drawImage(old,0,0);break;
    case 11: g.beginPath();g.rect(0,0,W*q,H);g.clip();g.drawImage(newer,0,0);line(g,W*q,0,W*q,H,P.mint,4);break;
  }g.restore();
}
window.render=function(t){
  t=clamp(Number(t),0,30-1/30);ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=1;ctx.globalCompositeOperation='source-over';ctx.filter='none';
  if(t>=26){bg(ctx,t);outro(ctx,t-26);return}
  let i=Math.floor(t/2),local=t-i*2;renderScene(B,i,local);
  if(i>0&&local<.24){renderScene(A,i-1,1.999);composite(ctx,layerA,layerB,i-1,local/.24)}else ctx.drawImage(layerB,0,0);
};
window.filmReady=(async()=>{
  await document.fonts.ready;
  const mask=document.createElement('canvas');mask.width=W;mask.height=H;const m=mask.getContext('2d');
  m.fillStyle=P.white;m.font='700 215px Helvetica Neue, sans-serif';m.textAlign='center';m.fillText('ONE ISLAND',960,563);
  const pixels=m.getImageData(0,0,W,H).data,targets=[];for(let y=330;y<590;y+=3)for(let x=220;x<1700;x+=3)if(pixels[(y*W+x)*4+3]>180)targets.push([x,y]);
  const pick=rng(9000);particleTargets=Array.from({length:9000},()=>{const p=targets[Math.floor(pick()*targets.length)];return [p[0]+(pick()-.5)*3,p[1]+(pick()-.5)*3]});
  window.render(0);return {width:W,height:H,frames:900,fps:30,particles:particleTargets.length,deterministic:true};
})();
