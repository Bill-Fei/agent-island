/* Playwright screenshots -> ffmpeg image pipe. Saves 900 lossless PNG frames.
   render(t) is called explicitly, so browser or CPU timing cannot affect output. */
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const crypto=require('node:crypto');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const ROOT=__dirname,OUT=path.join(ROOT,'output/v2');
const mode=process.argv[2]||'render';
fs.mkdirSync(OUT,{recursive:true});
const server=http.createServer((req,res)=>{
  const file=path.join(ROOT,req.url==='/'?'index.html':decodeURIComponent(req.url).split('?')[0]);
  if(!file.startsWith(ROOT+path.sep)){res.writeHead(403);return res.end()}
  fs.readFile(file,(err,data)=>{if(err){res.writeHead(404);res.end();return}
    res.setHeader('Content-Type',file.endsWith('.html')?'text/html':file.endsWith('.js')?'text/javascript':'application/octet-stream');res.end(data)});
});
async function main(){
  server.listen(0,'127.0.0.1');await once(server,'listening');
  const browser=await chromium.launch({headless:true,executablePath:process.env.CHROME_BINARY||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  const page=await browser.newPage({viewport:{width:1920,height:1080},deviceScaleFactor:1});
  const errors=[],network=[];page.on('pageerror',e=>errors.push(e.message));
  page.on('request',req=>network.push(req.url()));
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const init=await page.evaluate(()=>window.filmReady);console.log('READY',JSON.stringify(init));
  const seek=async t=>{await page.evaluate(t=>window.render(t),t);return page.screenshot({type:'png',animations:'disabled'})};
  const heroTimes=Array.from({length:13},(_,i)=>i*2+1.25).concat([27.25,29.5]);
  fs.mkdirSync(path.join(OUT,'stills'),{recursive:true});
  for(let i=0;i<heroTimes.length;i++){const png=await seek(heroTimes[i]);fs.writeFileSync(path.join(OUT,'stills',`${String(i).padStart(2,'0')}.png`),png)}
  const first=await seek(8.8);await seek(19.4);const second=await seek(8.8);
  const deterministic=first.equals(second);
  const external=network.filter(u=>!u.startsWith('http://127.0.0.1:'));
  if(!deterministic||errors.length||external.length)throw new Error(JSON.stringify({deterministic,errors,external}));
  if(mode==='stills'){
    fs.writeFileSync(path.join(OUT,'stills-check.json'),JSON.stringify({init,deterministic,errors,external,heroTimes},null,2));
    console.log('STILLS VERIFIED');await browser.close();server.close();return;
  }
  const frames=path.join(OUT,'frames');fs.mkdirSync(frames,{recursive:true});
  const args=['-hide_banner','-loglevel','warning','-y','-f','image2pipe','-framerate','30','-vcodec','png','-i','pipe:0',
    '-i',path.join(OUT,'original-score.wav'),'-map','0:v:0','-map','1:a:0','-c:v','libx264','-preset','slow','-crf','17',
    '-pix_fmt','yuv420p','-r','30','-c:a','aac','-b:a','320k','-ar','48000','-t','30','-movflags','+faststart',
    '-metadata','title=Agent 灵动岛 — Quiet Power','-metadata','artist=Bill · original code-generated film',
    path.join(OUT,'Agent-Island-Quiet-Power-V2-1080p.mp4')];
  const ff=spawn(process.env.FFMPEG||'/opt/homebrew/bin/ffmpeg',args,{stdio:['pipe','ignore','inherit']});
  const ffExit=once(ff,'exit');ff.stdin.on('error',err=>console.error(err.message));
  const before=Date.now();
  for(let f=0;f<900;f++){
    const png=await seek(f/30);fs.writeFileSync(path.join(frames,`frame-${String(f).padStart(4,'0')}.png`),png);
    if(!ff.stdin.write(png))await once(ff.stdin,'drain');
    if(f%60===0)console.log(`FRAME ${f}/900 | ${Math.round((Date.now()-before)/1000)}s`);
  }
  ff.stdin.end();const [code]=await ffExit;if(code!==0)throw new Error(`ffmpeg ${code}`);
  const report={...init,deterministic,errors,external,frame_count:900,cuts:Array.from({length:14},(_,i)=>i*2),
    recap_cuts:[24,24.5,25,25.5],transitions:12,score:'original-score.wav',
    sha256:crypto.createHash('sha256').update(fs.readFileSync(path.join(OUT,'Agent-Island-Quiet-Power-V2-1080p.mp4'))).digest('hex')};
  fs.writeFileSync(path.join(OUT,'render-report.json'),JSON.stringify(report,null,2));
  console.log('COMPLETE',JSON.stringify(report));await browser.close();server.close();
}
main().catch(err=>{console.error(err);server.close();process.exit(1)});
