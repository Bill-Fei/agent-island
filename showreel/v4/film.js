/* Agent 灵动岛 V4 — one continuous camera over one Mac.
   render(t) is a pure function of time: no timers, no randomness, no accumulated state.
   UI is redrawn as vectors from the real product layout; task copy is demo content. */
'use strict';
const W=1920,H=1080,TAU=Math.PI*2;
const canvas=document.getElementById('film'),ctx=canvas.getContext('2d',{alpha:false});
// Device scale (?scale=2 renders 3840x2160): the film is authored in 1920x1080 units, so every
// absolute transform, shadow and blur — the only device-pixel quantities — is multiplied by DS.
const DS=Math.max(1,Number(new URLSearchParams(location.search).get('scale'))||1);
if(DS!==1){
  canvas.width=W*DS;canvas.height=H*DS;
  const P=CanvasRenderingContext2D.prototype,st=P.setTransform;
  ctx.setTransform=function(a,b,c,d,e,f){return st.call(this,a*DS,b*DS,c*DS,d*DS,e*DS,f*DS)};
  for(const k of ['shadowBlur','shadowOffsetX','shadowOffsetY']){const pd=Object.getOwnPropertyDescriptor(P,k);
    Object.defineProperty(ctx,k,{get(){return pd.get.call(this)/DS},set(v){pd.set.call(this,v*DS)}})}
  const fd=Object.getOwnPropertyDescriptor(P,'filter');
  Object.defineProperty(ctx,'filter',{get(){return fd.get.call(this)},
    set(v){fd.set.call(this,String(v).replace(/blur\(([\d.]+)px\)/g,(_,n)=>`blur(${(n*DS).toFixed(2)}px)`))}});
}
const FONT='system-ui, -apple-system, "PingFang SC", sans-serif';
const MONO='"SF Mono", Menlo, monospace';
const C={ink:'#16201c',ink2:'#5d6763',stage:'#eeeeea',obs:'#090c0e',porc:'#f7f7f4',mint:'#79f2b5',ice:'#84dbf3',muted:'#7f9292',
  info:'#8aaee8',attn:'#e8b080',ok:'#87c7ab',danger:'#e08f97',
  codex:'#7aa8ff',claude:'#ad7dff',doubao:'#ff6e47',workbuddy:'#33d69e'};

const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),mix=(a,b,p)=>a+(b-a)*p;
const seg=(t,a,b)=>clamp((t-a)/(b-a));
const smooth=x=>{x=clamp(x);return x*x*(3-2*x)};
const ease=x=>{x=clamp(x);return x<.5?4*x*x*x:1-Math.pow(-2*x+2,3)/2};
const out=x=>1-Math.pow(1-clamp(x),3);
const out5=x=>1-Math.pow(1-clamp(x),5);
const back=x=>{x=clamp(x);const c=1.6;return 1+(c+1)*Math.pow(x-1,3)+c*Math.pow(x-1,2)};
const spring=x=>{x=clamp(x);return x>=1?1:1-Math.exp(-6.5*x)*Math.cos(10*x)};
const lerpRect=(a,b,p)=>({x:mix(a.x,b.x,p),y:mix(a.y,b.y,p),w:mix(a.w,b.w,p),h:mix(a.h,b.h,p)});

const IMG={};
const NAMES=['codex','claude','doubao','workbuddy','finder','safari','messages','notes','photos','settings','trash'];
const AGENTS={codex:{name:'Codex',color:C.codex},claude:{name:'Claude',color:C.claude},
  doubao:{name:'豆包',color:C.doubao},workbuddy:{name:'Work Buddy',color:C.workbuddy}};

function T(g,s,x,y,size,color,weight=400,align='left',font=FONT){
  g.font=`${weight} ${size}px ${font}`;g.fillStyle=color;g.textAlign=align;g.textBaseline='alphabetic';g.fillText(s,x,y);
}
function tw(g,s,size,weight=400,font=FONT){g.font=`${weight} ${size}px ${font}`;return g.measureText(s).width}
function rr(g,x,y,w,h,r,fill,stroke=null,lw=1){g.beginPath();g.roundRect(x,y,w,h,r);if(fill){g.fillStyle=fill;g.fill()}if(stroke){g.strokeStyle=stroke;g.lineWidth=lw;g.stroke()}}
function circle(g,x,y,r,fill,stroke=null,lw=1){g.beginPath();g.arc(x,y,Math.max(.01,r),0,TAU);if(fill){g.fillStyle=fill;g.fill()}if(stroke){g.strokeStyle=stroke;g.lineWidth=lw;g.stroke()}}
function alpha(g,a,fn){if(a<=0.001)return;g.save();g.globalAlpha*=clamp(a);fn();g.restore()}
function icon(g,name,cx,cy,size){g.drawImage(IMG[name],cx-size/2,cy-size/2,size,size)}

/* Same contour as LinglongtaiBrandMark.swift: the notch, with concave top shoulders. */
function notchPath(g,cx,top,bodyW,h,sh,r){
  const minX=cx-bodyW/2-sh,maxX=cx+bodyW/2+sh,maxY=top+h,left=minX+sh,right=maxX-sh;
  r=Math.min(r,h-sh,bodyW/2);
  g.beginPath();g.moveTo(minX,top);
  g.quadraticCurveTo(left,top,left,top+sh);
  g.lineTo(left,maxY-r);g.quadraticCurveTo(left,maxY,left+r,maxY);
  g.lineTo(right-r,maxY);g.quadraticCurveTo(right,maxY,right,maxY-r);
  g.lineTo(right,top+sh);g.quadraticCurveTo(right,top,maxX,top);g.closePath();
}
function brandMark(g,cx,cy,size,signalMix=1){
  const w=size*.92,h=size*.5,sh=w*.12;
  notchPath(g,cx,cy-h/2,w-2*sh,h,sh,h*.35);g.fillStyle='#0a0c0d';g.fill();
  const gr=g.createLinearGradient(0,cy-h/2,0,cy+h/2);gr.addColorStop(0,'#f7fcf7');gr.addColorStop(1,'#999e99');
  g.strokeStyle=gr;g.lineWidth=size*.06;g.stroke();
  const sw=size*.07,cols=[C.mint,C.porc,C.ice],hs=[.16,.25,.12];
  for(let i=0;i<3;i++){const x=cx+(i-1)*sw*2,hh=size*hs[i];rr(g,x-sw/2,cy+size*.028-hh/2,sw,hh,sw/2,cols[i])}
}

