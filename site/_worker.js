// Pages advanced-mode worker: assets + first-party aggregate analytics.
const TARGETS = new Set(['download_section', 'download_menu', 'download_hero', 'download_mirror',
  'download_blocked', 'film_play', 'source', 'island_demo', 'film', 'states', 'privacy', 'agents', 'top',
  'lang_switch', 'lang_hint', 'lang_hint_close']);
// page_view target = which language version was viewed; '' is the Chinese page.
const PAGES = new Set(['', 'en']);
const SOURCES = new Set(['direct', 'search', 'social', 'other']);
const ENGAGEMENT = new Set(['visible_time', 'scroll_depth', 'film_complete']);
const VISIBLE_BUCKETS = new Set(['0_9s', '10_29s', '30_59s', '60s_plus']);
const SCROLL_BUCKETS = new Set(['25', '50', '75', '100']);
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
async function recordEngagement(env, request, metric, bucket, test) {
  if (!env.ANALYTICS_DB) throw new Error('Analytics binding missing');
  const day = new Date().toISOString().slice(0, 10);
  const cutoff = new Date(Date.now() - 89 * 86400000).toISOString().slice(0, 10);
  await env.ANALYTICS_DB.batch([
    env.ANALYTICS_DB.prepare(`INSERT INTO engagement_metrics(day,metric,bucket,traffic,count)
      VALUES(?,?,?,?,1) ON CONFLICT(day,metric,bucket,traffic)
      DO UPDATE SET count=count+1`).bind(day, metric, bucket, test ? 'test' : 'visitor'),
    env.ANALYTICS_DB.prepare('DELETE FROM engagement_metrics WHERE day < ?').bind(cutoff)
  ]);
}
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === '/api/analytics/stats') {
      // Token-protected read API for the dashboard (GET only, no request body, read-only).
      if (request.method !== 'GET') return reply(405);
      const token = url.searchParams.get('token') || '';
      if (!env.STATS_TOKEN || token !== env.STATS_TOKEN) return reply(401);
      const days = Math.min(Math.max(parseInt(url.searchParams.get('days') || '7', 10) || 7, 1), 90);
      const start = new Date(Date.now() - (days - 1) * 86400000).toISOString().slice(0, 10);
      let rows;
      try {
        rows = await env.ANALYTICS_DB.batch([
          env.ANALYTICS_DB.prepare(`SELECT COALESCE(SUM(count),0) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor'`).bind(),
          env.ANALYTICS_DB.prepare(`SELECT COALESCE(SUM(count),0) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor' AND day>=?`).bind(start),
          env.ANALYTICS_DB.prepare(`SELECT day, SUM(count) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor' AND day>=? GROUP BY day ORDER BY day`).bind(start),
          env.ANALYTICS_DB.prepare(`SELECT COALESCE(SUM(count),0) AS c FROM daily_metrics WHERE event='download_request' AND traffic='visitor'`).bind(),
          env.ANALYTICS_DB.prepare(`SELECT COALESCE(SUM(count),0) AS c FROM daily_metrics WHERE event='download_request' AND traffic='visitor' AND day>=?`).bind(start),
          env.ANALYTICS_DB.prepare(`SELECT day, SUM(count) AS c FROM daily_metrics WHERE event='download_request' AND traffic='visitor' AND day>=? GROUP BY day ORDER BY day`).bind(start),
          env.ANALYTICS_DB.prepare(`SELECT target, SUM(count) AS c FROM daily_metrics WHERE event='click' AND traffic='visitor' GROUP BY target ORDER BY c DESC LIMIT 8`).bind(),
          env.ANALYTICS_DB.prepare(`SELECT device, SUM(count) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor' GROUP BY device ORDER BY c DESC`).bind(),
          env.ANALYTICS_DB.prepare(`SELECT country, SUM(count) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor' GROUP BY country ORDER BY c DESC LIMIT 10`).bind(),
          env.ANALYTICS_DB.prepare(`SELECT source, SUM(count) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor' GROUP BY source ORDER BY c DESC`).bind()
          ,env.ANALYTICS_DB.prepare(`SELECT metric,bucket,SUM(count) AS c FROM engagement_metrics WHERE traffic='visitor' AND day>=? GROUP BY metric,bucket ORDER BY metric,bucket`).bind(start)
          ,env.ANALYTICS_DB.prepare(`SELECT target AS page, SUM(count) AS c FROM daily_metrics WHERE event='page_view' AND traffic='visitor' GROUP BY target ORDER BY c DESC`).bind()
        ]);
      } catch { return reply(503); }
      const val = (i) => rows[i].results?.[0]?.c ?? 0;
      const pvTotal = val(0), dlTotal = val(3);
      return new Response(JSON.stringify({
        days, start, generated_at: new Date().toISOString(),
        pageviews: pvTotal,
        pageviews_days: val(1),
        downloads: dlTotal,
        downloads_days: val(4),
        download_rate: pvTotal ? Math.round(dlTotal / pvTotal * 1000) / 10 : 0,
        daily_pageviews: rows[2].results || [],
        daily_downloads: rows[5].results || [],
        clicks: rows[6].results || [],
        devices: rows[7].results || [],
        countries: rows[8].results || [],
        sources: rows[9].results || [],
        engagement: rows[10].results || [],
        pages: rows[11].results || []
      }), { status: 200, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' } });
    }
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
      if (!data || !['page_view', 'click', ...ENGAGEMENT].includes(data.event)) return reply(400);
      if (typeof data.source !== 'string' || data.source.length < 1 || data.source.length > 120
        || !/^[A-Za-z0-9.\-_]+$/.test(data.source) || typeof data.test !== 'boolean') return reply(400);
      if (data.event === 'click' && !TARGETS.has(data.target)) return reply(400);
      if (ENGAGEMENT.has(data.event)) {
        const bucket = typeof data.bucket === 'string' ? data.bucket : '';
        const valid = data.event === 'visible_time' ? VISIBLE_BUCKETS : data.event === 'scroll_depth' ? SCROLL_BUCKETS : new Set(['complete']);
        if (!valid.has(bucket)) return reply(400);
        try { await recordEngagement(env, request, data.event, bucket, data.test); return reply(204); }
        catch { return reply(503); }
      }
      try {
        // Unknown page values fall back to '' rather than rejecting the hit: an old cached
        // analytics.js must never lose a page view.
        const target = data.event === 'click' ? data.target : PAGES.has(data.target) ? data.target : '';
        await record(env, request, data.event, target, data.source, data.test);
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
