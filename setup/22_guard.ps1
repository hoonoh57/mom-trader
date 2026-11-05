#requires -Version 5.1
# 22_guard.ps1 - PatternGuard guard-1.0: module + selftest + profiles. ASCII only. Engines untouched.
param([string]$Root = 'E:\parent\projects\rea\projects\mom-trader')
$ErrorActionPreference = 'Stop'
function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Put($rel, $text) {
  $p = Join-Path $Root $rel
  $d = Split-Path $p -Parent
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  if (Test-Path $p) { Copy-Item $p "$p.bak22" -Force }
  [IO.File]::WriteAllText($p, $text, $utf8)
  if ([IO.File]::ReadAllText($p, $utf8) -ne $text) { throw "write verify failed: $rel" }
}
Write-Host '=== mom-trader PatternGuard (guard-1.0) ==='

$guard = @'
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
'@

$selftest = @'
'use strict';
// sz-guard-selftest.cjs - guard-1.0 selftest. Usage: node sz-guard-selftest.cjs <profiles dir>
const fs = require('fs'), path = require('path');
const G = require(path.join(__dirname, 'sz-guard.cjs'));
let pass = 0, fail = 0;
function t(name, fn) {
  try { const r = fn(); if (r === true) pass++; else { fail++; console.log('  FAIL ' + name + ' :: ' + r); } }
  catch (e) { fail++; console.log('  FAIL ' + name + ' :: EXC ' + e.message); }
}
const D = '20261103';
function B(d, hms, o, h, l, c) { return { d, hms, t: 0, o, h, l, c, v: 1000 }; }
function seqBars() {
  return [
    B('20261102', 152900, 1000, 1000, 1000, 1000), B('20261102', 153000, 1000, 1000, 1000, 1000),
    B(D, 90000, 1000, 1002, 998, 1000), B(D, 90010, 1000, 1001, 999, 1000),
    B(D, 90020, 1000, 1035, 1000, 1030), B(D, 90030, 1030, 1032, 1025, 1028),
    B(D, 90040, 1028, 1030, 1022, 1025), B(D, 90050, 1025, 1026, 1018, 1020),
    B(D, 90100, 1020, 1021, 1015, 1016), B(D, 90110, 1016, 1023, 1016, 1022),
    B(D, 90120, 1022, 1023, 1021, 1022), B(D, 90130, 1022, 1023, 1021, 1022), B(D, 90140, 1022, 1023, 1021, 1022)
  ];
}
function fakeInd(bars, down) {
  const ind = { safe: [], st: [], stDir: [], n: [], sig: [] };
  for (let i = 0; i < bars.length; i++) { ind.safe.push(true); ind.st.push(1000); ind.stDir.push(down && down.includes(i) ? -1 : 1); ind.n.push(0.1); ind.sig.push(0); }
  return ind;
}
const eqWhy = (got, exp) => { for (let i = 0; i < exp.length; i++) if (got[i] !== exp[i]) return 'bar ' + i + ' got ' + got[i] + ' exp ' + exp[i]; return true; };
const SEQ = { patterns: { G01: { enabled: true } }, rebound: { coolBars: 2, pbPct: 1.5, signals: ['stUp'], need: 1 } };
const n_ = null;

