// First-party, aggregate-only website metrics. No cookies or visitor IDs.
(() => {
  'use strict';
  if (navigator.doNotTrack === '1' || navigator.globalPrivacyControl === true) return;
  if (!/^https?:$/.test(location.protocol)) return;
  const test = new URLSearchParams(location.search).get('analytics_test') === '1';
  function send(event, target = '') {
    let source = 'direct';
    try {
      const host = new URL(document.referrer).hostname;
      if (host !== location.hostname) {
        source = /(^|\.)(google\.[a-z.]+|bing\.com|baidu\.com|duckduckgo\.com)$/.test(host) ? 'search'
          : /(^|\.)(t\.co|twitter\.com|x\.com|weibo\.com|bilibili\.com|xiaohongshu\.com|zhihu\.com)$/.test(host) ? 'social' : 'other';
      }
    } catch { /* Direct visit or restricted referrer. */ }
    const body = JSON.stringify({ event, target, source, test });
    fetch('/api/analytics', {
      method: 'POST', credentials: 'omit', keepalive: true,
      headers: { 'Content-Type': 'application/json' }, body
    }).catch(() => {}); // Analytics must never block navigation or downloads.
  }
  send('page_view');
  document.addEventListener('click', event => {
    const element = event.target.closest?.('a, button, [role="button"]');
    if (!element || element.getAttribute('aria-disabled') === 'true') return;
    if (element.matches('[data-download]')) {
      if (!window.SITE?.dmgUrl) return;
      send('click', element.id === 'dmgLink' ? 'download_section'
        : element.classList.contains('menubar-download') ? 'download_menu' : 'download_hero');
    } else if (element.id === 'mirrorLink') send('click', 'download_mirror');
    else if (element.id === 'filmPlay') send('click', 'film_play');
    else if (element.id === 'sourceLink') send('click', 'source');
    else if (element.id === 'island') send('click', 'island_demo');
    else {
      const section = element.getAttribute('href');
      if (['#film', '#states', '#privacy', '#agents', '#top'].includes(section)) send('click', section.slice(1));
    }
  });
})();
