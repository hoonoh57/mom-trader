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