/* ---------------- camera ---------------- */
const CAMS={P:{s:.68,x:256,y:520},W:{s:1.0,x:360,y:480},P2:{s:.75,x:302.7,y:520},N:{s:2.6,x:756,y:140},O:{s:1.62,x:756,y:275},Z:{s:2.4,x:756,y:16.5}};
const CAM_KEYS=[[0,'P'],[6.3,'P'],[7.9,'N'],[14.6,'N'],[15.7,'O'],[20.3,'O'],[21.5,'W'],[22.95,'W'],[24.1,'P'],[24.85,'P2'],[25.75,'Z']];
let CAM_S=1;
function rawCamera(t){
  let a=CAM_KEYS[CAM_KEYS.length-1],b=a;
  for(let i=0;i<CAM_KEYS.length-1;i++)if(t>=CAM_KEYS[i][0]&&t<CAM_KEYS[i+1][0]){a=CAM_KEYS[i];b=CAM_KEYS[i+1];break}
  const A=CAMS[a[1]],B=CAMS[b[1]],p=a===b?0:ease(seg(t,a[0],b[0]));
  let s=Math.exp(mix(Math.log(A.s),Math.log(B.s),p));
  // Push into the island: it glides in a straight line to frame centre while growing,
  // landing exactly on the end-card mark (scale 2.4, centred) so the cut becomes a match.
  if(b[1]==='Z'&&a!==b){const fx=W/2+(B.x-A.x)*A.s,fy=H/2+(B.y-A.y)*A.s;
    return {ls:Math.log(s),x:B.x-(mix(fx,W/2,p)-W/2)/s,y:B.y-(mix(fy,H/2,p)-H/2)/s};}
  // slow breathing drift on every hold, so the camera never fully parks
  s*=1+.03*seg(t,2.45,6.3)*(1-seg(t,6.3,7.9));
  s*=1+.035*seg(t,7.9,14.6)*(1-seg(t,14.6,15.7));
  s*=1+.025*seg(t,15.7,20.3)*(1-seg(t,20.3,21.7));
  s*=1+.02*seg(t,21.5,22.95)*(1-seg(t,22.95,24.1));
  return {ls:Math.log(s),x:mix(A.x,B.x,p),y:mix(A.y,B.y,p)};
}
// Gaussian blur of the camera path over time: moves blend into each other
// instead of starting/stopping on a keyframe. Still a pure function of t.
const CAM_TAPS=(()=>{const taps=[];let sum=0;for(let k=-10;k<=10;k++){const w=Math.exp(-(k*k)/(2*4.2*4.2));taps.push([k*.04,w]);sum+=w}
  return taps.map(([d,w])=>[d,w/sum])})();
function camera(t){
  let ls=0,x=0,y=0;
  for(const [d,w] of CAM_TAPS){const c=rawCamera(clamp(t+d,0,25.75));ls+=c.ls*w;x+=c.x*w;y+=c.y*w}
  // hand over to the exact path for the final push, so the landing is pixel-exact
  const r=rawCamera(clamp(t,0,25.75)),k=smooth(seg(t,25.0,25.45));
  return {s:Math.exp(mix(ls,r.ls,k)),x:mix(x,r.x,k),y:mix(y,r.y,k)};
}
const toScreen=(cam,x,y)=>({x:W/2+(x-cam.x)*cam.s,y:H/2+(y-cam.y)*cam.s});

/* ---------------- desktop ---------------- */
const SW=1512,SH=982,NX=756;
const DOCK=['finder','safari','messages','notes','photos','settings','|','codex','claude','doubao','workbuddy','|','trash'];
const DOCK_POS=(()=>{const size=46,gap=10,sep=21;let wsum=0;DOCK.forEach((n,i)=>{wsum+=n==='|'?sep:size;if(i<DOCK.length-1)wsum+=gap});
  let x=NX-wsum/2;const pos={};DOCK.forEach(n=>{if(n==='|'){x+=sep+gap;return}pos[n]={x:x+size/2,y:940};x+=size+gap});
  pos._w=wsum;return pos})();
const dockRect=n=>({x:DOCK_POS[n].x-23,y:DOCK_POS[n].y-23,w:46,h:46});

function wallpaper(g){
  let lg=g.createLinearGradient(0,0,SW,SH);lg.addColorStop(0,'#a9b6a5');lg.addColorStop(.55,'#c9d1c3');lg.addColorStop(1,'#e2e5dc');
  g.fillStyle=lg;g.fillRect(0,0,SW,SH);
  g.save();g.shadowColor='rgba(55,70,55,.22)';g.shadowBlur=70*CAM_S;g.shadowOffsetY=18*CAM_S;
  g.beginPath();g.moveTo(-40,-40);g.lineTo(SW+40,-40);g.lineTo(SW+40,70);g.bezierCurveTo(1160,420,700,560,-40,470);g.closePath();
  let a=g.createLinearGradient(0,0,1300,620);a.addColorStop(0,'#c0c9ba');a.addColorStop(1,'#eceee8');g.fillStyle=a;g.fill();
  g.beginPath();g.moveTo(-40,640);g.bezierCurveTo(420,560,880,700,1260,SH+40);g.lineTo(-40,SH+40);g.closePath();
  let b=g.createLinearGradient(0,600,760,SH);b.addColorStop(0,'#f0f2ec');b.addColorStop(1,'#d2d8cd');g.fillStyle=b;g.fill();
  g.restore();
  let r=g.createRadialGradient(1120,300,0,1120,300,640);r.addColorStop(0,'rgba(255,255,255,.28)');r.addColorStop(1,'rgba(255,255,255,0)');
  g.fillStyle=r;g.fillRect(0,0,SW,SH);
}

function frontApp(t){
  if(t>=23.2)return '备忘录';
  if(t>=20.6&&t<23.2)return 'Codex';
  if(t>=2.45&&t<6.0){const f=topAgentWindow(t);return f?AGENTS[f].name:'Finder'}
  return 'Finder';
}
function menubar(g,t){
  g.fillStyle='rgba(246,248,243,.42)';g.fillRect(0,0,SW,32);
  g.fillStyle='rgba(0,0,0,.05)';g.fillRect(0,32,SW,1);
  T(g,'',20,22,16,'#1b2320',400);
  T(g,frontApp(t),48,21.5,13.5,'#1b2320',700);
  let x=48+tw(g,frontApp(t),13.5,700)+22;
  for(const s of ['文件','编辑','显示','前往','窗口','帮助']){T(g,s,x,21.5,13,'#1b2320',400);x+=tw(g,s,13)+20}
  const c='#1b2320';
  g.strokeStyle=c;g.lineWidth=1.6;g.lineCap='round';
  for(let i=0;i<3;i++){g.beginPath();g.arc(1300,22,4+i*3.6,-Math.PI*.75,-Math.PI*.25);g.stroke()}
  rr(g,1326,11,24,11,3,null,c,1.3);rr(g,1328.5,13.5,15,6,1.5,c);rr(g,1351,14.5,2,4,1,c);
  circle(g,1376,15.5,4.6,null,c,1.6);g.beginPath();g.moveTo(1379.5,19);g.lineTo(1383,22.5);g.stroke();
  rr(g,1396,10.5,16,5.5,2.75,null,c,1.3);rr(g,1396,17.5,16,5.5,2.75,null,c,1.3);
  T(g,'周四 21:04',1496,21.5,13,c,500,'right');
}
function dock(g,t){
  const w=DOCK_POS._w+20;
  g.save();g.shadowColor='rgba(40,50,45,.18)';g.shadowBlur=24*CAM_S;g.shadowOffsetY=6*CAM_S;
  rr(g,NX-w/2,910,w,60,18,'rgba(250,251,248,.42)');g.restore();
  rr(g,NX-w/2,910,w,60,18,null,'rgba(255,255,255,.62)',1);
  let sepX=[];
  DOCK.forEach((n,i)=>{if(n!=='|')return;const prev=DOCK_POS[DOCK[i-1]];sepX.push(prev.x+23+10+10)});
  sepX.forEach(x=>{g.fillStyle='rgba(30,40,35,.18)';g.fillRect(x,920,1,40)});
  for(const n of DOCK){if(n==='|')continue;
    if(AGENTS[n]&&t<2.45)continue;
    const p=DOCK_POS[n];icon(g,n,p.x,p.y-2,46);
    const running=AGENTS[n]?t>=2.45:(n==='finder'||(n==='notes'&&t>=23.15));
    if(running)circle(g,p.x,966,2,'rgba(25,32,29,.62)');
  }
}