t('GP000 passive: all ok, no events', () => {
  const b = seqBars(), r = G.computeGate(b, fakeInd(b), { date: D }, G.load({}));
  return (r.ok.every(x => x === 1) && r.events.length === 0) || 'blocked=' + r.diag.blocked + ' ev=' + r.events.length;
});
t('G01 sequence cool->pb->rb->clear', () => {
  const b = seqBars(), r = G.computeGate(b, fakeInd(b, [7, 8]), { date: D }, G.load(SEQ));
  return eqWhy(r.why, [n_, n_, n_, n_, 'G01_cool', 'G01_cool', 'G01_pb', 'G01_rb', 'G01_rb', n_, n_, n_, n_]);
});
t('G01 event recorded once at bar 4', () => {
  const b = seqBars(), r = G.computeGate(b, fakeInd(b, [7, 8]), { date: D }, G.load(SEQ));
  return (r.events.length === 1 && r.events[0].pid === 'G01' && r.events[0].i === 4 && r.events[0].px === 1030) || JSON.stringify(r.events);
});
t('clearTTL 2 -> back to rebound wait', () => {
  const b = seqBars(), g = G.load(G.merge(SEQ, { rebound: { clearTTL: 2 } }));
  const r = G.computeGate(b, fakeInd(b, [7, 8]), { date: D }, g);
  return eqWhy(r.why, [n_, n_, n_, n_, 'G01_cool', 'G01_cool', 'G01_pb', 'G01_rb', 'G01_rb', n_, n_, 'G01_rb', n_]);
});
t('blockDay blocks rest of day', () => {
  const b = seqBars(), r = G.computeGate(b, fakeInd(b), { date: D }, G.load({ patterns: { G01: { enabled: true, action: 'blockDay' } } }));
  return eqWhy(r.why, [n_, n_, n_, n_].concat(new Array(9).fill('G01_day')));
});
function gapBars(open) {
  return [B('20261102', 152900, 1000, 1000, 1000, 1000), B('20261102', 153000, 1000, 1000, 1000, 1000), B('20261102', 160000, 1100, 1100, 1100, 1100),
    B(D, 90000, open, open + 2, open - 2, open), B(D, 90010, open, open + 1, open - 1, open)];
}
t('G03 gap uses prev close <= 15:30 (skips after-hours)', () => {
  const b = gapBars(1060), r = G.computeGate(b, fakeInd(b), { date: D }, G.load({ patterns: { G03: { enabled: true } } }));
  return (r.events.length === 1 && r.events[0].pid === 'G03' && r.diag.prevCloseSrc === 'bars:20261102 153000') || JSON.stringify(r.diag) + ' ev=' + r.events.length;
});
t('G03 ctx.prevClose overrides bars', () => {
  const b = gapBars(1060), r = G.computeGate(b, fakeInd(b), { date: D, prevClose: 1050 }, G.load({ patterns: { G03: { enabled: true } } }));
  return (r.events.length === 0 && r.diag.prevCloseSrc === 'ctx') || JSON.stringify(r.diag);
});
t('G04 prev day surge fires at open', () => {
  const b = gapBars(1000), r = G.computeGate(b, fakeInd(b), { date: D, prevChg: 30 }, G.load({ patterns: { G04: { enabled: true } } }));
  return (r.events.length === 1 && r.events[0].pid === 'G04' && r.events[0].i === 3) || JSON.stringify(r.events);
});
t('G04 missing prevChg reported, no fire', () => {
  const b = gapBars(1000), r = G.computeGate(b, fakeInd(b), { date: D }, G.load({ patterns: { G04: { enabled: true } } }));
  return (r.events.length === 0 && r.diag.missing.includes('G04:prevChg')) || JSON.stringify(r.diag);
});
t('G05 near VI then G06 VI resolve resets ref', () => {
  const b = [B('20261102', 153000, 1000, 1000, 1000, 1000),
    B(D, 90000, 1000, 1000, 1000, 1000), B(D, 90010, 1000, 1050, 1000, 1050), B(D, 90020, 1050, 1090, 1050, 1088),
    B(D, 90230, 1100, 1105, 1095, 1100), B(D, 90240, 1100, 1102, 1098, 1100)];
  const r = G.computeGate(b, fakeInd(b), { date: D }, G.load({ patterns: { G05: { enabled: true }, G06: { enabled: true } } }));
  const s = r.events.map(e => e.pid + '@' + e.i).join(',');
  return (s === 'G05@3,G06@4' && r.diag.viEst === 1) || s + ' viEst=' + r.diag.viEst;
});
t('ledger forward mfe/mae/crash', () => {
  const b = seqBars(), r = G.computeGate(b, fakeInd(b, [7, 8]), { date: D }, G.load(SEQ));
  const f = G.forward(b, r.events, { mins: [10, 30, 60], crashPct: 1 })[0];
  return (Math.abs(f.mae10 - (1015 / 1030 - 1) * 100) < 1e-9 && Math.abs(f.mfe10 - (1032 / 1030 - 1) * 100) < 1e-9 && f.crash === true) || JSON.stringify(f);
});
function rng(s) { return function () { s |= 0; s = s + 0x6D2B79F5 | 0; let x = Math.imul(s ^ s >>> 15, 1 | s); x = x + Math.imul(x ^ x >>> 7, 61 | x) ^ x; return ((x ^ x >>> 14) >>> 0) / 4294967296; }; }
const hmsOf = s => Math.floor(s / 3600) * 10000 + Math.floor(s % 3600 / 60) * 100 + s % 60;
function synth(seed) {
  const r = rng(seed), bars = []; let px = 1000;
  for (let k = 0; k < 30; k++) bars.push(B('20261102', hmsOf(14 * 3600 + 50 * 60 + k * 30), px, px, px, px));
  let ts = 9 * 3600;
  for (let k = 0; k < 400; k++) {
    if (k) ts += 5 + Math.floor(r() * 20) + (r() < 0.01 ? 120 : 0);
    let ret = (r() - 0.48) * 0.006; if (r() < 0.02) ret += 0.03;
    const o = px, c = px * (1 + ret);
    bars.push(B(D, hmsOf(ts), o, Math.max(o, c) * (1 + r() * 0.002), Math.min(o, c) * (1 - r() * 0.002), c)); px = c;
  }
  const ind = { safe: [], st: [], stDir: [], n: [], sig: [] };
  for (let i = 0; i < bars.length; i++) {
    const c = bars[i].c, c3 = bars[Math.max(0, i - 3)].c, c5 = bars[Math.max(0, i - 5)].c;
    ind.safe.push(r() > 0.1); ind.st.push(c * 0.99); ind.stDir.push(c >= c3 ? 1 : -1); ind.n.push(c / c5 - 1); ind.sig.push(0);
  }
  return { bars, ind };
}
for (const seed of [1, 2, 3]) t('no look-ahead (truncation) seed ' + seed, () => {
  const x = synth(seed), ctx = { date: D, prevChg: 30 };
  const g = G.load({ patterns: { G01: { enabled: true }, G02: { enabled: true }, G03: { enabled: true, pct: 0.0001 }, G04: { enabled: true }, G05: { enabled: true }, G06: { enabled: true } },
    rebound: { onUnsafe: seed === 3 ? 'reset' : 'keep', signals: ['stUp', 'nmacdSig', 'higherLow'], need: 2, clearTTL: seed === 2 ? 5 : 0 } });
  const full = G.computeGate(x.bars, x.ind, ctx, g);
  if (full.events.length < 3) return 'too few events ' + full.events.length;
  const d0 = full.diag.d0;
  for (const k of [d0 + 10, d0 + 57, d0 + 150, d0 + 299, x.bars.length - 2]) {
    const bs = x.bars.slice(0, k + 1), is = {};
    for (const key of Object.keys(x.ind)) is[key] = x.ind[key].slice(0, k + 1);
    const part = G.computeGate(bs, is, ctx, g);
    for (let i = 0; i <= k; i++) if (full.ok[i] !== part.ok[i] || full.why[i] !== part.why[i]) return 'cut ' + k + ' bar ' + i + ' ' + full.why[i] + ' vs ' + part.why[i];
    if (JSON.stringify(full.events.filter(e => e.i <= k)) !== JSON.stringify(part.events)) return 'cut ' + k + ' events differ';
  }
  return true;
});
const throws = (u, s) => { try { G.load(u); return 'no throw'; } catch (e) { return e.message.includes(s) || e.message; } };
t('validate unknown key', () => throws({ patterns: { G01: { foo: 1 } } }, 'patterns.G01.foo'));
t('validate need > signals', () => throws({ rebound: { signals: ['stUp'], need: 2 } }, 'rebound.need'));
t('validate bad action', () => throws({ patterns: { G02: { action: 'x' } } }, 'G02.action'));
t('profiles load (GP000 passive, others active)', () => {
  const dir = process.argv[2]; if (!dir || !fs.existsSync(dir)) return 'profiles dir missing: ' + dir;
  const fl = fs.readdirSync(dir).filter(f => /^GP\d+\.json$/.test(f)).sort(); if (!fl.length) return 'no GP*.json';
  for (const f of fl) {
    const u = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8').replace(/^\uFEFF/, '')), g = G.load(u), id = f.replace('.json', '');
    if (g.id !== id) return f + ' id ' + g.id;
    if ((id === 'GP000') !== G.isPassive(g)) return id + ' passive=' + G.isPassive(g);
    console.log('    profile ' + id + ' on=[' + G.enabledList(g).join(' ') + '] need=' + g.rebound.need);
  }
  return true;
});
console.log((fail ? 'SELFTEST FAIL ' : 'SELFTEST OK ') + pass + '/' + (pass + fail) + ' (' + G.VERSION + ')');
process.exit(fail ? 1 : 0);
'@

