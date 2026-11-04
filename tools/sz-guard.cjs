'use strict';
// sz-guard.cjs - PatternGuard guard-1.0. Entry BLOCK only, causal, no I/O.
// gate[i] depends only on bars[0..i] / ind[0..i]. forward() is ledger-only and never feeds the gate.
const VERSION = 'guard-1.0';
const PIDS = ['G01', 'G02', 'G03', 'G04', 'G05', 'G06'];
const SIGS = ['higherLow', 'stUp', 'nmacdSig', 'reHigh'];
const ACTIONS = ['rebound', 'blockDay', 'off'];
const META = ['id', 'name', 'note', 'status', 'created', 'validatedOn', 'confirmedOn'];
const DEF = {
  id: 'GP000', name: 'all off',
  session: { openHms: 90000, endHms: 152000, prevCloseHms: 153000 },
  patterns: {
    G01: { enabled: false, action: 'rebound', pct: 2 },                              // one bar close-to-close surge
    G02: { enabled: false, action: 'rebound', winSec: 60, pct: 5 },                  // run from low within winSec
    G03: { enabled: false, action: 'rebound', pct: 5 },                              // gap up vs prev close
    G04: { enabled: false, action: 'rebound', pct: 25 },                             // prev day change >= pct
    G05: { enabled: false, action: 'rebound', viPct: 10, nearPct: 1.5 },             // near static VI price
    G06: { enabled: false, action: 'rebound', gapSec: 100, viPct: 10, refTolPct: 1.5 } // VI resolved (estimated)
  },
  rebound: { coolBars: 3, pbMode: 'pct', pbPct: 1.5, pbBars: 10, signals: ['stUp', 'nmacdSig'], need: 1, clearTTL: 0, onUnsafe: 'keep' },
  ledger: { refireBars: 5, mins: [10, 30, 60], crashPct: 3 }
};
const isObj = v => !!v && typeof v === 'object' && !Array.isArray(v);
function merge(a, b) {
  const o = Object.assign({}, a);
  if (!isObj(b)) return o;
  for (const k of Object.keys(b)) o[k] = isObj(a[k]) && isObj(b[k]) ? merge(a[k], b[k]) : (Array.isArray(b[k]) ? b[k].slice() : b[k]);
  return o;
}
function unknownKeys(u, d, pre) {
  d = d || DEF; pre = pre || ''; const out = [];
  if (!isObj(u)) return out;
  for (const k of Object.keys(u)) {
    if (!pre && META.includes(k)) continue;
    if (!(k in d)) { out.push(pre + k); continue; }
    if (isObj(d[k])) out.push(...unknownKeys(u[k], d[k], pre + k + '.'));
  }
  return out;
}
function validate(G) {
  const e = [], P = G.patterns, R = G.rebound;
  const pos = (v, p) => { if (typeof v !== 'number' || !isFinite(v) || v <= 0) e.push(p); };
  const nn = (v, p) => { if (typeof v !== 'number' || !isFinite(v) || v < 0) e.push(p); };
  for (const p of PIDS) { if (typeof P[p].enabled !== 'boolean') e.push(p + '.enabled'); if (!ACTIONS.includes(P[p].action)) e.push(p + '.action'); }
  pos(P.G01.pct, 'G01.pct'); pos(P.G02.winSec, 'G02.winSec'); pos(P.G02.pct, 'G02.pct'); pos(P.G03.pct, 'G03.pct'); pos(P.G04.pct, 'G04.pct');
  pos(P.G05.viPct, 'G05.viPct'); nn(P.G05.nearPct, 'G05.nearPct'); pos(P.G06.gapSec, 'G06.gapSec'); pos(P.G06.viPct, 'G06.viPct'); nn(P.G06.refTolPct, 'G06.refTolPct');
  nn(R.coolBars, 'rebound.coolBars'); if (!['pct', 'bars'].includes(R.pbMode)) e.push('rebound.pbMode');
  pos(R.pbPct, 'rebound.pbPct'); pos(R.pbBars, 'rebound.pbBars'); nn(R.clearTTL, 'rebound.clearTTL');
  if (!Array.isArray(R.signals) || !R.signals.length || R.signals.some(s => !SIGS.includes(s))) e.push('rebound.signals');
  else if (!Number.isInteger(R.need) || R.need < 1 || R.need > R.signals.length) e.push('rebound.need');
  if (!['keep', 'reset'].includes(R.onUnsafe)) e.push('rebound.onUnsafe');
  nn(G.session.openHms, 'session.openHms'); pos(G.session.endHms, 'session.endHms'); pos(G.session.prevCloseHms, 'session.prevCloseHms');
  nn(G.ledger.refireBars, 'ledger.refireBars'); pos(G.ledger.crashPct, 'ledger.crashPct');
  if (!Array.isArray(G.ledger.mins) || !G.ledger.mins.length || G.ledger.mins.some(m => !(m > 0))) e.push('ledger.mins');
  return e;
}
function load(u) {
  u = u || {};
  const bad = unknownKeys(u);
  if (bad.length) throw new Error('guard: unknown keys ' + bad.join(','));
  const G = merge(DEF, u);
  const e = validate(G);
  if (e.length) throw new Error('guard: invalid ' + e.join(','));
  G.id = u.id || DEF.id; G.name = u.name || G.id;
  return G;
}
const enabledList = G => PIDS.filter(p => G.patterns[p].enabled && G.patterns[p].action !== 'off');
const isPassive = G => enabledList(G).length === 0;
function sec(h) { h = Math.floor(+h); return Math.floor(h / 10000) * 3600 + (Math.floor(h / 100) % 100) * 60 + (h % 100); }
const STN = { C: 'cool', P: 'pb', R: 'rb', B: 'day' };