/* ---------------- app windows ---------------- */
const WINS={
  codex:{x:140,y:120,w:620,h:420,user:'把数据库脚本迁移到新表结构',reply:['正在读取 schema.sql 与迁移记录','对比 12 张表的字段差异…'],status:'执行命令中'},
  claude:{x:540,y:170,w:620,h:420,user:'重构登录模块，拆分 session 逻辑',reply:['已修改 auth/session.ts 等 3 个文件','继续补充单元测试…'],status:'正在生成'},
  doubao:{x:290,y:380,w:560,h:390,user:'帮我找 5 个竞品的定价页',reply:['已找到 3 个，继续检索中','稍后整理成对比表格…'],status:'处理中'},
  workbuddy:{x:830,y:330,w:560,h:400,user:'整理本周周报素材',reply:['已汇总 12 条更新','正在按项目分组…'],status:'处理中'}
};
const ORDER=['codex','claude','doubao','workbuddy'];
const CLICKS=[[3.5,'codex'],[4.0,'claude'],[4.5,'doubao'],[5.0,'workbuddy'],[5.5,'codex']];
const openAt=k=>2.45+ORDER.indexOf(k)*.15;
function lastFront(k,t){let v=openAt(k);for(const [ct,n] of CLICKS)if(n===k&&t>=ct)v=ct;return v}
function topAgentWindow(t){let best=null,bv=-1;for(const k of ORDER){if(t<openAt(k))continue;const v=lastFront(k,t);if(v>bv){bv=v;best=k}}return best}

function windowFrame(g,w,h,title,iconName,focused){
  g.save();g.shadowColor='rgba(20,30,25,.24)';g.shadowBlur=(focused?44:26)*CAM_S;g.shadowOffsetY=(focused?16:8)*CAM_S;
  rr(g,0,0,w,h,12,'#fbfbf9');g.restore();
  rr(g,0,0,w,h,12,null,'rgba(0,0,0,.09)',1);
  g.fillStyle='rgba(0,0,0,.06)';g.fillRect(0,38,w,1);
  const lights=focused?['#ff5f57','#febc2e','#28c840']:['#d6d8d4','#d6d8d4','#d6d8d4'];
  lights.forEach((c,i)=>circle(g,18+i*20,19,6,c));
  icon(g,iconName,92,19,20);T(g,title,108,24,13.5,focused?C.ink:'#7c8581',600);
}
function spinner(g,x,y,r,t,color){g.beginPath();const a=t*TAU*1.15;g.arc(x,y,r,a,a+Math.PI*1.4);g.strokeStyle=color;g.lineWidth=2;g.lineCap='round';g.stroke()}
function chatBody(g,d,k,t,focused,mode){
  const w=d.w,h=d.h;
  g.font=`400 14px ${FONT}`;const uw=g.measureText(d.user).width;
  rr(g,w-24-uw-28,58,uw+28,36,18,'#eceee9');T(g,d.user,w-24-uw-14,81,14,'#25302b');
  icon(g,k,34,128,22);
  d.reply.forEach((s,i)=>T(g,s,56,133+i*24,14,'#3b4440'));
  if(mode==='perm'){permCard(g,w,t);}
  else{
    spinner(g,34,h-92,6.5,t,AGENTS[k].color);
    T(g,d.status,50,h-87,13,'#7a8480',500);
  }
  rr(g,20,h-62,w-40,42,14,'#f1f2ee',null);T(g,'继续输入…',38,h-36,13,'#a3aaa6');
}
function permCard(g,w,t){
  const y=196,h=150,x=24,cw=w-48,ok=t>=22.45;
  rr(g,x,y,cw,h,14,'#ffffff','rgba(0,0,0,.1)',1);
  if(!ok){
    circle(g,x+24,y+30,4,C.attn);T(g,'需要你的确认',x+36,y+35,15,C.ink,600);
    T(g,'Codex 请求执行命令',x+20,y+62,13,'#7a8480');
    const code='psql -f migrate_v2.sql';const cw2=tw(g,code,13,500,MONO);
    rr(g,x+20,y+76,cw2+20,28,7,'#f1f2ef');T(g,code,x+30,y+95,13,'#2d3632',500,'left',MONO);
    const press=1-.06*Math.sin(Math.PI*seg(t,22.36,22.5));
    rr(g,x+cw-164,y+h-46,68,32,9,'#eceee9');T(g,'拒绝',x+cw-130,y+h-24.5,13,C.ink,500,'center');
    g.save();g.translate(x+cw-52,y+h-30);g.scale(press,press);rr(g,-34,-16,68,32,9,'#17201d');T(g,'允许',0,5.5,13,'#fff',600,'center');g.restore();
  }else{
    const p=out(seg(t,22.45,22.8));
    alpha(g,p,()=>{
      circle(g,x+34,y+44,12,'rgba(135,199,171,.22)');
      g.beginPath();g.moveTo(x+28,y+44);g.lineTo(x+32.5,y+48.5);g.lineTo(x+40,y+39.5);g.strokeStyle='#3f9c78';g.lineWidth=2.2;g.lineCap='round';g.lineJoin='round';g.stroke();
      T(g,'已允许',x+56,y+50,15,C.ink,600);
      T(g,'继续执行迁移，完成后会在灵动岛里告诉你。',x+20,y+90,13,'#6d7773');
      rr(g,x+20,y+108,(cw-40)*mix(.08,.42,seg(t,22.6,23.2)),4,2,C.ok);
    });
  }
}
function tick(g,x,y,color){g.beginPath();g.moveTo(x-4,y);g.lineTo(x-1,y+3);g.lineTo(x+4.5,y-3.5);
  g.strokeStyle=color;g.lineWidth=1.8;g.lineCap='round';g.lineJoin='round';g.stroke()}
