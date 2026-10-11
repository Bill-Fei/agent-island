import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const code = fs.readFileSync(new URL('../site/_worker.js', import.meta.url), 'utf8');
const worker = (await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`)).default;
let rows = [], pending = [];
const env = { ANALYTICS_DB: {
  prepare: sql => ({ bind: (...values) => ({ sql, values }) }),
  batch: async statements => { rows.push(statements[0].values); }
}, ASSETS: { fetch: async () => new Response('installer', {status: 200}) } };
const ctx = {waitUntil: promise => pending.push(promise)};
function req(body, headers = {}, pathname = '/api/analytics', method = 'POST') {
  const request = new Request(`https://agent-island.pages.dev${pathname}`, {
    method, headers: {'Origin': 'https://agent-island.pages.dev', 'Content-Type': 'application/json', ...headers},
    ...(method === 'POST' ? {body: typeof body === 'string' ? body : JSON.stringify(body)} : {})
  });
  Object.defineProperty(request, 'cf', {value: {country: 'CN'}});
  return request;
}
const event = {event: 'click', target: 'download_hero', source: 'direct', test: true};
assert.equal((await worker.fetch(req(event), env, ctx)).status, 204);
assert.equal(rows.length, 1); assert.equal(rows[0][3], 'CN'); assert.equal(rows[0][6], 'test');
assert.equal((await worker.fetch(req(event, {Origin: 'https://evil.example'}), env, ctx)).status, 403);
assert.equal((await worker.fetch(req({...event, target: 'private content'}), env, ctx)).status, 400);
assert.equal((await worker.fetch(req({...event, source: 'https://private.example/path'}), env, ctx)).status, 400);
assert.equal((await worker.fetch(req('x'.repeat(1025)), env, ctx)).status, 413);
for (const header of [{DNT: '1'}, {'Sec-GPC': '1'}, {'User-Agent': 'Googlebot'}]) {
  const n = rows.length;
  assert.equal((await worker.fetch(req(event, header), env, ctx)).status, 204);
  assert.equal(rows.length, n);
}
assert.equal((await worker.fetch(req(event), {...env, ANALYTICS_DB: null}, ctx)).status, 503);
let n = rows.length;
for (const method of ['HEAD', 'GET']) {
  await worker.fetch(req(null, method === 'GET' ? {Range: 'bytes=100-200'} : {}, '/download/Agent-Island-0.3.1.dmg', method), env, ctx);
}
await Promise.all(pending); assert.equal(rows.length, n);
await worker.fetch(req(null, {Range: 'bytes=0-200'}, '/download/Agent-Island-0.3.1.dmg?analytics_test=1', 'GET'), env, ctx);
await Promise.all(pending); assert.equal(rows.length, n + 1); assert.equal(rows.at(-1)[1], 'download_request');
const browserCode = fs.readFileSync(new URL('../site/analytics.js', import.meta.url), 'utf8');
for (const optout of [false, true]) {
  let requests = [], listener;
  const context = {navigator: {doNotTrack: optout ? '1' : '0'}, URL, URLSearchParams,
    location: {protocol: 'https:', search: '?analytics_test=1', hostname: 'agent-island.pages.dev'},
    document: {referrer: '', addEventListener: (name, fn) => {listener = fn}},
    window: {SITE: {dmgUrl: 'download/Agent-Island-0.3.1.dmg'}},
    fetch: (url, options) => {requests.push(JSON.parse(options.body)); return Promise.resolve()}};
  vm.runInNewContext(browserCode, context);
  assert.equal(requests.length, optout ? 0 : 1);
  if (!optout) {
    listener({target: {closest: () => ({id: 'dmgLink', getAttribute: () => null, matches: () => true})}});
    assert.equal(requests[1].target, 'download_section');
    assert.equal(requests[1].test, true);
  }
}
console.log('Site analytics tests passed: collection, privacy opt-outs, validation, downloads, frontend.');