$profiles = [ordered]@{
  'GP000' = '{ "id": "GP000", "name": "all off (S000 parity)" }'
  'GP001' = '{ "id": "GP001", "name": "G01 tick-bar surge", "patterns": { "G01": { "enabled": true } } }'
  'GP002' = '{ "id": "GP002", "name": "G02 1-min run", "patterns": { "G02": { "enabled": true } } }'
  'GP003' = '{ "id": "GP003", "name": "G03 gap up", "patterns": { "G03": { "enabled": true } } }'
  'GP004' = '{ "id": "GP004", "name": "G04 prev-day surge", "patterns": { "G04": { "enabled": true } } }'
  'GP005' = '{ "id": "GP005", "name": "G05 near static VI", "patterns": { "G05": { "enabled": true } } }'
  'GP006' = '{ "id": "GP006", "name": "G06 after VI (estimated)", "patterns": { "G06": { "enabled": true } } }'
  'GP010' = '{ "id": "GP010", "name": "all on, rebound", "patterns": { "G01": { "enabled": true }, "G02": { "enabled": true }, "G03": { "enabled": true }, "G04": { "enabled": true }, "G05": { "enabled": true }, "G06": { "enabled": true } } }'
  'GP011' = '{ "id": "GP011", "name": "all on, 2 of 3 rebound signals", "patterns": { "G01": { "enabled": true }, "G02": { "enabled": true }, "G03": { "enabled": true }, "G04": { "enabled": true }, "G05": { "enabled": true }, "G06": { "enabled": true } }, "rebound": { "signals": ["stUp", "nmacdSig", "higherLow"], "need": 2 } }'
}