// Codex desktop layout for the approval beat: thread sidebar, header, tool log, approval, composer.
function codexBody(g,d,t){
  const w=d.w,h=d.h,sw=176,mx=sw+21,mw=w-sw-42;
  rr(g,0,39,sw,h-39,[0,0,0,12],'#f3f4f1');g.fillStyle='rgba(0,0,0,.06)';g.fillRect(sw,39,1,h-39);
  rr(g,12,52,sw-24,30,8,'#fbfbf9','rgba(0,0,0,.09)',1);T(g,'＋  新对话',26,72,12.5,'#38403c',500);
  T(g,'island-hud',16,110,11.5,'#8a918d',600);
  const ok=t>=22.45;
  rr(g,8,122,sw-16,46,8,'#e6eae5');
  T(g,'数据库迁移',20,142,13,C.ink,600);T(g,ok?'正在执行':'等待批准',20,159,11,'#7a8480');
  if(!ok)circle(g,sw-24,145,3.5,C.attn);else spinner(g,sw-24,145,4.5,t,C.codex);
  [['修复登录跳转','12 分钟前'],['补充 API 文档','昨天']].forEach(([a,b],i)=>{
    T(g,a,20,196+i*46,13,'#38403c',500);T(g,b,20,213+i*46,11,'#8a918d')});
  // header
  T(g,'数据库迁移到新表结构',mx,64,14,C.ink,600);
  const br='main',bw=tw(g,br,11.5,500,MONO)+30,bx=w-21-bw;
  rr(g,bx,50,bw,22,6,'#f1f2ef');g.beginPath();g.arc(bx+11,61,2.6,0,TAU);g.strokeStyle='#7a8480';g.lineWidth=1.3;g.stroke();
  T(g,br,bx+20,65.5,11.5,'#5d6763',500,'left',MONO);
  T(g,'~/island-hud',bx-10,65.5,11.5,'#9aa19d',400,'right',MONO);
  g.fillStyle='rgba(0,0,0,.06)';g.fillRect(sw+1,79,w-sw-1,1);
  // user turn
  const uw=tw(g,d.user,13.5);rr(g,w-21-uw-26,92,uw+26,32,16,'#eceee9');T(g,d.user,w-21-uw-13,113,13.5,'#25302b');
  // tool log
  icon(g,'codex',mx+8,148,18);
  tick(g,mx+30,147,'#3f9c78');T(g,'已读取 schema.sql 与 14 条迁移记录',mx+42,152,12.5,'#6d7773');
  tick(g,mx+30,171,'#3f9c78');const gl='已生成 migrate_v2.sql';T(g,gl,mx+42,176,12.5,'#6d7773');
  const dx=mx+42+tw(g,gl,12.5)+10;T(g,'+38',dx,176,12,'#3f9c78',600,'left',MONO);T(g,'−12',dx+tw(g,'+38',12,600,MONO)+6,176,12,'#d0574a',600,'left',MONO);
  T(g,'字段差异已核对，准备在本地数据库执行迁移。',mx+30,202,13.5,'#2f3834');
  // approval card
  const y=218,ch=128,x=mx,cw=mw;
  rr(g,x,y,cw,ch,12,'#ffffff','rgba(0,0,0,.1)',1);
  if(!ok){
    circle(g,x+20,y+24,3.5,C.attn);T(g,'需要你的批准',x+31,y+29,14,C.ink,600);T(g,'执行命令',x+cw-18,y+29,11.5,'#8a918d',500,'right');
    rr(g,x+16,y+42,cw-32,32,7,'#f4f5f2');
    T(g,'$',x+28,y+63,12.5,'#9aa19d',500,'left',MONO);T(g,'psql -d island_dev -f migrate_v2.sql',x+42,y+63,12.5,'#2d3632',500,'left',MONO);
    T(g,'影响 12 张表 · 已自动备份',x+18,y+107,12,'#7a8480');
    const press=1-.06*Math.sin(Math.PI*seg(t,22.36,22.5));
    rr(g,x+cw-152,y+86,64,30,8,'#eceee9');T(g,'拒绝',x+cw-120,y+106,12.5,C.ink,500,'center');
    g.save();g.translate(x+cw-50,y+101);g.scale(press,press);rr(g,-32,-15,64,30,8,'#17201d');T(g,'允许',0,5,12.5,'#fff',600,'center');g.restore();
  }else{
    const p=out(seg(t,22.45,22.8)),pr=mix(.08,.42,seg(t,22.6,23.2));
    alpha(g,p,()=>{
      circle(g,x+28,y+34,11,'rgba(135,199,171,.22)');tick(g,x+28,y+34.5,'#3f9c78');
      T(g,'已允许本次执行',x+48,y+39.5,14,C.ink,600);
      T(g,'完成后会在灵动岛里告诉你。',x+18,y+76,12.5,'#6d7773');
      rr(g,x+18,y+94,cw-36,4,2,'#eef0ec');rr(g,x+18,y+94,(cw-36)*pr,4,2,C.ok);
      T(g,`${Math.max(1,Math.round(pr*12))} / 12 张表`,x+cw-18,y+76,12,'#8a918d',500,'right');
    });
  }
  // composer
  const cy=h-76;rr(g,mx,cy,mw,60,14,'#ffffff','rgba(0,0,0,.1)',1);
  T(g,'继续追问 Codex…',mx+16,cy+24,13,'#a3aaa6');
  const m='GPT-5-Codex',mwid=tw(g,m,11,500)+26;rr(g,mx+12,cy+34,mwid,20,6,'#f1f2ef');T(g,m,mx+22,cy+48,11,'#5d6763',500);
  g.beginPath();g.moveTo(mx+12+mwid-12,cy+42);g.lineTo(mx+12+mwid-9,cy+45.5);g.lineTo(mx+12+mwid-6,cy+42);g.strokeStyle='#7a8480';g.lineWidth=1.2;g.stroke();
  rr(g,mx+20+mwid,cy+34,40,20,6,'#f1f2ef');T(g,'本地',mx+40+mwid,cy+48,11,'#5d6763',500,'center');
  circle(g,mx+mw-24,cy+42,12,'#d9dcd7');
  g.beginPath();g.moveTo(mx+mw-24,cy+48);g.lineTo(mx+mw-24,cy+36.5);g.moveTo(mx+mw-28.5,cy+41);g.lineTo(mx+mw-24,cy+36.5);g.lineTo(mx+mw-19.5,cy+41);
  g.strokeStyle='#fff';g.lineWidth=1.8;g.lineCap='round';g.stroke();
}
const NOTE={x:356,y:150,w:800,h:560};
const NOTE_LINES=['分析要点：','· 开通路径从 4 步压到 2 步，权益说明前置','· 连续包月需明确扣费提醒，避免客诉','· 待确认：是否先做 A/B 测试'];
function notesBody(g,t){
  const w=NOTE.w,h=NOTE.h;
  g.fillStyle='#f3f2ee';g.fillRect(0,39,190,h-39-12);rr(g,0,h-24,190,24,[0,0,0,12],'#f3f2ee');
  g.fillStyle='rgba(0,0,0,.06)';g.fillRect(190,39,1,h-39);
  rr(g,10,54,170,52,8,'#f2e3a3');
  T(g,'需求分析',22,76,13.5,C.ink,600);T(g,'21:06  会员中心 PRD',22,95,11.5,'#7a6f45');
  T(g,'周会记录',22,136,13.5,'#38403c',600);T(g,'昨天  评审结论',22,155,11.5,'#8a918d');
  T(g,'用户访谈',22,194,13.5,'#38403c',600);T(g,'周二  12 条反馈',22,213,11.5,'#8a918d');
  T(g,'PRD 分析 · 会员中心改版',228,96,26,C.ink,700);
  T(g,'2026 年 10 月 10 日 21:06  ·  来源：会员中心 PRD v1.3',228,124,12.5,'#8a918d');
  const chip='待评审',cw=tw(g,chip,11.5,600)+18,cx0=w-36-cw;
  rr(g,cx0,79,cw,22,11,'rgba(217,163,0,.14)');T(g,chip,cx0+cw/2,94.5,11.5,'#9a7400',600,'center');
  // quoted PRD excerpt with the key data point highlighted
  rr(g,228,146,w-264,78,10,'#f5f4ef');rr(g,228,146,3,78,1.5,'#d9a300');
  T(g,'原文 §3.2',246,172,12,'#9a7400',600,'left',MONO);
  T(g,'用户可在个人页一键开通会员，支持连续包月。',318,172,13.5,'#4a524e');
  const pre='数据：开通路径共 4 步，',hl='第 2 步流失 46%',x1=246+tw(g,pre,13.5);
  T(g,pre,246,204,13.5,'#4a524e');
  rr(g,x1-3,188,tw(g,hl,13.5,600)+6,22,4,'rgba(242,214,110,.55)');T(g,hl,x1,204,13.5,'#27302c',600);
  let n=Math.max(0,Math.floor((t-23.6)*40)),cx=228,cy=262;
  NOTE_LINES.forEach((ln,i)=>{const chars=[...ln];const k=Math.min(n,chars.length);n-=k;
    const s=chars.slice(0,k).join('');const y=262+i*34;
    T(g,s,228,y,17,'#27302c',i===0?600:400);
    if(k>0||i===0){cx=228+tw(g,s,17,i===0?600:400);cy=y}
  });
  if(Math.floor(t*2.2)%2===0)rr(g,cx+2,cy-17,2,21,1,'#d9a300');
}

