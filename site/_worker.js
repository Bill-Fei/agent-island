// Pages advanced-mode worker: assets + first-party aggregate analytics.
const TARGETS = new Set(['download_section', 'download_menu', 'download_hero', 'download_mirror',
  'film_play', 'source', 'island_demo', 'film', 'states', 'privacy', 'agents', 'top']);
const SOURCES = new Set(['direct', 'search', 'social', 'other']);
const privateHeaders = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
const reply = status => new Response(null, { status, headers: privateHeaders });
function excluded(request) {
  return request.headers.get('DNT') === '1' || request.headers.get('Sec-GPC') === '1'
    || /bot|crawler|spider|headless/i.test(request.headers.get('User-Agent') || '');
}
function dimensions(request) {
  const country = String(request.cf?.country || 'XX');
  const ua = request.headers.get('User-Agent') || '';
  return {
    country: /^[A-Z]{2}$/.test(country) ? country : 'XX',
    device: /iPad|Tablet/i.test(ua) ? 'tablet' : /Mobile|Android|iPhone/i.test(ua) ? 'mobile' : 'desktop'
  };
}
async function record(env, request, event, target, source, test) {
  if (!env.ANALYTICS_DB) throw new Error('Analytics binding missing');
  const { country, device } = dimensions(request);
  const day = new Date().toISOString().slice(0, 10);
  const cutoff = new Date(Date.now() - 89 * 86400000).toISOString().slice(0, 10);
  await env.ANALYTICS_DB.batch([
    env.ANALYTICS_DB.prepare(`INSERT INTO daily_metrics(day,event,target,country,device,source,traffic,count)
      VALUES(?,?,?,?,?,?,?,1) ON CONFLICT(day,event,target,country,device,source,traffic)
      DO UPDATE SET count=count+1`).bind(day, event, target, country, device, source, test ? 'test' : 'visitor'),
    env.ANALYTICS_DB.prepare('DELETE FROM daily_metrics WHERE day < ?').bind(cutoff)
  ]);
}
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/api/analytics') {
      if (request.method !== 'POST') return reply(405);
      if (request.headers.get('Origin') !== url.origin) return reply(403);
      if (request.headers.get('Sec-Fetch-Site') === 'cross-site') return reply(403);
      if (excluded(request)) return reply(204);
      if (!request.headers.get('Content-Type')?.startsWith('application/json')) return reply(415);
      if (Number(request.headers.get('Content-Length')) > 1024) return reply(413);
      let data;
      try {
        // Bounded read even when the sender supplies no Content-Length.
        const reader = request.body?.getReader();
        if (!reader) return reply(400);
        let length = 0, chunks = [];
        while (true) {
          const part = await reader.read();
          if (part.done) break;
          length += part.value.byteLength;
          if (length > 1024) { await reader.cancel(); return reply(413); }
          chunks.push(part.value);
        }
        const bytes = new Uint8Array(length); let offset = 0;
        for (const part of chunks) { bytes.set(part, offset); offset += part.byteLength; }
        data = JSON.parse(new TextDecoder().decode(bytes));
      } catch { return reply(400); }
      if (!data || !['page_view', 'click'].includes(data.event)) return reply(400);
      if (data.event === 'click' && !TARGETS.has(data.target)) return reply(400);
      if (!SOURCES.has(data.source) || typeof data.test !== 'boolean') return reply(400);
      try {
        await record(env, request, data.event, data.event === 'click' ? data.target : '', data.source, data.test);
        return reply(204);
      } catch { return reply(503); } // No request body or user data in logs.
    }
    const response = await env.ASSETS.fetch(request);
    if (request.method === 'GET' && /^\/download\/Agent-Island-[0-9.]+\.dmg$/.test(url.pathname)
      && [200, 206].includes(response.status) && !excluded(request)) {
      // Count initial requests only, not HEAD checks or later byte-range retries.
      const range = request.headers.get('Range');
      if (!range || /^bytes=0-\d*$/.test(range)) {
        ctx.waitUntil(record(env, request, 'download_request', 'installer', 'direct',
          url.searchParams.get('analytics_test') === '1').catch(() => {}));
      }
    }
    return response;
  }
};
