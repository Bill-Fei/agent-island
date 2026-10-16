// Live demo island + small page wiring. No dependencies.
(() => {
  'use strict';

  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  // One script serves both language versions; the page's lang attribute picks the strings.
  const EN = document.documentElement.lang.startsWith('en');

  /* ---------- release links ---------- */
  const SITE = window.SITE || {};
  // Path back to the site root: '' on the Chinese page, '../' on /en/.
  const ROOT = SITE.root || '';
  const dmg = document.getElementById('dmgLink');
  if (SITE.dmgUrl) {
    document.querySelectorAll('[data-download]').forEach(a => { a.href = SITE.dmgUrl; });
    document.getElementById('pending').hidden = true;
  } else {
    // No published build yet: keep the main button visible but inert, and say why.
    dmg.setAttribute('aria-disabled', 'true');
    dmg.removeAttribute('href');
  }
  if (SITE.mirrorUrl) { const m = document.getElementById('mirrorLink'); m.href = SITE.mirrorUrl; m.hidden = false; }
  if (SITE.sourceUrl) { document.getElementById('sourceLink').href = SITE.sourceUrl; document.getElementById('sourceNote').hidden = false; }
  document.querySelectorAll('[data-version]').forEach(n => { n.textContent = SITE.version || n.textContent; });

  /* ---------- language hint ----------
     Chinese page only. Offer English when none of the browser's languages is Chinese: a
     Chinese reader with an English system usually still lists zh, and should not be asked.
     Never redirects — shared links must open the page they point to. Any answer (follow the
     hint, close it, or pick a language from the menu bar) is remembered on this device only. */
  const HINT_KEY = 'island_lang_hint';
  const remember = () => { try { localStorage.setItem(HINT_KEY, '1'); } catch { /* storage off */ } };
  const answered = () => { try { return localStorage.getItem(HINT_KEY) === '1'; } catch { return false; } };
  document.querySelectorAll('[data-lang-switch]').forEach(a => a.addEventListener('click', remember));
  const hint = document.getElementById('langHint');
  if (hint) {
    const langs = navigator.languages?.length ? navigator.languages : [navigator.language || ''];
    const readsChinese = langs.some(l => /^zh(-|$)/i.test(l));
    if (!answered() && !readsChinese) {
      // Let the hero land first, so the hint reads as an offer rather than part of the page.
      // Re-check on firing: the visitor may have picked a language in the meantime.
      setTimeout(() => { if (!answered()) hint.hidden = false; }, 1200);
    }
    hint.querySelector('[data-lang-hint]').addEventListener('click', remember);
    hint.querySelector('[data-lang-hint-close]').addEventListener('click', () => { hint.hidden = true; remember(); });
  }

  /* ---------- menu bar clock ---------- */
  const clock = document.getElementById('clock');
  const DAYS = EN ? ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] : [...'日一二三四五六'].map(d => `周${d}`);
  const tick = () => {
    const d = new Date();
    clock.textContent = `${DAYS[d.getDay()]} ${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
  };
  tick(); setInterval(tick, 15000);

  /* ---------- film ---------- */
  const video = document.getElementById('filmVideo');
  const play = document.getElementById('filmPlay');
  play.addEventListener('click', () => {
    play.hidden = true;
    video.controls = true;
    video.play();
  });

  /* ---------- island ---------- */
  const ICON = k => `${ROOT}media/icons/${k}.png`;
  const EVENTS = [
    { agent: 'claude', stack: ['claude', 'codex', 'doubao'], title: EN ? 'Refactor login' : '重构登录模块', status: EN ? 'Done' : '已完成', color: '#87c7ab', glow: 'rgba(135,199,171,.28)' },
    { agent: 'codex', stack: ['codex', 'claude', 'workbuddy'], title: EN ? 'Database migration' : '数据库迁移', status: EN ? 'Needs you' : '等你批准', color: '#e8b080', glow: 'rgba(232,176,128,.28)' }
  ];

  // Geometry of each state, in app points (same values as the app / film).
  const SHAPES = {
    small: { w: 290, h: 34, r: 12, sh: 7 },
    med: { w: 520, h: 34, r: 12, sh: 7 },
    panel: { w: 640, h: 452, r: 30, sh: 10 }
  };

  const parts = el => ({
    el,
    shape: el.querySelector('.island-shape'),
    path: el.querySelector('.island-shape path'),
    body: el.querySelector('.island-body'),
    glow: el.querySelector('.island-glow'),
    smallIcon: el.querySelector('.i-small-icon'),
    stack: el.querySelectorAll('.i-stack img'),
    medTitle: el.querySelector('.i-med-title'),
    medStatus: el.querySelector('.i-med-status')
  });

  function notchPath(w, h, sh, r) {
    // Same construction as the app: concave shoulders into the top edge, rounded bottom corners.
    const minX = 0, maxX = w + 2 * sh, left = sh, right = w + sh, top = -1, maxY = h;
    r = Math.min(r, h - sh, w / 2);
    return `M${minX} ${top}Q${left} ${top} ${left} ${top + sh}L${left} ${maxY - r}Q${left} ${maxY} ${left + r} ${maxY}` +
      `L${right - r} ${maxY}Q${right} ${maxY} ${right} ${maxY - r}L${right} ${top + sh}Q${right} ${top} ${maxX} ${top}Z`;
  }

  function paint(p, { w, h, r, sh }) {
    const W = w + 2 * sh;
    p.shape.setAttribute('width', W.toFixed(2));
    p.shape.setAttribute('height', (h + 1).toFixed(2));
    p.path.setAttribute('d', notchPath(w, h, sh, r));
    const k = Math.max(0, Math.min(1, (h - 40) / 120));
    p.shape.style.filter = k > 0 ? `drop-shadow(0 ${18 * k}px ${46 * k}px rgba(4,20,22,${.36 * k}))` : '';
    p.body.style.left = sh + 'px';
    p.body.style.width = w + 'px';
    p.body.style.height = h + 'px';
    p.body.style.borderRadius = `0 0 ${r}px ${r}px`;
    p.glow.style.left = W / 2 + 'px';
    p.el.style.width = W + 'px';
    p.el.style.height = h + 'px';
  }

  function showEvent(p, e) {
    p.stack.forEach((img, i) => { img.src = ICON(e.stack[i]); });
    p.medTitle.textContent = e.title;
    p.medStatus.querySelector('span').textContent = e.status;
    p.medStatus.style.setProperty('--ev', e.color);
    p.glow.style.background = `radial-gradient(320px 320px at 50% 30px, ${e.glow}, transparent 70%)`;
    p.smallIcon.src = ICON(e.agent);
  }

  const live = parts(document.getElementById('island'));
  const root = live.el;

  // Scale for narrow screens: the bar states shrink a little, the panel fits the viewport.
  const baseScale = () => (innerWidth < 760 ? .74 : 1);
  // On desktop the panel keeps the share of the screen it has on a 14" MacBook (1512 pt wide).
  const panelScale = () => Math.min(1, (innerWidth - 16) / 640, Math.max(.8, innerWidth / 1512));
  // The expanded bar never covers the menu bar's own links: it takes whatever room is left between them.
  const menuLeft = document.querySelector('.menubar-app');
  const menuNav = document.querySelector('.menubar-menu');
  const menuRight = document.querySelector('.menubar-right');
  const menuLang = document.querySelector('.menubar-lang');
  function medWidth() {
    // On phones the language switch moves to the left half (style.css); count it there too.
    const lang = menuLang?.getBoundingClientRect();
    const langLeft = lang && lang.right < innerWidth / 2 ? lang.right : 0;
    const leftEdge = Math.max(menuLeft.getBoundingClientRect().right, menuNav.getBoundingClientRect().right, langLeft);
    const clear = Math.max(leftEdge, innerWidth - menuRight.getBoundingClientRect().left) + 12;
    return Math.max(290, Math.min(520, (innerWidth - 2 * clear) / baseScale() - 14));
  }

  // Damped springs for w / h / r / sh / scale.
  const keys = ['w', 'h', 'r', 'sh', 's'];
  const cur = { ...SHAPES.small, s: baseScale() };
  const vel = { w: 0, h: 0, r: 0, sh: 0, s: 0 };
  let target = { ...cur };
  let raf = 0, last = 0;

  function draw() {
    paint(live, cur);
    root.style.transform = `translateX(-50%) scale(${cur.s})`;
  }

  function step(now) {
    const dt = Math.min(1 / 30, (now - last) / 1000 || 1 / 60);
    last = now;
    let moving = false;
    for (const key of keys) {
      // Stiffness / damping tuned to land with a small overshoot, like the app's spring.
      const k = key === 'h' ? 210 : 260, c = 2 * Math.sqrt(k) * (key === 'h' ? .8 : .68);
      const a = -k * (cur[key] - target[key]) - c * vel[key];
      vel[key] += a * dt;
      cur[key] += vel[key] * dt;
      if (Math.abs(vel[key]) > .01 || Math.abs(cur[key] - target[key]) > .01) moving = true;
    }
    if (!moving) for (const key of keys) { cur[key] = target[key]; vel[key] = 0; }
    draw();
    raf = moving ? requestAnimationFrame(step) : 0;
  }

  function goTo(name) {
    const g = { ...SHAPES[name] };
    if (name === 'med') g.w = medWidth();
    g.s = name === 'panel' ? panelScale() : baseScale();
    target = g;
    if (reduced.matches) { Object.assign(cur, target); draw(); return; }
    if (!raf) { last = performance.now(); raf = requestAnimationFrame(step); }
  }

  let state = 'small';
  // True once the hero has scrolled away: the live island is only a hero piece, so it steps aside.
  let away = false;
  function setState(name) {
    state = name;
    root.dataset.state = name;
    root.setAttribute('aria-expanded', String(name === 'panel'));
    goTo(name);
  }

  /* Idle cycle: small → event → small → next event … Pauses while the panel is open.
     Kept unhurried on purpose: the real app only speaks up when something happens. */
  const HOLD_MED = 5200, HOLD_SMALL = 9000;
  let cycleTimer = 0, evIndex = 0;
  function scheduleCycle(delay) {
    clearTimeout(cycleTimer);
    if (reduced.matches) return;
    cycleTimer = setTimeout(() => {
      if (state === 'panel' || away) return;
      if (state === 'small') {
        showEvent(live, EVENTS[evIndex]);
        evIndex = (evIndex + 1) % EVENTS.length;
        setState('med');
        scheduleCycle(HOLD_MED);
      } else {
        setState('small');
        scheduleCycle(HOLD_SMALL);
      }
    }, delay);
  }

  /* Hover 0.2 s to open, leave to close — same rule as the app. Click / Enter toggles for touch and keyboard. */
  let hoverTimer = 0, closeTimer = 0;
  function open() {
    clearTimeout(cycleTimer); clearTimeout(closeTimer);
    if (state !== 'panel') setState('panel');
  }
  function close() {
    clearTimeout(hoverTimer);
    if (state !== 'panel') return;
    // Content fades first, then the shape follows.
    root.dataset.state = 'closing';
    closeTimer = setTimeout(() => { setState('small'); scheduleCycle(4000); }, 90);
  }
  root.addEventListener('pointerenter', e => {
    if (e.pointerType !== 'mouse') return;
    clearTimeout(closeTimer);
    hoverTimer = setTimeout(open, 200);
  });
  root.addEventListener('pointerleave', e => {
    if (e.pointerType !== 'mouse') return;
    clearTimeout(hoverTimer);
    close();
  });
  root.addEventListener('click', () => { state === 'panel' ? close() : open(); });
  root.addEventListener('keydown', e => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); state === 'panel' ? close() : open(); }
    if (e.key === 'Escape') close();
  });
  document.addEventListener('pointerdown', e => { if (!root.contains(e.target)) close(); });

  /* ---------- static pictures of each state (hero screen + states section) ---------- */
  showEvent(live, EVENTS[0]);
  const demos = [...document.querySelectorAll('[data-demo]')].map(box => {
    const name = box.dataset.demo;
    const el = document.createElement('div');
    el.className = 'island island-static';
    el.dataset.state = name;
    el.setAttribute('aria-hidden', 'true');
    el.innerHTML = '<div class="island-glow"></div><svg class="island-shape"><path/></svg>';
    el.appendChild(live.body.cloneNode(true));
    box.appendChild(el);
    const p = parts(el);
    showEvent(p, EVENTS[name === 'small' ? 0 : 1]);
    return { box, name, p };
  });
  function fitDemos() {
    for (const { box, name, p } of demos) {
      const W = box.clientWidth;
      const g = { ...SHAPES[name] };
      let k;
      if (box.dataset.fit === 'hero') {
        // Hero screen: drawn as a 14" MacBook screen (1512 pt wide), so the island sits at its true size.
        // Phones get a little more room, or the panel would be too small to make out.
        k = W / (W < 500 ? 1000 : 1512);
      } else if (name === 'panel') {
        // On phones the picture can run closer to the edges.
        k = Math.min(1, W / (W < 500 ? 690 : 820));
        box.style.height = (g.h + 64) * k + 'px';
      } else {
        k = Math.min(1, W / 420);
        if (name === 'med') g.w = Math.min(520, W / k - 48);
      }
      box.style.setProperty('--k', k);
      paint(p, g);
    }
  }

  /* ---------- menu bar tint follows the section underneath ---------- */
  const menubar = document.querySelector('.menubar');
  const darkZones = [...document.querySelectorAll('.tone-dark')];
  const hero = document.querySelector('.hero');
  function onScroll() {
    root.classList.toggle('is-scrolled', scrollY > innerHeight * .5);
    // Hide the live island once most of the hero is gone; bring it back, quiet, on the way up.
    const nowAway = hero.getBoundingClientRect().bottom < innerHeight * .4;
    if (nowAway !== away) {
      away = nowAway;
      root.classList.toggle('is-away', away);
      if (away) {
        clearTimeout(cycleTimer); clearTimeout(hoverTimer); clearTimeout(closeTimer);
        root.blur();
        setState('small');
      } else {
        scheduleCycle(2400);
      }
    }
    menubar.classList.toggle('is-dark', darkZones.some(z => {
      const r = z.getBoundingClientRect();
      return r.top <= 16 && r.bottom > 16;
    }));
  }

  addEventListener('resize', () => { goTo(state === 'closing' ? 'small' : state); fitDemos(); onScroll(); });
  addEventListener('scroll', onScroll, { passive: true });
  reduced.addEventListener?.('change', () => { if (!reduced.matches) scheduleCycle(1500); });

  fitDemos();
  onScroll();
  setState('small');
  Object.assign(cur, target); draw();
  scheduleCycle(3200);
})();