function drawWindows(g,t){
  const list=[];
  if(t>=2.45&&t<6.8){
    ORDER.forEach((k,i)=>{const d=WINS[k],o=openAt(k),m=6.0+i*.07;
      const p=out5(seg(t,o,o+.5)),q=ease(seg(t,m,m+.5));
      if(t<o||q>=1)return;
      let r=lerpRect(dockRect(k),d,p);r=lerpRect(r,dockRect(k),q);
      list.push({k,d,r,a:seg(t,o,o+.12)*(1-seg(q,.75,1)),z:lastFront(k,t),mode:'chat'});
    });
  }
  if(t>=20.55&&t<23.5){const d={...WINS.codex,x:396,y:190,w:760,h:440};
    const p=out5(seg(t,20.55,21.1)),q=ease(seg(t,23.0,23.45));
    let r=lerpRect(dockRect('codex'),d,p);r=lerpRect(r,dockRect('codex'),q);
    list.push({k:'codex',d,r,a:seg(t,20.55,20.67)*(1-seg(q,.75,1)),z:20,mode:'perm'});
  }
  if(t>=23.15){const p=out5(seg(t,23.15,23.7));const r=lerpRect(dockRect('notes'),NOTE,p);
    list.push({k:'notes',d:NOTE,r,a:seg(t,23.15,23.27),z:23,mode:'notes'});
  }
  list.sort((a,b)=>a.z-b.z);
  const top=list.length?list[list.length-1]:null;
  for(const it of list){
    alpha(g,it.a,()=>{g.save();g.translate(it.r.x,it.r.y);g.scale(it.r.w/it.d.w,it.r.h/it.d.h);
      const focused=it===top;
      if(it.mode==='notes'){windowFrame(g,it.d.w,it.d.h,'备忘录','notes',true);notesBody(g,t)}
      else if(it.mode==='perm'){windowFrame(g,it.d.w,it.d.h,'Codex','codex',focused);codexBody(g,it.d,t)}
      else{windowFrame(g,it.d.w,it.d.h,AGENTS[it.k].name,it.k,focused);chatBody(g,it.d,it.k,t,focused,it.mode)}
      g.restore()});
  }
}

/* ---------------- the island ---------------- */
function island(t){
  const I={w:186,h:32,r:9,sh:6,small:0,med:0,pan:0};
  if(t<7.3)return I;
  const p0=seg(t,7.3,7.9),q=smooth(p0);
  I.w=mix(186,290,back(p0));I.h=mix(32,34,q);I.r=mix(9,12,q);I.sh=mix(6,7,q);I.small=seg(t,7.6,7.95);
  if(t>=10&&t<14){
    const e=spring(seg(t,10,10.7)),c=ease(seg(t,13.4,13.85));
    I.w=mix(mix(290,520,e),290,c)+10*Math.sin(Math.PI*seg(t,12,12.35));
    I.small=t<12?1-seg(t,10,10.12):seg(t,13.75,14);
    I.med=seg(t,10.22,10.48)*(1-seg(t,13.28,13.42));
  }
  if(t>=14.75&&t<21){
    const e=spring(seg(t,14.8,15.5)),eh=spring(seg(t,14.84,15.56)),c=ease(seg(t,20.25,20.7)),ch=out(seg(t,20.25,20.6));
    I.w=mix(mix(290,640,e),290,c);I.h=mix(mix(34,452,eh),34,ch);
    const k=clamp(mix(clamp(eh),0,ch));I.r=mix(12,30,k);I.sh=mix(7,10,k);
    I.small=t<17?1-seg(t,14.75,14.85):seg(t,20.7,20.95);
    I.pan=seg(t,15.1,15.3)*(1-seg(t,20.18,20.3));
  }
  return I;
}
function barHeights(t){const tt=Math.min(t,25.75);return [0,1,2].map(i=>5+8*(.5+.5*Math.sin(tt*TAU*[.83,1.21,1.04][i]+i*1.9)))}
function smallContent(g,t,I,cx){
  const x0=cx-I.w/2,x1=cx+I.w/2,cy=17;
  const agent=t<12.1?'claude':'codex';
  icon(g,agent,x0+21,cy,22);
  const bx=x1-31;rr(g,bx-22,cy-11,44,22,11,'rgba(255,255,255,.1)');
  barHeights(t).forEach((h,i)=>rr(g,bx-14+i*5,cy-h/2,3,h,1.5,'#cddaf3'));
  T(g,'4',bx+8,cy+4.6,12.5,'#f2f4f1',600,'center');
}
const EVENTS=[{agent:'claude',stack:['claude','codex','doubao'],title:'重构登录模块',status:'本轮结束',color:C.ok},
  {agent:'codex',stack:['codex','claude','workbuddy'],title:'数据库迁移',status:'待你确认',color:C.attn}];
function medContent(g,t,I,cx){
  const x0=cx-I.w/2,x1=cx+I.w/2,cy=17;
  const draw=(e,a,dy)=>alpha(g,a,()=>{
    for(let j=2;j>=0;j--)alpha(g,j?.6:1,()=>icon(g,e.stack[j],x0+21+j*9,cy+dy,22));
    T(g,e.title,x0+66,cy+5+dy,14,'#f5f6f3',600);
    const sw=tw(g,e.status,13,500);T(g,e.status,x1-20,cy+4.6+dy,13,e.color,500,'right');
    const dx=x1-20-sw-11;circle(g,dx,cy+dy,7*(.6+.4*Math.sin(t*TAU*.9)),e.color+'33');circle(g,dx,cy+dy,3.5,e.color);
  });
  draw(EVENTS[0],I.med*(1-seg(t,11.95,12.08)),-6*seg(t,11.95,12.08));
  if(t>=12.08)draw(EVENTS[1],I.med*seg(t,12.1,12.3),6*(1-out(seg(t,12.1,12.35))));
}
function clockIcon(g,x,y,c){circle(g,x,y,5.5,null,c,1.3);g.beginPath();g.moveTo(x,y-3);g.lineTo(x,y);g.lineTo(x+2.4,y+1.3);g.strokeStyle=c;g.lineWidth=1.3;g.stroke()}
function stepArrow(g,x,y,c){g.beginPath();g.moveTo(x,y-9);g.lineTo(x,y-4);g.quadraticCurveTo(x,y,x+4,y);g.lineTo(x+11,y);g.moveTo(x+8,y-3);g.lineTo(x+11,y);g.lineTo(x+8,y+3);
  g.strokeStyle=c;g.lineWidth=1.4;g.lineCap='round';g.lineJoin='round';g.stroke()}
const CARDS=[{k:'codex',task:'数据库迁移脚本',meta:'A41C02  21:04',status:'待你确认',color:C.attn},
  {k:'workbuddy',task:'整理本周周报素材',meta:'7F2E91  20:58',status:'进行中',color:C.info},
  {k:'claude',task:'重构登录模块',meta:'C93B07  20:41',status:'本轮结束',color:C.ok}];
