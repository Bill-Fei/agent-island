/* Playwright screenshots -> ffmpeg image pipe. render(t) is called explicitly,
   so browser or CPU timing cannot affect output. */
const fs=require('node:fs');
const path=require('node:path');
const {spawn}=require('node:child_process');
const {once}=require('node:events');
const crypto=require('node:crypto');
const pw=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const ENGINE=process.env.ENGINE||'webkit';
const ROOT=__dirname,OUT=path.join(ROOT,'../output/v4');
const MP4=path.join(OUT,'Agent-Island-V4-1080p.mp4');
const mode=process.argv[2]||'render';
const only=process.argv.slice(3).map(Number).filter(Number.isFinite);
fs.mkdirSync(OUT,{recursive:true});
// Loaded straight from disk (file://); the page only ever reads files inside ROOT.
const server={close(){}};
const PAGE=require('node:url').pathToFileURL(path.join(ROOT,'index.html')).href;
const LOCAL=require('node:url').pathToFileURL(ROOT).href;
async function main(){
  const browser=ENGINE==='chrome'
    ?await pw.chromium.launch({headless:true,executablePath:process.env.CHROME_BINARY||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'})
    :await pw.webkit.launch({headless:true});
  const page=await browser.newPage({viewport:{width:1920,height:1080},deviceScaleFactor:1});
  const errors=[],network=[];page.on('pageerror',e=>errors.push(e.message));
  page.on('request',req=>network.push(req.url()));
  await page.goto(PAGE);
  const init=await page.evaluate(()=>window.filmReady);console.log('READY',JSON.stringify(init));
  const seek=async t=>{await page.evaluate(t=>window.render(t),t);return page.screenshot({type:'png',animations:'disabled'})};
  const heroTimes=only.length?only:[1.2,3.8,5.6,8.8,11.2,12.8,16.8,18.6,21.8,22.8,24.8,25.7,27.5,29.2];
  const stillDir=path.join(OUT,'stills');fs.mkdirSync(stillDir,{recursive:true});
  for(const t of heroTimes){fs.writeFileSync(path.join(stillDir,`t${t.toFixed(2).padStart(5,'0')}.png`),await seek(t))}
  const first=await seek(8.8);await seek(19.4);const second=await seek(8.8);
  const deterministic=first.equals(second);
  const external=network.filter(u=>!u.startsWith(LOCAL));
  if(!deterministic||errors.length||external.length)throw new Error(JSON.stringify({deterministic,errors,external}));
  if(mode==='stills'){console.log('STILLS VERIFIED',heroTimes.join(','));await browser.close();server.close();return}
  const frames=path.join(OUT,'frames');fs.mkdirSync(frames,{recursive:true});
  const args=['-hide_banner','-loglevel','warning','-y','-f','image2pipe','-framerate','30','-vcodec','png','-i','pipe:0',
    '-i',path.join(OUT,'original-score.wav'),'-map','0:v:0','-map','1:a:0','-c:v','libx264','-preset','slow','-crf','17',
    '-pix_fmt','yuv420p','-r','30','-c:a','aac','-b:a','320k','-ar','48000','-t','30','-movflags','+faststart',
    '-metadata','title=Agent 灵动岛 — V4','-metadata','artist=Bill · original code-generated film',MP4];
  const ff=spawn(process.env.FFMPEG||'/opt/homebrew/bin/ffmpeg',args,{stdio:['pipe','ignore','inherit']});
  const ffExit=once(ff,'exit');ff.stdin.on('error',err=>console.error(err.message));
  const before=Date.now();
  for(let f=0;f<900;f++){
    const png=await seek(f/30);fs.writeFileSync(path.join(frames,`frame-${String(f).padStart(4,'0')}.png`),png);
    if(!ff.stdin.write(png))await once(ff.stdin,'drain');
    if(f%90===0)console.log(`FRAME ${f}/900 | ${Math.round((Date.now()-before)/1000)}s`);
  }
  ff.stdin.end();const [code]=await ffExit;if(code!==0)throw new Error(`ffmpeg ${code}`);
  const report={...init,engine:ENGINE,deterministic,errors,external,frame_count:900,score:'original-score.wav',
    sha256:crypto.createHash('sha256').update(fs.readFileSync(MP4)).digest('hex')};
  fs.writeFileSync(path.join(OUT,'render-report.json'),JSON.stringify(report,null,2));
  console.log('COMPLETE',JSON.stringify(report));await browser.close();server.close();
}
main().catch(err=>{console.error(err);server.close();process.exit(1)});
