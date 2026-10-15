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
for (const file of ['index.html', 'style.css', 'island.js', 'analytics.js', '_worker.js', '_routes.json', 'dashboard.html']) {
  fs.copyFileSync(path.join(root, 'site', file), path.join(out, file));
}
const html = fs.readFileSync(path.join(out, 'index.html'), 'utf8')
  .replace("dmgUrl: ''", `dmgUrl: 'download/Agent-Island-${version}.dmg'`);
fs.writeFileSync(path.join(out, 'index.html'), html);
console.log(`Website prepared; existing installer preserved: ${version}`);
if (!process.argv.includes('--deploy')) process.exit(0);
const result = spawnSync('wrangler', ['pages', 'deploy', out, '--project-name', 'agent-island',
  '--branch', 'main', '--commit-dirty=true'], {cwd: path.join(root, 'site'), stdio: 'inherit'});
process.exit(result.status ?? 1);