const STEPS=[['读取文件 · 已返回','21:02'],['执行命令 · 已返回','21:03'],['修改文件 · 已返回','21:03'],['请求权限 · 待你确认','21:04']];
function panel(g,t,x0,a){
  const A=t0=>a*out(seg(t,t0,t0+.38)),D=t0=>(1-out(seg(t,t0,t0+.5)))*10;
  const R=x0+640,dim='#8a9391',hi='#eef0ec';
  alpha(g,A(15.15),()=>{
    brandMark(g,x0+38,62,40);
    T(g,'Agent 灵动岛',x0+70,60,16,hi,700);T(g,'你的 Agent 管家',x0+70,79,11,dim);
    const n=out(seg(t,15.3,15.9));
    [['活跃',2,C.info],['待更新',1,'#e6e8e4'],['待处理',1,C.attn]].forEach(([l,v,c],i)=>{const x=R-188+i*48;
      T(g,String(Math.round(v*n)),x,61,17,c,700,'center');T(g,l,x,80,10.5,dim,400,'center')});
    circle(g,R-38,64,16,'rgba(255,255,255,.08)');
    g.beginPath();g.moveTo(R-44,67);g.lineTo(R-38,61);g.lineTo(R-32,67);g.strokeStyle='#d9dcd8';g.lineWidth=1.8;g.lineCap='round';g.lineJoin='round';g.stroke();
    g.fillStyle='rgba(255,255,255,.08)';g.fillRect(x0,100,640,1);
  });
  alpha(g,A(15.3),()=>{
    T(g,'今日活跃 · 12 轮',x0+22,124,11,'#dfe2de',600);
    const bx=x0+128,bw=490,f=ease(seg(t,15.4,16.2));const parts=[['codex',5],['claude',4],['workbuddy',2],['doubao',1]];
    g.save();g.beginPath();g.rect(bx,112,bw*f,14);g.clip();
    let x=bx;parts.forEach(([k,v])=>{const w=(bw-12)*v/12;rr(g,x,116,w,7,3.5,AGENTS[k].color);x+=w+4});g.restore();
    x=x0+22;parts.forEach(([k,v])=>{circle(g,x+3,142.5,3,AGENTS[k].color);T(g,AGENTS[k].name,x+11,146,10.5,'#c7ccc9');
      const nw=tw(g,AGENTS[k].name,10.5);T(g,String(v),x+17+nw,146,10.5,hi,700);x+=17+nw+tw(g,String(v),10.5,700)+20});
    g.fillStyle='rgba(255,255,255,.08)';g.fillRect(x0,160,640,1);g.fillRect(x0+275,160,1,292);
  });
  alpha(g,A(15.45),()=>{T(g,'最近 24 小时',x0+20,184,10.5,dim);T(g,'进行中优先',x0+262,184,10.5,dim,400,'right')});
  CARDS.forEach((c,i)=>{const t0=15.55+i*.14;alpha(g,A(t0),()=>{
    const x=x0+12,y=196+i*84+D(t0);
    const hover=i===0?.5+.5*seg(t,16.85,17.05)*(1-seg(t,18.6,18.8)):0;
    rr(g,x,y,250,76,12,i===0?`rgba(255,255,255,${.075+.035*hover})`:'rgba(255,255,255,.05)',i===0?'rgba(138,174,232,.32)':null,1);
    icon(g,c.k,x+26,y+38,26);
    T(g,AGENTS[c.k].name,x+48,y+26,12.5,hi,700);T(g,c.task,x+48,y+45,11,'#aab2af');T(g,c.meta,x+48,y+63,9.5,'#6f7976',500);
    const sw=tw(g,c.status,11,600);T(g,c.status,x+238,y+45,11,c.color,600,'right');clockIcon(g,x+238-sw-10,y+41,c.color);
  })});
  alpha(g,A(15.9),()=>{
    const dx=x0+295;icon(g,'codex',dx+14,188,30);T(g,'Codex',dx+40,193,14,hi,700);
    const press=1-.06*Math.sin(Math.PI*seg(t,19.94,20.1)),glow=seg(t,19.0,19.2);
    g.save();g.translate(R-58,188);g.scale(press,press);
    rr(g,-38,-15,76,30,15,`rgba(122,168,255,${.16+.1*glow})`);T(g,'打开应用',0,4,11.5,'#a6c3ff',700,'center');g.restore();
    T(g,'数据库迁移脚本：对比新旧表结构，',dx-2,234,13,hi,500);T(g,'并补充回滚步骤',dx-2,254,13,hi,500);
    T(g,'会话线索 · A41C02   21:04',dx-2,278,10,dim);T(g,'复制会话线索',R-20,278,10,dim,400,'right');
  });
  STEPS.forEach((s,i)=>{const t0=16.1+i*.15;alpha(g,A(t0),()=>{const y=310+i*28+D(t0)*.6,last=i===3,c=last?C.attn:'#e6e8e4';
    stepArrow(g,x0+300,y-4,last?C.attn:'#c9cecb');T(g,s[0],x0+322,y,11.5,c,last?600:400);T(g,s[1],R-20,y,11,'#9aa3a0',500,'right');
    if(last)circle(g,x0+322+tw(g,s[0],11.5,600)+10,y-4,2.6+.8*Math.sin(t*TAU),C.attn);
  })});
  alpha(g,A(16.8),()=>T(g,'由真实事件更新',R-20,430,9.5,'#68716e',400,'right'));
}
function drawIsland(g,t){
  const I=island(t);
  if(I.med>0){const e=t<12.08?EVENTS[0]:EVENTS[1];
    const r=g.createRadialGradient(NX,30,0,NX,30,320);r.addColorStop(0,e.color+'40');r.addColorStop(1,e.color+'00');
    alpha(g,I.med,()=>{g.fillStyle=r;g.fillRect(NX-340,0,680,360)})}
  g.save();
  if(I.h>40){g.shadowColor='rgba(10,16,14,.34)';g.shadowBlur=46*CAM_S;g.shadowOffsetY=18*CAM_S}
  notchPath(g,NX,-1,I.w,I.h+1,I.sh,I.r);g.fillStyle='#000';g.fill();g.restore();
  g.save();notchPath(g,NX,-1,I.w,I.h+1,I.sh,I.r);g.clip();
  if(I.small>0)alpha(g,I.small,()=>smallContent(g,t,I,NX));
  if(I.med>0)medContent(g,t,I,NX);
  if(I.pan>0)panel(g,t,NX-320,I.pan);
  g.restore();
}

/* ---------------- cursor ---------------- */
const CUR=[[2.9,720,620],[3.4,200,142],[3.55,200,142],[3.9,1100,188],[4.05,1100,188],[4.4,330,748],[4.55,330,748],
  [4.9,1352,700],[5.05,1352,700],[5.4,200,142],[5.6,200,142],[6.1,420,420],
  [14.05,960,210],[14.6,872,21],[16.6,872,21],[17.0,566,232],[18.5,566,232],[19.1,1012,183],[21.0,1012,183],[22.25,1088,514],[22.6,1088,514],[23.1,1150,690]];