function computeGate(bars, ind, ctx, G) {
  const N = bars.length, ok = new Uint8Array(N).fill(1), why = new Array(N).fill(null), events = [];
  const diag = { on: enabledList(G), d0: -1, prevClose: null, prevCloseSrc: 'none', dayOpen: null, viEst: 0, missing: [], blocked: 0 };
  if (!diag.on.length) return { ok, why, events, diag };
  const S = G.session, Rb = G.rebound, PT = G.patterns, has = p => diag.on.includes(p);
  let d0 = -1;
  for (let i = 0; i < N; i++) if (bars[i].d === ctx.date && +bars[i].hms >= S.openHms) { d0 = i; break; }
  diag.d0 = d0;
  if (d0 < 0) { diag.missing.push('session_bar'); return { ok, why, events, diag }; }
  let pc = ctx.prevClose == null ? NaN : Number(ctx.prevClose);
  if (isFinite(pc) && pc > 0) diag.prevCloseSrc = 'ctx';
  else {
    pc = null;
    for (let j = d0 - 1; j >= 0; j--) { const b = bars[j]; if (b.d !== ctx.date && +b.hms <= S.prevCloseHms) { pc = +b.c; diag.prevCloseSrc = 'bars:' + b.d + ' ' + b.hms; break; } }
  }
  diag.prevClose = pc;
  let ref = +bars[d0].o; diag.dayOpen = ref;
  const viOn = has('G05') || has('G06');
  let s = 'N', pid = null, cool = 0, pHigh = 0, hiI = -1, pbLow = 0, ttl = 0, prevNear = false;
  const lastEv = {};
  for (let i = d0; i < N; i++) {
    const b = bars[i];
    if (b.d !== ctx.date) continue;
    const hs = +b.hms, inS = hs >= S.openHms && hs < S.endHms;
    const pv = i > d0 && bars[i - 1].d === ctx.date ? bars[i - 1] : null;
    const fired = [];
    if (inS) {
      if (viOn && pv) {
        const q = PT.G06;
        if (sec(hs) - sec(pv.hms) >= q.gapSec && Math.abs(pv.c / ref - 1) * 100 >= q.viPct - q.refTolPct) {
          diag.viEst++; ref = +b.o; if (has('G06')) fired.push('G06');
        }
      }
      if (has('G01') && pv && pv.c > 0 && (b.c / pv.c - 1) * 100 >= PT.G01.pct) fired.push('G01');
      if (has('G02')) {
        const t0 = sec(hs) - PT.G02.winSec; let lo = +b.l;
        for (let j = i - 1; j >= d0 && bars[j].d === ctx.date && sec(bars[j].hms) >= t0; j--) if (bars[j].l < lo) lo = +bars[j].l;
        if (lo > 0 && (b.c / lo - 1) * 100 >= PT.G02.pct) fired.push('G02');
      }
      if (i === d0) {
        if (has('G03')) { if (pc > 0) { if ((b.o / pc - 1) * 100 >= PT.G03.pct) fired.push('G03'); } else diag.missing.push('G03:prevClose'); }
        if (has('G04')) { const c = ctx.prevChg == null ? NaN : Number(ctx.prevChg); if (isFinite(c)) { if (c >= PT.G04.pct) fired.push('G04'); } else diag.missing.push('G04:prevChg'); }
      }
      if (has('G05')) { const vi = ref * (1 + PT.G05.viPct / 100), near = b.h >= vi * (1 - PT.G05.nearPct / 100); if (near && !prevNear) fired.push('G05'); prevNear = near; }
    }
    if (fired.length) {
      const before = s, bd = fired.find(p => PT[p].action === 'blockDay');
      if (s === 'B') { /* stays blocked for the day */ }
      else if (bd) { s = 'B'; pid = bd; }
      else { pid = fired[0]; s = Rb.coolBars > 0 ? 'C' : 'P'; cool = Rb.coolBars; pHigh = +b.h; hiI = i; }
      for (const p of fired) { if (lastEv[p] == null || i - lastEv[p] > G.ledger.refireBars) events.push({ pid: p, i, d: b.d, hms: hs, px: +b.c, state: before }); lastEv[p] = i; }
    } else if (s === 'C') {
      if (b.h > pHigh) { pHigh = +b.h; hiI = i; }
      if (--cool <= 0) s = 'P';
    } else if (s === 'P') {
      if (b.h > pHigh) { pHigh = +b.h; hiI = i; }
      const met = Rb.pbMode === 'pct' ? (pHigh - b.l) / pHigh * 100 >= Rb.pbPct : i - hiI >= Rb.pbBars;
      if (met) { s = 'R'; pbLow = +b.l; }
    } else if (s === 'R') {
      let k = 0;
      for (const g of Rb.signals) {
        let y = false;
        if (g === 'higherLow') y = !!pv && b.l > pbLow && b.c > pv.c;
        else if (g === 'stUp') y = !!ind.stDir && ind.stDir[i] === 1 && ind.st[i] != null && b.c > ind.st[i];
        else if (g === 'nmacdSig') y = !!ind.n && ind.n[i] != null && ind.sig[i] != null && ind.n[i] > ind.sig[i];
        else if (g === 'reHigh') y = b.c >= pHigh;
        if (y) k++;
      }
      if (k >= Rb.need) { s = 'K'; ttl = Rb.clearTTL; } else if (b.l < pbLow) pbLow = +b.l;
    } else if (s === 'K') {
      if (Rb.clearTTL > 0 && --ttl <= 0) { s = 'R'; pbLow = +b.l; }
    }
    if (Rb.onUnsafe === 'reset' && s !== 'N' && s !== 'B' && ind.safe && !ind.safe[i]) { s = 'N'; pid = null; }
    if (s !== 'N' && s !== 'K') { ok[i] = 0; why[i] = pid + '_' + STN[s]; diag.blocked++; }
  }
  return { ok, why, events, diag };
}
const OK = { ok: true };
function makeHook(g) { return (i) => (g.ok[i] ? OK : { ok: false, why: g.why[i] }); }
function forward(bars, events, L) {
  const mins = (L && L.mins) || DEF.ledger.mins, crash = (L && L.crashPct) || DEF.ledger.crashPct, maxS = Math.max(...mins) * 60;
  return events.map(e => {
    const o = Object.assign({}, e), t0 = sec(e.hms), hi = {}, lo = {};
    for (const m of mins) { hi[m] = e.px; lo[m] = e.px; }
    for (let j = e.i + 1; j < bars.length && bars[j].d === e.d; j++) {
      const dt = sec(bars[j].hms) - t0; if (dt > maxS) break;
      for (const m of mins) if (dt <= m * 60) { if (bars[j].h > hi[m]) hi[m] = +bars[j].h; if (bars[j].l < lo[m]) lo[m] = +bars[j].l; }
    }
    for (const m of mins) { o['mfe' + m] = (hi[m] / e.px - 1) * 100; o['mae' + m] = (lo[m] / e.px - 1) * 100; }
    o.crash = mins.includes(30) ? o.mae30 <= -crash : null;
    return o;
  });
}
module.exports = { VERSION, PIDS, SIGS, DEF, load, merge, validate, unknownKeys, enabledList, isPassive, sec, computeGate, makeHook, forward };