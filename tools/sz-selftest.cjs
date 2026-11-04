'use strict';
const SZ = require('./sz-engine.cjs');
let pass = 0, fail = 0;
function ok(name, cond, info) { if (cond) pass++; else { fail++; console.log('FAIL ' + name + (info !== undefined ? ' :: ' + info : '')); } }
const near = (a, b, e) => Math.abs(a - b) <= (e || 1e-9);
function mk(prices, d, t0) { return prices.map((c, k) => ({ d: d || '20261102', hms: 90000 + k, t: (t0 || 0) + k * 10, o: c, h: c + 0.5, l: c - 0.5, c, v: 1000 })); }
try {
  ok('ema-const', SZ.ema([5, 5, 5, 5], 3).every(x => x === 5));
  ok('ema-step', near(SZ.ema([1, 3], 3)[1], 2));
  const up = mk(Array.from({ length: 40 }, (_, k) => 100 + k));
  const su = SZ.supertrend(up, 14, 1.5); ok('st-up', su.dir[39] === 1 && su.line[39] < up[39].c);
  const dn = mk(Array.from({ length: 40 }, (_, k) => 200 - k));
  const sd = SZ.supertrend(dn, 14, 1.5); ok('st-down', sd.dir[39] === -1 && sd.line[39] > dn[39].c);
  const P0 = SZ.prep({ MomLen: 2, P1: 2, P2: 3, P3: 2, EmaLen: 3, StLen: 3, RelWin: 2, TickScope: 120 });
  const two = mk([10, 10, 10], '20261030', 0).concat(mk([10, 20, 10], '20261102', 100000));
  const I0 = SZ.compute(two, P0);
  ok('taamt-reset', near(I0.taamt[3], 10000) && near(I0.taamt[5], 40000), I0.taamt.join());
  ok('mom', I0.mom[1] === null && near(I0.mom[4], 200), I0.mom[4]);
  ok('tick-cnt', I0.cnt1[5] === 360, I0.cnt1[5]);

  function scen(mod) {
    const c = [100, 101, 102, 101, 103, 102, 101, 100];
    const o = [100, 100.5, 101, 101.5, 102, 102.5, 101.5, 100.5];
    const bars = c.map((x, k) => ({ d: '20261102', hms: 90100 + k * 100, t: k * 60, o: o[k], h: Math.max(x, o[k]) + 0.5, l: Math.min(x, o[k]) - 0.5, c: x, v: 1 }));
    const N = c.length;
    const ind = { n: [-0.1, 0.1, 0.2, 0.15, 0.1, -0.05, -0.1, -0.1], sig: [0, 0, 0.1, 0.2, 0.2, 0.1, 0, 0],
      safe: new Array(N).fill(true), big: [false, false, true, false, false, false, false, false],
      taamt: new Array(N).fill(2e9), dayStart: new Array(N).fill(0), ema: new Array(N).fill(90), st: new Array(N).fill(90),
      stDir: new Array(N).fill(1), disp: new Array(N).fill(100), tickOk: new Array(N).fill(true) };
    if (mod) mod(ind, bars);
    return { bars, ind };
  }
  const base = { FeePct: 0, ArmSkip: 1, TargetPct: 5, StopPct: 3, ArmMode: 'cross', SafeNoLoss: 0, SafeBelow: 'macd_zero' };
  const P = o => SZ.prep(Object.assign({}, base, o || {}));
  const ctx = { start: 0, date: '20261102', dayComplete: true, limKind: null };
  let s = scen(), R = SZ.simulate(s.bars, s.ind, P(), ctx);
  ok('sz-hold-to-zero', R.trades.length === 1 && R.trades[0].inI === 2 && R.trades[0].outI === 5 && R.trades[0].why === 'S-:macd_zero', JSON.stringify(R.trades));
  ok('sz-mfe-mae', R.trades.length === 1 && near(R.trades[0].mfe, (103.5 / 102 - 1) * 100) && near(R.trades[0].mae, (100.5 / 102 - 1) * 100));
  R = SZ.simulate(s.bars, s.ind, P({ SafeBelow: 'macd_sig', SafeAbove: 'macd_sig' }), ctx);
  ok('baseline-sig', R.trades.length === 1 && R.trades[0].outI === 3 && R.trades[0].outPx === 101, JSON.stringify(R.trades));
  s = scen(ind => { ind.safe[6] = false; ind.safe[7] = false; });
  R = SZ.simulate(s.bars, s.ind, P({ TargetPct: 0.5 }), ctx);
  ok('target-hold-then-unsafe', R.trades.length === 1 && R.trades[0].outI === 6 && R.trades[0].why === 'U+:immediate', JSON.stringify(R.trades));
  s = scen((ind, bars) => { bars[3].l = 98; });
  R = SZ.simulate(s.bars, s.ind, P(), ctx);
  ok('stop', R.trades.length === 1 && R.trades[0].why === 'stop' && near(R.trades[0].outPx, 102 * 0.97), JSON.stringify(R.trades));
  s = scen();
  R = SZ.simulate(s.bars, s.ind, P({ EntryEnd: 902 }), ctx);
  ok('time-window', R.trades.length === 0 && R.rej.time === 1);
  R = SZ.simulate(s.bars, s.ind, P(), Object.assign({}, ctx, { limKind: 'surge' }));
  ok('surge-pullback', R.trades.length === 0 && R.rej.lim === 1);
  s = scen(ind => { for (let k = 3; k < 8; k++) ind.safe[k] = false; });
  R = SZ.simulate(s.bars, s.ind, P(), ctx);
  ok('unsafe-below-sig', R.trades.length === 1 && R.trades[0].outI === 3 && R.trades[0].why === 'U-:macd_sig', JSON.stringify(R.trades));
  let threw = false; try { SZ.prep({ SafeBelow: 'xx' }); } catch (e) { threw = true; }
  ok('validate', threw);

  // --- new: no-loss hold in safe zone
  s = scen((ind, bars) => { bars[5].c = 101; bars[5].h = 103; bars[5].l = 100.5; });
  R = SZ.simulate(s.bars, s.ind, P({ SafeNoLoss: 1 }), ctx);
  ok('noloss-safe', R.trades.length === 1 && R.trades[0].outI === 7 && R.trades[0].why === 'eod' && R.held === 3, JSON.stringify(R.trades) + ' held=' + R.held);
  // --- new: n already > 0 before safe zone starts
  const late = ind => { ind.n = new Array(8).fill(0.1); ind.sig = new Array(8).fill(0); ind.safe[0] = false; };
  s = scen(late);
  R = SZ.simulate(s.bars, s.ind, P({ ArmMode: 'state', SafeBelow: 'hold', SafeNoLoss: 1 }), ctx);
  ok('state-late-arm', R.trades.length === 1 && R.trades[0].inI === 2 && R.arms === 1, JSON.stringify(R.trades) + ' arms=' + R.arms);
  R = SZ.simulate(s.bars, s.ind, P({ ArmMode: 'cross' }), ctx);
  ok('cross-late-noarm', R.trades.length === 0 && R.arms === 0);
  // --- new: re-entry inside the same safe zone
  const re = (ind, bars) => { ind.n = new Array(8).fill(0.1); ind.n[4] = -0.05; ind.sig = new Array(8).fill(0); ind.big[6] = true; bars[6].o = 100.5; bars[6].h = 101.5; bars[6].l = 100; };
  s = scen(re);
  R = SZ.simulate(s.bars, s.ind, P({ ArmMode: 'state' }), ctx);
  ok('reentry-state', R.trades.length === 2 && R.trades[0].outI === 4 && R.trades[1].inI === 6, JSON.stringify(R.trades));
  R = SZ.simulate(s.bars, s.ind, P({ ArmMode: 'state', ReentryGap: 3 }), ctx);
  ok('reentry-gap', R.trades.length === 1 && R.rej.gap === 1, JSON.stringify(R.rej));
} catch (e) { fail++; console.log('EXCEPTION ' + (e && e.stack || e)); }
console.log((fail ? 'SELFTEST FAIL ' : 'SELFTEST OK ') + pass + '/' + (pass + fail));
process.exit(fail ? 1 : 0);