const CLICK_T=[[3.5,0],[4.0,0],[4.5,0],[5.0,0],[5.5,0],[20.0,1],[22.4,0]];
function cursorAt(t){
  if(t<=CUR[0][0])return {x:CUR[0][1],y:CUR[0][2]};
  for(let i=0;i<CUR.length-1;i++){const a=CUR[i],b=CUR[i+1];if(t>=a[0]&&t<b[0]){const p=ease(seg(t,a[0],b[0]));return {x:mix(a[1],b[1],p),y:mix(a[2],b[2],p)}}}
  const l=CUR[CUR.length-1];return {x:l[1],y:l[2]};
}
function drawCursor(g,t,cam){
  const v=seg(t,2.85,3.0)*(1-seg(t,6.0,6.25))+seg(t,14.0,14.2)*(1-seg(t,23.05,23.3));
  if(v<=0)return;
  const p=cursorAt(t),sc=clamp(1.05/cam.s,1,1.55);
  for(const [ct,dark] of CLICK_T){const q=seg(t,ct,ct+.4);if(q>0&&q<1)alpha(g,v*(1-q)*.5,()=>circle(g,p.x,p.y,(5+20*out(q))*sc,null,dark?'#fff':C.ink,1.6*sc))}
  // 0.2 s hover dwell ring
  const hq=seg(t,14.6,14.82),ha=seg(t,14.58,14.62)*(1-seg(t,14.85,15.0));
  if(ha>0)alpha(g,ha,()=>{circle(g,p.x,p.y,13,null,'rgba(255,255,255,.18)',2.2);
    g.beginPath();g.arc(p.x,p.y,13,-Math.PI/2,-Math.PI/2+TAU*hq);g.strokeStyle=C.mint;g.lineWidth=2.2;g.lineCap='round';g.stroke();
    T(g,'0.2s',p.x+16,p.y+38,10,C.ink,700,'left',MONO)});
  let press=1;for(const [ct] of CLICK_T)press=Math.min(press,1-.12*Math.sin(Math.PI*seg(t,ct-.06,ct+.08)));
  alpha(g,v,()=>{g.save();g.translate(p.x,p.y);g.scale(sc*press,sc*press);
    g.beginPath();g.moveTo(0,0);g.lineTo(0,18.5);g.lineTo(4.4,14.4);g.lineTo(7.4,21.2);g.lineTo(10.4,19.9);g.lineTo(7.5,13.3);g.lineTo(13.2,13.3);g.closePath();
    g.lineJoin='round';g.shadowColor='rgba(0,0,0,.3)';g.shadowBlur=5*cam.s*sc;g.shadowOffsetY=1.5*cam.s*sc;
    g.strokeStyle='#fff';g.lineWidth=2.2;g.stroke();g.shadowColor='transparent';g.fillStyle='#0b0d0c';g.fill();g.restore()});
}

/* ---------------- stage + laptop ---------------- */
function stage(g){
  g.setTransform(1,0,0,1,0,0);g.fillStyle=C.stage;g.fillRect(0,0,W,H);
  const r=g.createRadialGradient(W*.62,H*.42,0,W*.62,H*.42,1200);r.addColorStop(0,'#f7f7f4');r.addColorStop(1,'#e4e5e0');
  g.fillStyle=r;g.fillRect(0,0,W,H);
}
function laptop(g,t,cam){
  g.save();g.translate(NX,1032);g.scale(1,.07);
  const sg=g.createRadialGradient(0,0,0,0,0,920);sg.addColorStop(0,'rgba(30,40,35,.34)');sg.addColorStop(1,'rgba(30,40,35,0)');
  g.fillStyle=sg;g.fillRect(-920,-920,1840,1840);g.restore();
  g.beginPath();g.moveTo(-100,1000);g.lineTo(SW+100,1000);g.lineTo(SW+84,1024);g.quadraticCurveTo(SW+80,1028,SW+70,1028);g.lineTo(-58,1028);g.quadraticCurveTo(-80,1028,-84,1024);g.closePath();
  const bg=g.createLinearGradient(0,1000,0,1028);bg.addColorStop(0,'#e4e6e3');bg.addColorStop(.45,'#bfc3c0');bg.addColorStop(1,'#8b918e');g.fillStyle=bg;g.fill();
  rr(g,NX-120,1000,240,7,[0,0,6,6],'#9aa09d');
  rr(g,-18,-18,SW+36,SH+36,28,'#0b0d0e','#3c4241',2);
  g.save();g.beginPath();g.roundRect(0,0,SW,SH,[10,10,4,4]);g.clip();
  wallpaper(g);drawWindows(g,t);dock(g,t);menubar(g,t);drawIsland(g,t);drawCursor(g,t,cam);
  g.restore();
}

/* ---------------- captions ---------------- */
const CAPS=[
  {a:2.7,b:6.0,lines:['来回切窗口，','只为看一眼：好了没？'],sub:'每个 Agent 一个窗口，进度散落各处。',align:'left',x:110,y:452},
  {a:8.0,b:9.95,lines:['现在，它们都在 Agent 灵动岛里。'],sub:'小态常驻，只呈现真实事件。',align:'center',x:960,y:500},
  {a:10.6,b:14.25,lines:['有事才展开，说完就收回。'],sub:'中态约 10 秒后自动收起。',align:'center',x:960,y:500},
  {a:15.8,b:20.2,lines:['停 0.2 秒，全部看清。'],sub:'最近 24 小时的任务，进行中优先。',align:'center',x:960,y:922,size:52,subSize:23},
  {a:21.3,b:22.95,lines:['一键，回到它。'],sub:'批准、停止、回复，仍在原应用完成。',align:'left',x:110,y:470},
  {a:23.6,b:25.6,lines:['你，继续专注。'],sub:'状态安静留在 Mac 顶部。',align:'left',x:110,y:500}
];
function caption(g,t,c){
  if(t<c.a||t>c.b)return;
  // exit: soft fade + lift + defocus, so captions dissolve into the next shot
  const xo=ease(seg(t,c.b-.5,c.b)),fade=1-xo,lift=-14*xo,size=c.size||60,lh=size*1.24;
  g.save();g.setTransform(1,0,0,1,0,0);g.textBaseline='alphabetic';g.textAlign='left';
  g.font=`600 ${size}px ${FONT}`;let k=0;
  c.lines.forEach((ln,li)=>{const ch=[...ln],ws=ch.map(s=>g.measureText(s).width),tot=ws.reduce((a,b)=>a+b,0);
    let x=c.align==='center'?c.x-tot/2:c.x;const y=c.y+li*lh;
    ch.forEach((s,i)=>{const p=out(seg(t,c.a+k*.026,c.a+k*.026+.6));k++;if(p*fade<=.002){x+=ws[i];return}
      const bl=(1-p)*9+xo*6;g.filter=bl>.15?`blur(${bl.toFixed(2)}px)`:'none';
      g.globalAlpha=p*fade;g.fillStyle=c.color||C.ink;g.fillText(s,x,y+(1-p)*22+lift);x+=ws[i]});
  });
  if(c.sub){const p=out(seg(t,c.a+.4,c.a+1.05)),bl=(1-p)*6+xo*5;g.filter=bl>.15?`blur(${bl.toFixed(2)}px)`:'none';
    g.globalAlpha=p*fade;g.font=`400 ${c.subSize||26}px ${FONT}`;g.fillStyle=c.subColor||C.ink2;
    g.textAlign=c.align;g.fillText(c.sub,c.x,c.y+(c.lines.length-1)*lh+size*.98+(1-p)*12+lift)}
  g.filter='none';g.restore();
}