try {
  Put 'tools\sz-guard.cjs' $guard
  Put 'tools\sz-guard-selftest.cjs' $selftest
  foreach ($k in $profiles.Keys) { Put ("strategies\guard\$k.json") ($profiles[$k] + "`n") }
  Ok "files written: tools 2, profiles $($profiles.Count)"
} catch { Fail $_.Exception.Message; exit 1 }

$ErrorActionPreference = 'Continue'
foreach ($f in 'sz-guard.cjs', 'sz-guard-selftest.cjs') {
  & node --check (Join-Path $Root "tools\$f") 2>&1 | ForEach-Object { "  $_" }
  if ($LASTEXITCODE -ne 0) { Fail "syntax error: $f"; exit 1 }
}
Ok 'syntax check'
& node (Join-Path $Root 'tools\sz-guard-selftest.cjs') (Join-Path $Root 'strategies\guard') 2>&1 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Fail 'guard selftest failed - paste the FAIL lines'; exit 1 }
$h = (Get-FileHash (Join-Path $Root 'tools\sz-guard.cjs') -Algorithm SHA256).Hash.ToLower()
Put 'strategies\guard\manifest.json' ("{`n  ""version"": ""guard-1.0"",`n  ""sha256"": ""$h""`n}`n")
Ok "guard-1.0 registered sha256=$($h.Substring(0,12))"
Ok 'done (engines and lab files untouched)'
