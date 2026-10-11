/* Static server for the V4 film plus a frame sink: the page POSTs canvas PNGs,
   which are written to output/v4/frames (or stills) for ffmpeg. */
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const ROOT=__dirname,OUT=path.join(ROOT,'../output/v4');
const PORT=Number(process.env.PORT||4874);
const TYPES={'.html':'text/html; charset=utf-8','.js':'text/javascript','.png':'image/png'};
http.createServer((req,res)=>{
  const url=new URL(req.url,'http://x');
  if(req.method==='POST'&&url.pathname==='/sink'){
    const dir=['stills','frames4k'].includes(url.searchParams.get('dir'))?url.searchParams.get('dir'):'frames';
    const name=path.basename(url.searchParams.get('name')||'');
    if(!/^[\w.-]+\.(png|json)$/.test(name)){res.writeHead(400);return res.end()}
    const chunks=[];req.on('data',c=>chunks.push(c));req.on('end',()=>{
      fs.mkdirSync(path.join(OUT,dir),{recursive:true});
      fs.writeFileSync(path.join(OUT,dir,name),Buffer.concat(chunks));res.end('ok')});
    return;
  }
  const file=path.join(ROOT,url.pathname==='/'?'index.html':decodeURIComponent(url.pathname));
  if(!file.startsWith(ROOT+path.sep)){res.writeHead(403);return res.end()}
  fs.readFile(file,(err,data)=>{if(err){res.writeHead(404);return res.end()}
    res.setHeader('Content-Type',TYPES[path.extname(file)]||'application/octet-stream');res.setHeader('Cache-Control','no-store');res.end(data)});
}).listen(PORT,'127.0.0.1',()=>console.log(`V4 film on http://127.0.0.1:${PORT}`));
