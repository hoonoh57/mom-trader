'use strict';
const fs = require('fs'), path = require('path');
const R = require('./sz-risk.cjs');
let pass = 0, fail = 0;
function t(name, fn) { try { fn(); pass++; } catch (e) { fail++; console.log('FAIL ' + name + ' :: ' + e.message); } }
function eq(a, b, m) { if (a !== b) throw new Error((m || '') + ' expected ' + b + ' got ' + a); }
function near(a, b, m) { if (!(Math.abs(a - b) < 1e-6)) throw new Error((m || '') + ' expected ' + b + ' got ' + a); }
const B = (o, h, l, c) => ({ open: o, high: h, low: l, close: c });
const ENV = { feePct: 0.2, hms: 100000 };
const PP = o => R.load({ position: o });
const PA = o => R.load({ account: o });
const Q = (c, s, tsec, day) => ({ code: c, source: s || 's', tsec: tsec || 36000, day: day || '20261102' });

t('tickSize', () => {
  const cases = [[1999,1],[2000,5],[4999,5],[5000,10],[19990,10],[20000,50],[49950,50],[50000,100],[200000,500],[500000,1000]];
  for (const [p, k] of cases) eq(R.tickSize(p), k, 'p=' + p);
});
t('hms/dayKey', () => {
  const u = Date.UTC(2026, 10, 2, 0, 0, 12) / 1000;
  eq(R.hms('20261102090012'), 90012); eq(R.hms(u), 90012); eq(R.hms('090012'), 90012);
  eq(R.dayKey(u), '20261102'); eq(R.secOfDay(90012), 32412);
});
t('RP000 passive (3000 bars + account)', () => {
  const P = R.load({}); eq(R.isPassive(P), true);
  let s = 7, px = 10000; const rnd = () => (s = (s * 16807) % 2147483647) / 2147483647;
  const r = R.openPosition(P, { px, idx: 0, structLow: 9000 }); eq(!!r.reject, false); eq(r.pos.stop, null);
  for (let i = 1; i < 3000; i++) {
    const o = px; px = Math.max(100, px * (1 + (rnd() - 0.5) * 0.04));
    const a = R.onBar(P, r.pos, B(o, Math.max(o, px) * 1.01, Math.min(o, px) * 0.99, px), i, ENV);
    if (a.length) throw new Error('acted at bar ' + i);
  }
  const A = R.createAccount(P);
  for (let i = 0; i < 50; i++) { const q = Q('C' + i); eq(A.canEnter(q).ok, true); A.onEntry(q); A.mark(q.code, -50); }
  eq(R.flattenDue(P, 153000), false);
});
t('hard stop', () => {
  const r = R.openPosition(PP({ hardStop: { enabled: true, pct: 3 } }), { px: 10000, idx: 0 });
  const a = R.onBar(PP({ hardStop: { enabled: true, pct: 3 } }), r.pos, B(9900, 9950, 9650, 9800), 1, ENV);
  eq(a[0].type, 'exit'); eq(a[0].why, 'hard'); near(a[0].px, 9700);
});
t('gap below stop -> open', () => {
  const P = PP({ hardStop: { enabled: true, pct: 3 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  const a = R.onBar(P, r.pos, B(9600, 9650, 9500, 9550), 1, ENV); eq(a[0].px, 9600); eq(a[0].gap, true);
});
t('struct stop = higher of hard/struct', () => {
  const P = PP({ hardStop: { enabled: true, pct: 3 }, structStop: { enabled: true, lookback: 3, bufTicks: 1, maxPct: 3 } });
  const bars = [B(0,0,9800,0), B(0,0,9750,0), B(0,0,9900,0)];
  const r = R.openPosition(P, { px: 10000, idx: 2, structLow: R.structLow(bars, 2, 3) });
  eq(r.pos.stopWhy, 'struct'); near(r.pos.stop, 9740);
});
t('struct far -> skip', () => {
  const P = PP({ structStop: { enabled: true, maxPct: 3, onFar: 'skip' } });
  eq(R.openPosition(P, { px: 10000, idx: 0, structLow: 9500 }).reject, 'struct_far');
});
t('struct far -> cap', () => {
  const P = PP({ structStop: { enabled: true, maxPct: 3, onFar: 'cap' } });
  const r = R.openPosition(P, { px: 10000, idx: 0, structLow: 9500 }); near(r.pos.stop, 9700);
});
t('struct invalid', () => {
  const P = PP({ structStop: { enabled: true } });
  eq(R.openPosition(P, { px: 10000, idx: 0, structLow: 10100 }).reject, 'struct_invalid');
});
t('partial TP 50%', () => {
  const P = PP({ takeProfit: { enabled: true, pct: 5, ratio: 0.5 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  const a = R.onBar(P, r.pos, B(10100, 10600, 10050, 10500), 1, ENV);
  eq(a[0].type, 'partial'); near(a[0].px, 10500); eq(a[0].frac, 0.5); eq(r.pos.frac, 0.5);
});
t('same bar stop+TP -> stop first', () => {
  const P = PP({ hardStop: { enabled: true, pct: 3 }, takeProfit: { enabled: true, pct: 5 } });
  const r = R.openPosition(P, { px: 10000, idx: 0 });
  const a = R.onBar(P, r.pos, B(10000, 10600, 9600, 10000), 1, ENV); eq(a.length, 1); eq(a[0].why, 'hard');
});
t('TP ratio 1.0 -> full exit', () => {
  const P = PP({ takeProfit: { enabled: true, pct: 5, ratio: 1 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  const a = R.onBar(P, r.pos, B(10100, 10600, 10050, 10500), 1, ENV); eq(a[0].type, 'exit'); eq(a[0].why, 'tp');
});
t('protect (breakeven+fee)', () => {
  const P = PP({ protect: { enabled: true, atPct: 2, levelPct: 0 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  eq(R.onBar(P, r.pos, B(10000, 10250, 10100, 10200), 1, ENV).length, 0); eq(r.pos.protectOn, true);
  const a = R.onBar(P, r.pos, B(10150, 10160, 10010, 10050), 2, ENV); eq(a[0].why, 'protect'); near(a[0].px, 10020);
});
t('trail clamped to avg+fee', () => {
  const P = PP({ trail: { enabled: true, afterPct: 3, dropPct: 5 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  R.onBar(P, r.pos, B(10000, 10400, 9990, 10350), 1, ENV); eq(r.pos.trailOn, true);
  const a = R.onBar(P, r.pos, B(10300, 10310, 10000, 10050), 2, ENV); eq(a[0].why, 'trail'); near(a[0].px, 10020);
});
t('time stop', () => {
  const P = PP({ timeStop: { enabled: true, bars: 3, minPct: 1 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  for (let i = 1; i < 3; i++) eq(R.onBar(P, r.pos, B(10000, 10050, 9990, 10010), i, ENV).length, 0);
  const a = R.onBar(P, r.pos, B(10000, 10050, 9990, 10010), 3, ENV); eq(a[0].why, 'time'); eq(a[0].px, 10010);
});
t('manual hold', () => {
  const P = PP({ hardStop: { enabled: true, pct: 3 }, protect: { enabled: true } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  r.pos.manualHold = true; eq(R.onBar(P, r.pos, B(9900, 9950, 9650, 9800), 1, ENV)[0].why, 'hard');
  const P2 = PP({ hardStop: { enabled: true, pct: 3 }, manualHoldKeepsHardStop: false }); const r2 = R.openPosition(P2, { px: 10000, idx: 0 });
  r2.pos.manualHold = true; eq(R.onBar(P2, r2.pos, B(9900, 9950, 9650, 9800), 1, ENV).length, 0);
});
t('ignore before open', () => {
  const P = PP({ hardStop: { enabled: true, pct: 3 } }); const r = R.openPosition(P, { px: 10000, idx: 0 });
  eq(R.onBar(P, r.pos, B(9000, 9000, 9000, 9000), 1, { feePct: 0.2, hms: 85959 }).length, 0);
});
t('max slots', () => {
  const A = R.createAccount(PA({ maxSlots: { enabled: true, n: 2 } }));
  A.onEntry(Q('A')); A.onEntry(Q('B')); eq(A.canEnter(Q('C')).why, 'slots');
});
t('per source', () => {
  const A = R.createAccount(PA({ maxEntriesPerSource: { enabled: true, n: 1 } }));
  A.onEntry(Q('A', 'x')); eq(A.canEnter(Q('B', 'x')).why, 'per_source'); eq(A.canEnter(Q('B', 'y')).ok, true);
  A.cancelEntry(Q('A', 'x')); eq(A.canEnter(Q('B', 'x')).ok, true);
});
t('no reentry same day', () => {
  const A = R.createAccount(PA({ noReentrySameDay: { enabled: true } }));
  A.onEntry(Q('A')); A.onExit({ code: 'A', retPct: 1, tsec: 36100 }); eq(A.canEnter(Q('A')).why, 'no_reentry');
  eq(A.canEnter(Q('A', 's', 36000, '20261103')).ok, true);
});
t('daily loss block', () => {
  const A = R.createAccount(PA({ dailyLoss: { enabled: true, pct: 2, action: 'block' } }));
  A.onEntry(Object.assign(Q('A'), { w: 0.5 })); eq(A.mark('A', -5), null); eq(A.canEnter(Q('B')).why, 'daily_loss');
  eq(A.canEnter(Q('B', 's', 36000, '20261103')).ok, true);
});
t('daily loss baseline at day roll', () => {
  const A = R.createAccount(PA({ dailyLoss: { enabled: true, pct: 2, action: 'block' } }));
  A.onEntry(Object.assign(Q('A'), { w: 0.5 })); A.mark('A', -5);
  eq(A.canEnter(Q('B', 's', 36000, '20261103')).ok, true, 'roll');
  near(A.equityPct(), 0, 'eq after roll');
  A.mark('A', -7); near(A.equityPct(), -1, 'delta');
  eq(A.canEnter(Q('B', 's', 36100, '20261103')).ok, true, 'within');
  A.mark('A', -10); eq(A.canEnter(Q('B', 's', 36200, '20261103')).why, 'daily_loss');
});
t('daily loss flatten', () => {
  const A = R.createAccount(PA({ dailyLoss: { enabled: true, pct: 2, action: 'flatten' } }));
  A.onEntry(Object.assign(Q('A'), { w: 0.5 })); eq(A.mark('A', -5), 'flatten');
});
t('consecutive loss pause', () => {
  const A = R.createAccount(PA({ consecLoss: { enabled: true, n: 2, pauseMin: 30 } }));
  A.onEntry(Q('A')); A.onEntry(Q('B'));
  A.onExit({ code: 'A', retPct: -1, tsec: 36000 }); A.onExit({ code: 'B', retPct: -1, tsec: 36000 });
  eq(A.canEnter(Q('C', 's', 36100)).why, 'pause'); eq(A.canEnter(Q('C', 's', 37801)).ok, true);
});
t('kill switch', () => {
  const A = R.createAccount(R.load({})); A.kill(true); eq(A.canEnter(Q('A')).why, 'kill');
});
t('sizer', () => {
  const P = R.load({ sizing: { mode: 'riskBased', riskPerTradePct: 0.5, maxWeightPct: 30 } });
  eq(R.size(P, { px: 10000, stop: 9700, equity: 1e7 }).qty, 166);
  eq(R.size(R.load({}), { px: 13400, equity: 1e7 }).qty, 74);
});
t('profiles', () => {
  const dir = process.argv[2];
  if (!dir || !fs.existsSync(dir)) throw new Error('profile dir missing: ' + dir);
  const files = fs.readdirSync(dir).filter(f => /\.json$/i.test(f));
  if (files.length < 7) throw new Error('profiles < 7: ' + files.length);
  for (const f of files) {
    const raw = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    const id = f.replace(/\.json$/i, '');
    if (raw.id !== id) throw new Error(f + ': id mismatch ' + raw.id);
    const unk = R.unknownKeys(raw); if (unk.length) throw new Error(f + ': unknown keys ' + unk.join(','));
    const P = R.load(raw), v = R.validate(P); if (v.length) throw new Error(f + ': invalid ' + v.join(','));
    if ((id === 'RP000') !== R.isPassive(P)) throw new Error(f + ': passive=' + R.isPassive(P));
    console.log('  profile ' + id + ' on=[' + R.enabledList(P).join(' ') + ']');
  }
});
console.log((fail ? 'SELFTEST FAIL ' : 'SELFTEST OK ') + pass + '/' + (pass + fail) + ' (' + R.VERSION + ')');
process.exit(fail ? 1 : 0);