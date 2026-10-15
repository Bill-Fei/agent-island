// First-party, aggregate-only website metrics. No cookies or visitor IDs.
(() => {
  'use strict';
  if (navigator.doNotTrack === '1' || navigator.globalPrivacyControl === true) return;
  if (!/^https?:$/.test(location.protocol)) return;
  const test = new URLSearchParams(location.search).get('analytics_test') === '1';
  // Which language version was viewed. The Chinese page reports '' so existing rows stay comparable.
  const page = document.documentElement?.lang?.startsWith('en') ? 'en' : '';
  function send(event, target = '', bucket = '') {
    let source = 'direct';
    try {
      const host = new URL(document.referrer).hostname;
      if (host !== location.hostname) {
        source = /(^|\.)(google\.[a-z.]+|bing\.com|baidu\.com|duckduckgo\.com)$/.test(host) ? 'search'
          : /(^|\.)(t\.co|twitter\.com|x\.com|weibo\.com|bilibili\.com|xiaohongshu\.com|zhihu\.com)$/.test(host) ? 'social' : host;
      }
    } catch { /* Direct visit or restricted referrer. */ }
    const body = JSON.stringify({ event, target, bucket, source, test });
    fetch('/api/analytics', {
      method: 'POST', credentials: 'omit', keepalive: true,
      headers: { 'Content-Type': 'application/json' }, body
    }).catch(() => {}); // Analytics must never block navigation or downloads.
  }
  send('page_view', page);
  const startedAt = typeof performance !== 'undefined' ? performance.now() : Date.now();
  let maxScroll = 0;
  let engagementReported = false;
  function scrollDepth() {
    const root = document.documentElement;
    const max = Math.max(1, root.scrollHeight - window.innerHeight);
    return Math.min(100, Math.round((window.scrollY / max) * 100));
  }
  function reportEngagement() {
    if (engagementReported) return;
    engagementReported = true;
    const now = typeof performance !== 'undefined' ? performance.now() : Date.now();
    const seconds = Math.min(3600, Math.max(0, (now - startedAt) / 1000));
    const timeBucket = seconds < 10 ? '0_9s' : seconds < 30 ? '10_29s' : seconds < 60 ? '30_59s' : '60s_plus';
    const depthBucket = maxScroll >= 90 ? '100' : maxScroll >= 70 ? '75' : maxScroll >= 45 ? '50' : '25';
    send('visible_time', '', timeBucket);
    send('scroll_depth', '', depthBucket);
  }
  if (typeof addEventListener === 'function') {
    addEventListener('scroll', () => { maxScroll = Math.max(maxScroll, scrollDepth()); }, {passive: true});
    addEventListener('pagehide', reportEngagement, { once: true });
  }
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') reportEngagement();
  });
  const filmVideo = document.getElementById?.('filmVideo');
  filmVideo?.addEventListener('ended', () => send('film_complete', '', 'complete'), { once: true });
  document.addEventListener('click', event => {
    const element = event.target.closest?.('a, button, [role="button"]');
    if (!element) return;
    // The inert download button carries aria-disabled, so exempt it from the bail below:
    // a click on it is the whole point of the download_blocked signal.
    const blockedDownload = element.matches('[data-download]') && !window.SITE?.dmgUrl;
    if (!blockedDownload && element.getAttribute('aria-disabled') === 'true') return;
    if (element.matches('[data-download]')) {
      // Someone wanted the app and got nothing — the strongest demand signal the site can
      // see. Record it rather than dropping it.
      if (blockedDownload) { send('click', 'download_blocked'); return; }
      send('click', element.id === 'dmgLink' ? 'download_section'
        : element.classList.contains('menubar-download') ? 'download_menu' : 'download_hero');
    } else if (element.id === 'mirrorLink') send('click', 'download_mirror');
    else if (element.id === 'filmPlay') send('click', 'film_play');
    else if (element.id === 'sourceLink') send('click', 'source');
    else if (element.id === 'island') send('click', 'island_demo');
    else if (element.matches('[data-lang-switch]')) send('click', 'lang_switch');
    else if (element.matches('[data-lang-hint]')) send('click', 'lang_hint');
    else if (element.matches('[data-lang-hint-close]')) send('click', 'lang_hint_close');
    else {
      const section = element.getAttribute('href');
      if (['#film', '#states', '#privacy', '#agents', '#top'].includes(section)) send('click', section.slice(1));
    }
  });
})();
