// Website-only release: reuse the already published installer, never build/sign the app.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'dist/site-deploy');
const version = fs.readFileSync(path.join(root, 'VERSION'), 'utf8').trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Invalid release version');
const dmg = path.join(out, 'download', `Agent-Island-${version}.dmg`);
if (!fs.existsSync(dmg)) throw new Error('Published installer missing; do not rebuild implicitly');
// echarts.min.js: dashboard.html loads it from the site, not a CDN. og-card.jpg: referenced
// by absolute URL from the og:image tags, so nothing on the page pulls it in.
for (const file of ['index.html', 'en/index.html', 'style.css', 'island.js', 'analytics.js', '_worker.js', '_routes.json', 'dashboard.html', 'echarts.min.js',
  'media/og-card.jpg', 'media/og-card-en.jpg']) {
  fs.mkdirSync(path.dirname(path.join(out, file)), { recursive: true });
  fs.copyFileSync(path.join(root, 'site', file), path.join(out, file));
}
// /en/ sits one level down, so its link climbs back to the shared download/ folder.
for (const [page, prefix] of [['index.html', ''], ['en/index.html', '../']]) {
  const file = path.join(out, page);
  const want = `dmgUrl: '${prefix}download/Agent-Island-${version}.dmg'`;
  const html = fs.readFileSync(file, 'utf8').replace("dmgUrl: ''", want);
  if (!html.includes(want)) throw new Error(`Download link not injected into ${page}`);
  fs.writeFileSync(file, html);
}
console.log(`Website prepared; existing installer preserved: ${version}`);
if (!process.argv.includes('--deploy')) process.exit(0);
const result = spawnSync('wrangler', ['pages', 'deploy', out, '--project-name', 'agent-island',
  '--branch', 'main', '--commit-dirty=true'], {cwd: path.join(root, 'site'), stdio: 'inherit'});
process.exit(result.status ?? 1);