/* ---------------- intro / silence / end ---------------- */
const INTRO=ORDER.map((k,i)=>({k,x:W/2+(i-1.5)*156,y:612,pop:.55+i*.25}));
function introOverlay(g,t){
  const ob=1-ease(seg(t,1.75,2.3));
  g.setTransform(1,0,0,1,0,0);
  if(ob>0){g.globalAlpha=ob;g.fillStyle=C.obs;g.fillRect(0,0,W,H);
    const r=g.createRadialGradient(W/2,H*.45,0,W/2,H*.45,900);r.addColorStop(0,'rgba(132,219,243,.06)');r.addColorStop(1,'rgba(132,219,243,0)');g.fillStyle=r;g.fillRect(0,0,W,H);g.globalAlpha=1}
  caption(g,t,{a:.12,b:1.85,lines:['多个 Agent，同时在跑。'],align:'center',x:960,y:440,size:78,color:C.porc});
  const cam=camera(2.45);
  INTRO.forEach(it=>{const s=back(seg(t,it.pop,it.pop+.42)),a=seg(t,it.pop,it.pop+.12);if(a<=0)return;
    const f=ease(seg(t,1.8,2.45)),d=toScreen(cam,DOCK_POS[it.k].x,DOCK_POS[it.k].y-2);
    const x=mix(it.x,d.x,f),y=mix(it.y,d.y,f),size=mix(108,46*cam.s,f)*s;
    if(t>=2.45)return;
    alpha(g,a,()=>{const q=seg(t,it.pop,it.pop+.6);if(q<1)alpha(g,(1-q)*.45*(1-f),()=>circle(g,x,y,54+50*out(q),null,AGENTS[it.k].color,1.5));
      g.drawImage(IMG[it.k],x-size/2,y-size/2,size,size)});
    alpha(g,a*(1-seg(t,1.55,1.8)),()=>T(g,AGENTS[it.k].name,it.x,it.y+96,21,'#9aa6a3',500,'center'));
  });
}
function silence(g,t){
  g.setTransform(1,0,0,1,0,0);g.fillStyle=C.obs;g.fillRect(0,0,W,H);
  endMark(g,25.99);
}
function endMark(g,t){
  const m=t<26?0:spring(seg(t,26,26.75)),S=2.4;
  const i0={w:290*S,h:34*S,sh:7*S,r:12*S,cy:540},size=184,bw=size*.92,bsh=bw*.12;
  const b={w:bw-2*bsh,h:size*.5,sh:bsh,r:size*.5*.35,cy:388};
  const w=mix(i0.w,b.w,m),h=mix(i0.h,b.h,m),sh=mix(i0.sh,b.sh,m),r=mix(i0.r,b.r,m),cy=mix(i0.cy,b.cy,m);
  const top=cy-h/2;
  const gl=g.createRadialGradient(W/2,cy,0,W/2,cy,520);gl.addColorStop(0,`rgba(247,247,244,${.03+.05*clamp(m)})`);gl.addColorStop(1,'rgba(247,247,244,0)');g.fillStyle=gl;g.fillRect(0,0,W,H);
  notchPath(g,W/2,top,w,h,sh,r);g.fillStyle='#0a0c0d';g.fill();
  const gr=g.createLinearGradient(0,top,0,top+h);gr.addColorStop(0,'#f7fcf7');gr.addColorStop(1,'#999e99');
  g.save();g.globalAlpha*=mix(.38,1,clamp(m*1.4));g.strokeStyle=gr;g.lineWidth=mix(1.5,size*.06,clamp(m));g.stroke();g.restore();
  const fade=1-clamp(m*3);
  alpha(g,fade,()=>{g.drawImage(IMG.codex,W/2-w/2+21*S-11*S,cy-11*S,22*S,22*S);
    T(g,'4',W/2+w/2-31*S+8*S,cy+4.6*S,12.5*S,'#f2f4f1',600,'center');rr(g,W/2+w/2-31*S-22*S,cy-11*S,44*S,22*S,11*S,'rgba(255,255,255,.1)')});
  const bh=barHeights(Math.min(t,25.75)),cols=['#cddaf3','#cddaf3','#cddaf3'],tc=[C.mint,C.porc,C.ice],ths=[.16,.25,.12];
  for(let i=0;i<3;i++){
    const sx=W/2+w/2-31*S-14*S+i*5*S+1.5*S,sy=cy,sw0=3*S,sh0=bh[i]*S;
    const tx=W/2+(i-1)*size*.14,ty=cy+size*.028,tsw=size*.07,tsh=size*ths[i];
    const k=clamp(m);const x=mix(sx,tx,k),y=mix(sy,ty,k),bw2=mix(sw0,tsw,k),bh2=mix(sh0,tsh,k);
    g.save();g.fillStyle=k>.02?tc[i]:cols[i];rr(g,x-bw2/2,y-bh2/2,bw2,bh2,bw2/2,k>.02?tc[i]:cols[i]);g.restore();
  }
}
function endCard(g,t){
  g.setTransform(1,0,0,1,0,0);g.fillStyle=C.obs;g.fillRect(0,0,W,H);
  endMark(g,t);
  caption(g,t,{a:26.45,b:30.5,lines:['Agent 灵动岛'],align:'center',x:960,y:586,size:84,color:C.porc,sub:'你的 Agent 管家',subSize:32,subColor:'#9aa6a3'});
  const k=out(seg(t,27.1,27.6));
  g.save();g.globalAlpha=k;g.font=`500 18px ${FONT}`;g.fillStyle=C.muted;g.textAlign='center';
  g.letterSpacing='4px';g.fillText('macOS · GITHUB ALPHA',960,748);g.letterSpacing='0px';g.restore();
  const f=out(seg(t,27.5,28.1));
  alpha(g,f,()=>{T(g,'Designed by Bill · GitHub @Bill-Fei',80,1018,17,'#6d7978');T(g,'界面依据真实产品布局重绘 · 任务内容为演示',1840,1018,17,'#6d7978',400,'right')});
  const end=seg(t,29.45,30);if(end>0){g.globalAlpha=end;g.fillStyle='#000';g.fillRect(0,0,W,H);g.globalAlpha=1}
}

/* ---------------- render ---------------- */
function render(t){
  t=clamp(t,0,30);
  ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=1;ctx.globalCompositeOperation='source-over';ctx.shadowColor='transparent';
  if(t>=26){endCard(ctx,t);return}
  if(t>=25.75){silence(ctx,t);return}
  stage(ctx);
  const cam=camera(t);CAM_S=cam.s;
  const la=t<2.5?out(seg(t,1.85,2.45)):1;
  if(la>0){ctx.save();ctx.globalAlpha=la;
    ctx.setTransform(cam.s,0,0,cam.s,W/2-cam.x*cam.s,H/2-cam.y*cam.s+(1-la)*70);
    laptop(ctx,t,cam);ctx.restore()}
  ctx.setTransform(1,0,0,1,0,0);
  for(const c of CAPS)caption(ctx,t,c);
  if(t<2.5)introOverlay(ctx,t);
  // Lights out around the island: the room fades to obsidian while the mark rides
  // on top of the real island, so 25.75 hands over to the end card without a cut.
  const lo=ease(seg(t,25.25,25.75));
  if(lo>0){ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=lo;ctx.fillStyle=C.obs;ctx.fillRect(0,0,W,H);
    const p=toScreen(cam,756,16.5),k=cam.s/2.4;
    ctx.setTransform(k,0,0,k,p.x-W/2*k,p.y-540*k);endMark(ctx,t);
    ctx.setTransform(1,0,0,1,0,0);ctx.globalAlpha=1}
}
window.render=render;
window.filmReady=Promise.all(NAMES.map(n=>new Promise((res,rej)=>{const i=new Image();i.onload=()=>{IMG[n]=i;res(n)};i.onerror=()=>rej(new Error('asset '+n));i.src=`assets/${n}.png`})))
  .then(()=>document.fonts.ready).then(()=>{render(0);return {assets:NAMES.length,duration:30,fps:30,size:[W*DS,H*DS]}});
