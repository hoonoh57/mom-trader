#requires -Version 5.1
# 13_trade.ps1 : SafeZone 2단계 - 진입 게이트 + 매도 상태 머신 + 차트/거래표
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [string]$Match = '_AL_120t_',
  [string]$Date = '',
  [int]$MomLen = 50, [double]$SafeTh = 100, [double]$SafeExitTh = 100, [int]$SafeConfirm = 1,
  [int]$P1 = 7, [int]$P2 = 14, [int]$P3 = 5,
  [double]$StrongA = 1e9,
  [ValidateSet('abs','rel','both')][string]$BigMode = 'abs',
  [double]$BigTh = 5e7, [int]$RelWin = 20, [double]$RelK = 3,
  [int]$BigNeedUp = 1, [int]$BigNeedST = 1,
  [int]$ArmSkip = 1, [int]$ArmSameSession = 1,
  [int]$EmaLen = 200, [int]$StLen = 14, [double]$StMult = 1.5,
  [double]$TickK = 1.0, [double]$TickAbs = 0,
  [double]$DispMax = 112, [int]$DispUntil = 1000,
  [double]$LimPct = 29, [double]$SurgePct = 25,
  [ValidateSet('off','block','pullback')][string]$LimMode = 'pullback',
  [ValidateSet('off','block','pullback')][string]$SurgeMode = 'pullback',
  [double]$PbPct = 5,
  [int]$EntryStart = 900, [int]$EntryEnd = 1520, [int]$ExitTime = 1520, [int]$SessionStartMax = 905,
  [double]$TargetPct = 5, [double]$StopPct = 3, [double]$TrailPct = 2,
  [ValidateSet('hold','immediate','macd_zero','macd_sig','supertrend','trail')][string]$SafeBelow = 'hold',
  [ValidateSet('hold','immediate','macd_zero','macd_sig','supertrend','trail')][string]$SafeAbove = 'hold',
  [ValidateSet('hold','immediate','macd_zero','macd_sig','supertrend','trail')][string]$UnsafeBelow = 'macd_sig',
  [ValidateSet('hold','immediate','macd_zero','macd_sig','supertrend','trail')][string]$UnsafeAbove = 'immediate',
  [double]$FeePct = 0.25, [double]$SlipPct = 0, [int]$MaxTrades = 10,
  [ValidateSet('state','cross')][string]$ArmMode = 'state', [int]$SafeNoLoss = 1, [double]$SafeMinPct = 0, [int]$ReentryGap = 0,
  [switch]$SelfTestOnly, [switch]$NoOpen
)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'

function Ok($m)   { Write-Host "[성공] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[실패] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" }
function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
  $back = [System.IO.File]::ReadAllText($Path, $enc)
  if ($back -ne $Text) { throw "write verify failed: $Path" }
}

Write-Host '=== mom-trader 2단계: SafeZone 매매 시뮬레이션 ==='
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) { Fail 'node 없음 (Node.js 18+ 설치 필요)'; exit 1 }
$tools = Join-Path $Root 'tools'
$out   = Join-Path $Root 'out\trade'

# ---------------------------------------------------------------- engine
$engine = @'
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.SZ = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';
  const RULES = ['hold', 'immediate', 'macd_zero', 'macd_sig', 'supertrend', 'trail'];
  const DEFAULTS = { MomLen: 50, SafeTh: 100, SafeExitTh: 100, SafeConfirm: 1, P1: 7, P2: 14, P3: 5,
    StrongA: 1e9, BigMode: 'abs', BigTh: 5e7, RelWin: 20, RelK: 3, BigNeedUp: 1, BigNeedST: 1,
    ArmSkip: 1, ArmSameSession: 1, EmaLen: 200, StLen: 14, StMult: 1.5, TickScope: 120, TickK: 1.0, TickAbs: 0,
    DispMax: 112, DispUntil: 1000, LimPct: 29, SurgePct: 25, LimMode: 'pullback', SurgeMode: 'pullback', PbPct: 5,
    EntryStart: 900, EntryEnd: 1520, ExitTime: 1520, SessionStartMax: 905,
    TargetPct: 5, StopPct: 3, TrailPct: 2,
    SafeBelow: 'hold', SafeAbove: 'hold', UnsafeBelow: 'macd_sig', UnsafeAbove: 'immediate',
    FeePct: 0.25, SlipPct: 0, MaxTrades: 10, ArmMode: 'state', SafeNoLoss: 1, SafeMinPct: 0, ReentryGap: 0, Match: '_AL_120t_', Date: '' };

  function validate(P) {
    for (const k of ['SafeBelow', 'SafeAbove', 'UnsafeBelow', 'UnsafeAbove'])
      if (RULES.indexOf(P[k]) < 0) throw new Error(k + ' invalid: ' + P[k] + ' (use ' + RULES.join('/') + ')');
    for (const k of ['LimMode', 'SurgeMode'])
      if (['off', 'block', 'pullback'].indexOf(P[k]) < 0) throw new Error(k + ' invalid: ' + P[k]);
    if (['abs', 'rel', 'both'].indexOf(P.BigMode) < 0) throw new Error('BigMode invalid: ' + P.BigMode);
    for (const k of ['MomLen', 'P1', 'P2', 'P3', 'EmaLen', 'StLen', 'RelWin', 'TickScope', 'SafeConfirm'])
      if (!(Number(P[k]) >= 1)) throw new Error(k + ' must be >= 1');
  }
  function prep(P0) {
    const P = Object.assign({}, DEFAULTS, P0 || {});
    validate(P);
    P._entS = P.EntryStart * 100; P._entE = P.EntryEnd * 100; P._exitT = P.ExitTime * 100;
    P._dispU = P.DispUntil * 100; P._sessMax = P.SessionStartMax * 100;
    return P;
  }
  function ema(src, len) {
    const a = 2 / (len + 1), out = new Array(src.length); let prev = null;
    for (let i = 0; i < src.length; i++) {
      const x = src[i];
      if (x == null || !isFinite(x)) { out[i] = prev; continue; }
      prev = prev == null ? x : prev + a * (x - prev); out[i] = prev;
    }
    return out;
  }
  function supertrend(bars, period, mult) {
    const n = bars.length, line = new Array(n).fill(null), dir = new Array(n).fill(0);
    let atr = null, trSum = 0, fu = null, fl = null, d = 1;
    for (let i = 0; i < n; i++) {
      const b = bars[i], pc = i > 0 ? bars[i - 1].c : b.c;
      const tr = Math.max(b.h - b.l, Math.abs(b.h - pc), Math.abs(b.l - pc));
      if (i < period) { trSum += tr; if (i < period - 1) continue; atr = trSum / period; }
      else atr = (atr * (period - 1) + tr) / period;
      const hl2 = (b.h + b.l) / 2, bu = hl2 + mult * atr, bl = hl2 - mult * atr;
      if (fu == null) { fu = bu; fl = bl; d = b.c >= hl2 ? 1 : -1; }
      else {
        const pcl = bars[i - 1].c;
        fu = (bu < fu || pcl > fu) ? bu : fu;
        fl = (bl > fl || pcl < fl) ? bl : fl;
        if (d === 1 && b.c < fl) d = -1; else if (d === -1 && b.c > fu) d = 1;
      }
      line[i] = d === 1 ? fl : fu; dir[i] = d;
    }
    return { line, dir };
  }
  function compute(bars, P) {
    const N = bars.length, c = bars.map(b => b.c);
    const mom = new Array(N).fill(null);
    for (let i = P.MomLen; i < N; i++) { const r = c[i - P.MomLen]; mom[i] = r > 0 ? c[i] / r * 100 : null; }
    const e1 = ema(c, P.P1), e2 = ema(c, P.P2);
    const n = c.map((x, i) => (e1[i] - e2[i]) / x * 100);
    const sig = ema(n, P.P3);
    const emaL = ema(c, P.EmaLen);
    const st = supertrend(bars, P.StLen, P.StMult);
    const amt = bars.map(b => (b.o + b.h + b.l + b.c) / 4 * b.v);
    const taamt = new Array(N), dayStart = new Array(N);
    let d = null, cum = 0, ds = 0;
    for (let i = 0; i < N; i++) {
      if (bars[i].d !== d) { d = bars[i].d; cum = 0; ds = i; }
      cum += amt[i]; taamt[i] = cum; dayStart[i] = ds;
    }
    const big = new Array(N).fill(false); let win = 0;
    for (let i = 0; i < N; i++) {
      let rel = false;
      if (i >= P.RelWin) rel = amt[i] >= P.RelK * (win / P.RelWin);
      const abs = amt[i] >= P.BigTh;
      big[i] = P.BigMode === 'abs' ? abs : P.BigMode === 'rel' ? rel : (abs && rel);
      win += amt[i]; if (i >= P.RelWin) win -= amt[i - P.RelWin];
    }
    const cnt1 = new Array(N), thr = new Array(N), tickOk = new Array(N);
    let a1 = 0, a5 = 0;
    for (let i = 0; i < N; i++) {
      const t = bars[i].t;
      while (bars[a1].t <= t - 60) a1++;
      while (bars[a5].t <= t - 300) a5++;
      cnt1[i] = (i - a1 + 1) * P.TickScope;
      const avg5 = (i - a5 + 1) * P.TickScope / 5;
      thr[i] = Math.max(P.TickAbs, avg5 * P.TickK);
      tickOk[i] = cnt1[i] >= thr[i];
    }
    const disp = c.map((x, i) => emaL[i] > 0 ? x / emaL[i] * 100 : null);
    const safe = new Array(N).fill(false);
    let s = false, upRun = 0, dnRun = 0;
    for (let i = 0; i < N; i++) {
      const m = mom[i];
      if (m == null) { safe[i] = false; continue; }
      upRun = m >= P.SafeTh ? upRun + 1 : 0;
      dnRun = m < P.SafeExitTh ? dnRun + 1 : 0;
      if (!s && upRun >= P.SafeConfirm) s = true; else if (s && dnRun >= P.SafeConfirm) s = false;
      safe[i] = s;
    }
    return { mom, n, sig, ema: emaL, st: st.line, stDir: st.dir, amt, taamt, dayStart, big, cnt1, thr, tickOk, disp, safe };
  }
  function hit(rule, i, ind, b, pos, P) {
    switch (rule) {
      case 'hold': return false;
      case 'immediate': return true;
      case 'macd_zero': return ind.n[i] < 0;
      case 'macd_sig': return ind.n[i] < ind.sig[i];
      case 'supertrend': return ind.stDir[i] === -1;
      case 'trail': return b.c <= pos.peakC * (1 - P.TrailPct / 100);
      default: throw new Error('unknown rule ' + rule);
    }
  }
  function simulate(bars, ind, P, ctx) {
    const N = bars.length, trades = [], marks = [];
    const rej = { time: 0, count: 0, gap: 0, lim: 0, ema: 0, disp: 0, tick: 0 };
    const armMode = P.ArmMode === 'cross' ? 'cross' : 'state';
    const noLoss = Number(P.SafeNoLoss == null ? 1 : P.SafeNoLoss) > 0;
    const minPct = Number(P.SafeMinPct || 0), gap = Number(P.ReentryGap || 0);
    let armed = false, pos = null, hiDay = 0, pbDone = false, arms = 0, sigs = 0, lastI = -1, lastExit = -1e9, held = 0;
    const limMode = ctx.limKind === 'limit' ? P.LimMode : ctx.limKind === 'surge' ? P.SurgeMode : 'off';
    const closeTrade = (i, px, why) => {
      const gross = (px / pos.entry - 1) * 100, ret = gross - P.FeePct;
      trades.push({ inI: pos.idx, inPx: pos.entry, outI: i, outPx: px, why, gross, ret,
        mfe: (pos.hi / pos.entry - 1) * 100, mae: (pos.lo / pos.entry - 1) * 100, bars: i - pos.idx, reached: pos.reached, held: pos.held });
      marks.push({ i, k: 'exit', why, ret });
      pos = null; lastExit = i;
    };
    for (let i = ctx.start; i < N; i++) {
      const b = bars[i];
      if (b.d !== ctx.date) continue;
      lastI = i;
      if (b.h > hiDay) hiDay = b.h;
      if (hiDay > 0 && (hiDay - b.l) / hiDay * 100 >= P.PbPct) pbDone = true;
      if (pos && i > pos.idx) {
        if (b.h > pos.hi) pos.hi = b.h;
        if (b.l < pos.lo) pos.lo = b.l;
        const stopPx = P.StopPct > 0 ? pos.entry * (1 - P.StopPct / 100) : -1;
        if (b.l <= stopPx) closeTrade(i, Math.min(b.o, stopPx), 'stop');
        else if (b.hms >= P._exitT) closeTrade(i, b.c, 'time');
        else {
          if (!pos.reached && (b.c / pos.entry - 1) * 100 >= P.TargetPct) pos.reached = true;
          if (b.c > pos.peakC) pos.peakC = b.c;
          const s = ind.safe[i];
          const rule = s ? (pos.reached ? P.SafeAbove : P.SafeBelow) : (pos.reached ? P.UnsafeAbove : P.UnsafeBelow);
          if (hit(rule, i, ind, b, pos, P)) {
            const cur = (b.c / pos.entry - 1) * 100 - P.FeePct;
            if (s && noLoss && cur < minPct) { pos.held++; held++; }
            else closeTrade(i, b.c, (s ? 'S' : 'U') + (pos.reached ? '+' : '-') + ':' + rule);
          }
        }
        if (!pos) continue;
      }
      const safe = ind.safe[i];
      const baseOk = safe && ctx.dayComplete && ind.taamt[i] > P.StrongA && (i - ind.dayStart[i]) >= P.ArmSkip;
      if (armMode === 'state') {
        const want = !pos && baseOk && ind.n[i] > 0;
        if (want && !armed) { arms++; marks.push({ i, k: 'arm' }); }
        armed = want;
      } else {
        if (armed && (!safe || ind.n[i] < 0)) armed = false;
        const prevSame = i > 0 && (!P.ArmSameSession || bars[i - 1].d === b.d);
        const crossUp = prevSame && ind.n[i - 1] <= 0 && ind.n[i] > 0;
        if (!pos && !armed && crossUp && baseOk) { armed = true; arms++; marks.push({ i, k: 'arm' }); }
      }
      if (pos || !armed) continue;
      const signal = ind.big[i] && (!P.BigNeedUp || b.c > b.o) && (!P.BigNeedST || (ind.st[i] != null && b.c > ind.st[i]));
      if (!signal) continue;
      sigs++;
      let why = null;
      if (b.hms < P._entS || b.hms >= P._entE) why = 'time';
      else if (P.MaxTrades > 0 && trades.length >= P.MaxTrades) why = 'count';
      else if (i - lastExit <= gap) why = 'gap';
      else if (limMode === 'block' || (limMode === 'pullback' && !pbDone)) why = 'lim';
      else if (!(b.c > ind.ema[i])) why = 'ema';
      else if (b.hms < P._dispU && ind.disp[i] > P.DispMax) why = 'disp';
      else if (!ind.tickOk[i]) why = 'tick';
      if (why) { rej[why]++; marks.push({ i, k: 'rej', why }); continue; }
      pos = { idx: i, entry: b.c * (1 + P.SlipPct / 100), hi: b.c, lo: b.c, peakC: b.c, reached: false, held: 0 };
      armed = false;
      marks.push({ i, k: 'entry' });
    }
    if (pos && lastI >= 0) closeTrade(lastI, bars[lastI].c, 'eod');
    return { trades, marks, rej, arms, sigs, limMode, pbDone, held };
  }
  function summarize(tr) {
    const n = tr.length; let w = 0, sum = 0, best = -Infinity, worst = Infinity, mfe = 0;
    for (const t of tr) { if (t.ret > 0) w++; sum += t.ret; best = Math.max(best, t.ret); worst = Math.min(worst, t.ret); mfe += t.mfe; }
    return { n, w, sum, avg: n ? sum / n : 0, best: n ? best : 0, worst: n ? worst : 0, avgMfe: n ? mfe / n : 0 };
  }
  return { RULES, DEFAULTS, prep, validate, ema, supertrend, compute, simulate, summarize };
});
'@

# ---------------------------------------------------------------- selftest
$selftest = @'
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
'@

# ---- renderer (browser)
$render = @'
(function () {
  'use strict';
  var D = window.SZDATA;
  var cv = document.getElementById('cv'), g = cv.getContext('2d'), tip = document.getElementById('tip');
  var N = D.c.length, v0 = 0, v1 = N, cur = -1, drag = null;
  var PAN = [['price', 40], ['mom', 13], ['macd', 15], ['amt', 14], ['tick', 14]];
  var LM = 8, RM = 72, TOP = 6, BOT = 20, GAP = 8, W = 0, H = 0, lay = {};
  var REJ = { time: '#ffffff', count: '#888888', lim: '#c08040', ema: '#9a9a9a', disp: '#b070ff', tick: '#ff9900' };
  var hist = D.n.map(function (x, i) { return x == null || D.sig[i] == null ? null : x - D.sig[i]; });
  function step() { return (W - LM - RM) / (v1 - v0); }
  function X(i) { return LM + (i - v0 + 0.5) * step(); }
  function I(x) { return Math.floor(v0 + (x - LM) / step()); }
  function rng(arrs, extra, padK) {
    var mn = Infinity, mx = -Infinity;
    arrs.forEach(function (a) { for (var i = v0; i < v1; i++) { var x = a[i]; if (x == null || !isFinite(x)) continue; if (x < mn) mn = x; if (x > mx) mx = x; } });
    (extra || []).forEach(function (x) { if (x < mn) mn = x; if (x > mx) mx = x; });
    if (!isFinite(mn)) { mn = 0; mx = 1; }
    if (mx === mn) { mx += 1; mn -= 1; }
    var pd = (mx - mn) * (padK || 0.06); return [mn - pd, mx + pd];
  }
  function ym(p, r) { return function (v) { return p.y + p.h - (v - r[0]) / (r[1] - r[0]) * p.h; }; }
  function clip(p, fn) { g.save(); g.beginPath(); g.rect(LM, p.y, W - LM - RM, p.h); g.clip(); fn(); g.restore(); }
  function line(a, col, y, w) {
    g.strokeStyle = col; g.lineWidth = w || 1; g.beginPath(); var pen = false;
    for (var i = v0; i < v1; i++) { var x = a[i]; if (x == null || !isFinite(x)) { pen = false; continue; } if (!pen) { g.moveTo(X(i), y(x)); pen = true; } else g.lineTo(X(i), y(x)); }
    g.stroke(); g.lineWidth = 1;
  }
  function hl(y, v, col, dash) { g.strokeStyle = col; g.setLineDash(dash || []); g.beginPath(); g.moveTo(LM, y(v)); g.lineTo(W - RM, y(v)); g.stroke(); g.setLineDash([]); }
  function bars(a, colFn, y, base) {
    var bw = Math.max(1, step() * 0.7), z = y(base);
    for (var i = v0; i < v1; i++) { var x = a[i]; if (x == null || !isFinite(x)) continue; var yy = y(x); g.fillStyle = colFn(i, x); g.fillRect(X(i) - bw / 2, Math.min(z, yy), bw, Math.max(1, Math.abs(yy - z))); }
  }
  function axis(p, r, y, fmt) {
    g.strokeStyle = '#333'; g.strokeRect(LM, p.y, W - LM - RM, p.h);
    g.fillStyle = '#999'; g.font = '11px sans-serif'; g.textAlign = 'left';
    for (var k = 0; k < 4; k++) { var v = r[0] + (r[1] - r[0]) * (k + 0.5) / 4; g.fillText(fmt(v), W - RM + 4, y(v) + 4); }
  }
  function title(p, s) { g.fillStyle = '#ccc'; g.font = '12px "Malgun Gothic",sans-serif'; g.textAlign = 'left'; g.fillText(s, LM + 4, p.y + 13); }
  function tri(x, y, s, col, up) {
    g.fillStyle = col; g.beginPath();
    if (up) { g.moveTo(x, y - s); g.lineTo(x - s, y + s); g.lineTo(x + s, y + s); }
    else { g.moveTo(x, y + s); g.lineTo(x - s, y - s); g.lineTo(x + s, y - s); }
    g.closePath(); g.fill();
  }
  function cross(x, y, s, col) { g.strokeStyle = col; g.lineWidth = 1.5; g.beginPath(); g.moveTo(x - s, y - s); g.lineTo(x + s, y + s); g.moveTo(x + s, y - s); g.lineTo(x - s, y + s); g.stroke(); g.lineWidth = 1; }
  function draw() {
    g.fillStyle = '#111'; g.fillRect(0, 0, W, H);
    var s = step(), bw = Math.max(1, s * 0.7), i;
    var p = lay.price, r = rng([D.h, D.l], null, 0.10), y = ym(p, r);
    clip(p, function () {
      g.fillStyle = 'rgba(0,170,90,0.12)';
      for (var i = v0; i < v1; i++) if (D.safe[i]) g.fillRect(X(i) - s / 2, p.y, s + 0.5, p.h);
      for (i = v0; i < v1; i++) {
        var upc = D.c[i] >= D.o[i], col = upc ? '#ff4d4d' : '#4d8dff', x = X(i);
        g.strokeStyle = col; g.beginPath(); g.moveTo(x, y(D.h[i])); g.lineTo(x, y(D.l[i])); g.stroke();
        var t = y(Math.max(D.o[i], D.c[i])), b = y(Math.min(D.o[i], D.c[i]));
        g.fillStyle = col; g.fillRect(x - bw / 2, t, bw, Math.max(1, b - t));
      }
      line(D.ema, '#bbbbbb', y, 2);
      g.lineWidth = 1.5;
      for (i = Math.max(v0 + 1, 1); i < v1; i++) {
        if (D.st[i] == null || D.st[i - 1] == null || D.stDir[i] !== D.stDir[i - 1]) continue;
        g.strokeStyle = D.stDir[i] === 1 ? '#ff9933' : '#66ccff';
        g.beginPath(); g.moveTo(X(i - 1), y(D.st[i - 1])); g.lineTo(X(i), y(D.st[i])); g.stroke();
      }
      g.lineWidth = 1;
      D.trades.forEach(function (t) {
        g.strokeStyle = t.ret > 0 ? 'rgba(255,90,90,.9)' : 'rgba(90,200,255,.9)'; g.setLineDash([4, 3]);
        g.beginPath(); g.moveTo(X(t.inI), y(t.inPx)); g.lineTo(X(t.outI), y(t.outPx)); g.stroke(); g.setLineDash([]);
      });
      D.marks.forEach(function (m) {
        if (m.i < v0 || m.i >= v1) return;
        var x = X(m.i);
        if (m.k === 'arm') tri(x, y(D.l[m.i]) + 6, 4, '#ffdd00', true);
        else if (m.k === 'entry') tri(x, y(D.l[m.i]) + 16, 7, '#ff66cc', true);
        else if (m.k === 'exit') {
          tri(x, y(D.h[m.i]) - 14, 7, m.ret > 0 ? '#ff4040' : '#33bbff', false);
          g.fillStyle = '#eee'; g.font = '11px sans-serif'; g.textAlign = 'center';
          g.fillText((m.ret > 0 ? '+' : '') + m.ret.toFixed(2) + '%', x, y(D.h[m.i]) - 24);
        }
        else if (m.k === 'rej') cross(x, y(D.h[m.i]) - 8, 4, REJ[m.why] || '#fff');
      });
    });
    axis(p, r, y, function (v) { return Math.round(v).toLocaleString(); });
    title(p, '가격 · EMA' + D.emaLen + '(회색) · ST(주황↑/하늘↓) · 녹색음영=안심구간');
    p = lay.mom; r = rng([D.mom], [D.safeTh]); y = ym(p, r);
    clip(p, function () { hl(y, D.safeTh, '#888', [4, 3]); line(D.mom, '#ffcc33', y, 1.2); });
    axis(p, r, y, function (v) { return v.toFixed(1); }); title(p, 'Mom(' + D.momLen + ') · ' + D.safeTh + '선');
    p = lay.macd; r = rng([D.n, D.sig, hist], [0]); y = ym(p, r);
    clip(p, function () {
      bars(hist, function (i, x) { return x >= 0 ? 'rgba(255,90,90,.5)' : 'rgba(90,140,255,.5)'; }, y, 0);
      hl(y, 0, '#888', [4, 3]); line(D.n, '#ff5555', y, 1.2); line(D.sig, '#55aaff', y, 1.2);
    });
    axis(p, r, y, function (v) { return v.toFixed(3); }); title(p, '강도(빨강) · 강도시그널(파랑) · 막대=차이');
    p = lay.amt; r = rng([D.amt], [0]); r[0] = 0; y = ym(p, r);
    clip(p, function () { bars(D.amt, function (i) { return D.big[i] ? '#ff66cc' : '#555a66'; }, y, 0); });
    axis(p, r, y, function (v) { return (v / 1e8).toFixed(1) + '억'; }); title(p, '봉당 거래대금 · 분홍=대량봉(' + D.bigMode + ')');
    p = lay.tick; r = rng([D.cnt1, D.thr], [0]); r[0] = 0; y = ym(p, r);
    clip(p, function () { bars(D.cnt1, function (i) { return D.tickOk[i] ? '#33aa55' : '#555555'; }, y, 0); line(D.thr, '#ffdd00', y, 1); });
    axis(p, r, y, function (v) { return Math.round(v).toLocaleString(); }); title(p, '1분 체결건수 · 노랑=기준(5분평균×' + D.tickK + ')');
    g.fillStyle = '#999'; g.font = '11px sans-serif'; g.textAlign = 'center';
    var last = -1e9;
    for (i = v0; i < v1; i++) { var x = X(i); if (x - last < 80) continue; var hh = String(D.hms[i]).padStart(6, '0'); g.fillText(hh.slice(0, 2) + ':' + hh.slice(2, 4), x, H - 6); last = x; }
    if (cur >= v0 && cur < v1) { g.strokeStyle = 'rgba(255,255,255,.25)'; g.beginPath(); g.moveTo(X(cur), TOP); g.lineTo(X(cur), H - BOT); g.stroke(); }
  }
  function f(x, k) { return x == null || !isFinite(x) ? '-' : Number(x).toFixed(k); }
  function showTip(e) {
    if (cur < 0 || cur >= N) { tip.style.display = 'none'; return; }
    var i = cur, hh = String(D.hms[i]).padStart(6, '0');
    tip.innerHTML = hh.slice(0, 2) + ':' + hh.slice(2, 4) + ':' + hh.slice(4) +
      '<br>O ' + D.o[i] + ' H ' + D.h[i] + ' L ' + D.l[i] + ' C ' + D.c[i] +
      '<br>Mom ' + f(D.mom[i], 2) + (D.safe[i] ? ' (안심)' : '') +
      '<br>강도 ' + f(D.n[i], 4) + ' / 시그널 ' + f(D.sig[i], 4) +
      '<br>EMA ' + f(D.ema[i], 0) + ' · 이격 ' + f(D.disp[i], 1) + '%' +
      '<br>봉대금 ' + f(D.amt[i] / 1e8, 2) + '억' + (D.big[i] ? ' ★' : '') +
      '<br>누적 ' + f(D.taamt[i] / 1e8, 1) + '억' +
      '<br>1분체결 ' + D.cnt1[i] + ' / 기준 ' + f(D.thr[i], 0);
    tip.style.display = 'block';
    tip.style.left = (e.clientX > window.innerWidth - 280 ? e.pageX - 250 : e.pageX + 16) + 'px';
    tip.style.top = (e.pageY + 12) + 'px';
  }
  function resize() {
    var dpr = window.devicePixelRatio || 1;
    W = cv.clientWidth; H = cv.clientHeight;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    var tot = PAN.reduce(function (s, p) { return s + p[1]; }, 0), avail = H - TOP - BOT - GAP * (PAN.length - 1), y = TOP;
    PAN.forEach(function (p) { var h = avail * p[1] / tot; lay[p[0]] = { y: y, h: h }; y += h + GAP; });
    draw();
  }
  cv.addEventListener('wheel', function (e) {
    e.preventDefault();
    var span = v1 - v0, c = Math.min(N - 1, Math.max(0, I(e.offsetX)));
    var ns = Math.round(span * (e.deltaY > 0 ? 1.25 : 0.8)); ns = Math.min(N, Math.max(20, ns));
    var a = Math.round(c - (c - v0) / span * ns); a = Math.max(0, Math.min(N - ns, a));
    v0 = a; v1 = a + ns; draw();
  }, { passive: false });
  cv.addEventListener('mousedown', function (e) { drag = { x: e.offsetX, a: v0, span: v1 - v0 }; });
  window.addEventListener('mouseup', function () { drag = null; });
  cv.addEventListener('mousemove', function (e) {
    if (drag) {
      var sp = (W - LM - RM) / drag.span, d = Math.round((drag.x - e.offsetX) / sp);
      var a = Math.max(0, Math.min(N - drag.span, drag.a + d)); v0 = a; v1 = a + drag.span;
    }
    cur = I(e.offsetX); if (cur < v0 || cur >= v1) cur = -1;
    draw(); showTip(e);
  });
  cv.addEventListener('mouseleave', function () { cur = -1; tip.style.display = 'none'; draw(); });
  cv.addEventListener('dblclick', function () { v0 = 0; v1 = N; draw(); });
  window.addEventListener('resize', resize);
  resize();
})();
'@

# ---------------------------------------------------------------- runner (node CLI)
$runner = @'
'use strict';
const fs = require('fs'), path = require('path');
const SZ = require('./sz-engine.cjs');
const ROOT = process.argv[2], PFILE = process.argv[3];
function die(m) { console.log('FAIL: ' + m); process.exit(1); }
if (!ROOT || !PFILE) die('usage: node sz-run.cjs <root> <params.json>');
let P;
try { P = SZ.prep(JSON.parse(fs.readFileSync(PFILE, 'utf8').replace(/^\uFEFF/, ''))); } catch (e) { die('params: ' + e.message); }
const tickDir = path.join(ROOT, 'data', 'ticks'), dailyDir = path.join(ROOT, 'data', 'daily'), outDir = path.join(ROOT, 'out', 'trade');
fs.mkdirSync(outDir, { recursive: true });
if (!fs.existsSync(tickDir)) die('no folder: ' + tickDir);
let files = fs.readdirSync(tickDir).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(P.Match));
if (P.Date) files = files.filter(f => f.includes(P.Date));
if (!files.length) die('no tick csv matching "' + P.Match + '" in ' + tickDir);
const RENDER = fs.readFileSync(path.join(__dirname, 'sz-render.js'), 'utf8');

function parseCsv(text) {
  text = text.replace(/^\uFEFF/, '');
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(f); f = ''; }
    else if (ch === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (ch !== '\r') f += ch;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows.filter(r => r.length > 1 || r[0] !== '');
}
function num(s) { const t = String(s == null ? '' : s).replace(/[,\s+]/g, ''); return t === '' ? NaN : Number(t); }
function stamp(ts, ds) {
  let t = String(ts == null ? '' : ts).replace(/\D/g, ''); const d = ds != null ? String(ds).replace(/\D/g, '') : '';
  if (t.length >= 14) return t.slice(0, 14);
  if ((t.length === 6 || t.length === 5) && d.length >= 8) return d.slice(0, 8) + t.padStart(6, '0');
  if (t.length === 4 && d.length >= 8) return d.slice(0, 8) + t + '00';
  if (t.length === 10 || t.length === 13) {
    const ms = t.length === 13 ? Number(t) : Number(t) * 1000;
    return new Date(ms + 9 * 3600e3).toISOString().replace(/\D/g, '').slice(0, 14);
  }
  return null;
}
function loadTicks(file) {
  const rows = parseCsv(fs.readFileSync(file, 'utf8'));
  if (rows.length < 2) throw new Error('empty csv');
  const hdr = rows[0].map(x => x.trim().toLowerCase());
  const find = names => { for (const nm of names) { const k = hdr.indexOf(nm); if (k >= 0) return k; } return -1; };
  const iT = find(['cntr_tm', 'time', 'ts', 'datetime', 'timestamp', 'dt']);
  const iD = find(['date', 'trading_date', 'tradingdate', 'trade_date', 'day']);
  const iO = find(['open', 'open_pric', 'o']), iH = find(['high', 'high_pric', 'h']), iL = find(['low', 'low_pric', 'l']);
  const iC = find(['close', 'cur_prc', 'c', 'price']), iV = find(['volume', 'trde_qty', 'vol', 'v', 'qty']);
  if ([iT, iO, iH, iL, iC, iV].some(k => k < 0)) throw new Error('columns not found, header=' + hdr.join('|'));
  const bars = [];
  for (let r = 1; r < rows.length; r++) {
    const row = rows[r], st = stamp(row[iT], iD >= 0 ? row[iD] : null);
    if (!st) continue;
    let o = Math.abs(num(row[iO])), h = Math.abs(num(row[iH])), l = Math.abs(num(row[iL])), c = Math.abs(num(row[iC])), v = Math.abs(num(row[iV]));
    if (!(c > 0) || !isFinite(v)) continue;
    if (!(o > 0)) o = c;
    h = Math.max(h > 0 ? h : c, o, c); l = Math.min(l > 0 ? l : c, o, c);
    const y = +st.slice(0, 4), mo = +st.slice(4, 6), d = +st.slice(6, 8), hh = +st.slice(8, 10), mi = +st.slice(10, 12), ss = +st.slice(12, 14);
    bars.push({ d: st.slice(0, 8), hms: hh * 10000 + mi * 100 + ss, t: Date.UTC(y, mo - 1, d, hh, mi, ss) / 1000, o, h, l, c, v });
  }
  if (bars.length < 10) throw new Error('too few bars: ' + bars.length + ', header=' + hdr.join('|'));
  if (bars[0].t > bars[bars.length - 1].t) bars.reverse();
  for (let i = 1; i < bars.length; i++) if (bars[i].t < bars[i - 1].t) { bars.sort((a, b) => a.t - b.t); break; }
  return bars;
}
function loadDaily(code, date, warn) {
  const f = path.join(dailyDir, code + '.csv');
  if (!fs.existsSync(f)) { warn.push('일봉 파일 없음(' + f + '): 전일 상한가/급등 필터 미적용 → 12_fetch_daily.ps1 실행'); return null; }
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), h = rows[0].map(x => x.trim().toLowerCase());
  const iD = h.indexOf('date'), iC = h.indexOf('close'), iP = h.indexOf('chg_pct');
  if (iD < 0 || iC < 0) { warn.push('일봉 열 없음: ' + h.join('|')); return null; }
  const list = rows.slice(1).map(r => ({ d: String(r[iD]).replace(/\D/g, '').slice(0, 8), c: Math.abs(num(r[iC])), p: iP >= 0 ? num(r[iP]) : NaN }))
    .filter(x => x.d.length === 8 && x.c > 0).sort((a, b) => a.d < b.d ? -1 : a.d > b.d ? 1 : 0);
  let k = -1; for (let j = 0; j < list.length; j++) if (list[j].d < date) k = j;
  if (k < 0) { warn.push('일봉에 ' + date + ' 이전 데이터 없음'); return null; }
  let chg = list[k].p;
  if (!isFinite(chg) && k > 0) chg = (list[k].c / list[k - 1].c - 1) * 100;
  return { d: list[k].d, chg };
}
const fmtT = hms => { const s = String(hms).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };
const fmtPx = x => x == null || !isFinite(x) ? '-' : Math.round(x).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const sgn = x => (x > 0 ? '+' : '') + x.toFixed(2);
const RULE_KO = { hold: '보유', immediate: '즉시', macd_zero: '강도0선↓', macd_sig: '시그널↓', supertrend: 'ST하락', trail: '트레일' };
const ST_KO = { 'S-': '안심·목표전', 'S+': '안심·목표후', 'U-': '이탈·목표전', 'U+': '이탈·목표후' };
function whyKo(w) {
  if (w === 'stop') return '손절'; if (w === 'time') return '시간청산'; if (w === 'eod') return '데이터끝';
  const p = w.split(':'); return (ST_KO[p[0]] || p[0]) + ' ' + (RULE_KO[p[1]] || p[1]);
}
function sumLine(S) { return '거래 ' + S.n + ', 승 ' + S.w + ', 합계 ' + sgn(S.sum) + '%, 평균 ' + sgn(S.avg) + '%, 평균MFE ' + sgn(S.avgMfe) + '%'; }
function tradeTable(title, tr, bars) {
  let h = '<h3>' + title + '</h3><table><tr><th>#</th><th>진입</th><th>진입가</th><th>청산</th><th>청산가</th><th>사유</th><th>순수익%</th><th>MFE%</th><th>MAE%</th><th>봉수</th><th>목표도달</th></tr>';
  tr.forEach((t, k) => {
    h += '<tr><td>' + (k + 1) + '</td><td>' + fmtT(bars[t.inI].hms) + '</td><td>' + fmtPx(t.inPx) + '</td><td>' + fmtT(bars[t.outI].hms) +
      '</td><td>' + fmtPx(t.outPx) + '</td><td>' + whyKo(t.why) + '</td><td class="' + (t.ret > 0 ? 'up' : 'dn') + '">' + sgn(t.ret) +
      '</td><td>' + sgn(t.mfe) + '</td><td>' + sgn(t.mae) + '</td><td>' + t.bars + '</td><td>' + (t.reached ? 'Y' : '') + '</td></tr>';
  });
  if (!tr.length) h += '<tr><td colspan="11">거래 없음</td></tr>';
  return h + '</table>';
}
const STYLE = '<style>body{background:#111;color:#ddd;font:13px "Malgun Gothic",sans-serif;margin:8px}a{color:#6cf}' +
  'table{border-collapse:collapse;margin:6px 0}td,th{border:1px solid #333;padding:3px 8px;text-align:right}th{background:#222}' +
  '.up{color:#ff6b6b}.dn{color:#5cc8ff}.warn{color:#ffcc33}#tip{position:absolute;display:none;pointer-events:none;background:rgba(0,0,0,.88);' +
  'border:1px solid #555;padding:6px 8px;font:12px "Malgun Gothic",sans-serif;line-height:1.45}</style>';

const sum = [], idx = [], csv = ['\uFEFFcode,date,mode,no,in_time,in_px,out_time,out_px,why,ret_pct,mfe_pct,mae_pct,bars,reached'];
let failed = 0, totS = [], totB = [];
for (const f of files) {
  try {
    const code = f.split('_')[0];
    const m = f.match(/_(\d+)t_/);
    const Pf = Object.assign({}, P, { TickScope: m ? Number(m[1]) : P.TickScope });
    const bars = loadTicks(path.join(tickDir, f));
    const dm = f.match(/(\d{8})\.csv$/i);
    const date = P.Date || (dm ? dm[1] : bars[bars.length - 1].d);
    const start = bars.findIndex(b => b.d === date);
    if (start < 0) throw new Error('target date ' + date + ' not in file');
    const warn = [];
    const dayComplete = bars[start].hms <= Pf._sessMax;
    if (!dayComplete) warn.push('당일 첫 봉 ' + fmtT(bars[start].hms) + ' (장 시작 봉 아님): 누적대금 판정 불가 → 진입 없음');
    if (start < Pf.EmaLen * 3) warn.push('EMA' + Pf.EmaLen + ' 워밍업 ' + start + '봉(권장 ' + Pf.EmaLen * 3 + '+): 영웅문 값과 다를 수 있음');
    const dly = loadDaily(code, date, warn);
    let limKind = null;
    if (dly && isFinite(dly.chg)) { if (dly.chg >= Pf.LimPct) limKind = 'limit'; else if (dly.chg >= Pf.SurgePct) limKind = 'surge'; }
    const ind = SZ.compute(bars, Pf);
    const ctx = { start, date, dayComplete, limKind };
    const R = SZ.simulate(bars, ind, Pf, ctx);
    const PB = Object.assign({}, Pf, { SafeBelow: 'macd_sig', SafeAbove: 'macd_sig', UnsafeBelow: 'macd_sig', UnsafeAbove: 'macd_sig' });
    const RB = SZ.simulate(bars, ind, PB, ctx);
    const S1 = SZ.summarize(R.trades), S2 = SZ.summarize(RB.trades);
    totS = totS.concat(R.trades); totB = totB.concat(RB.trades);
    const addCsv = (mode, tr) => tr.forEach((t, k) => csv.push([code, date, mode, k + 1, fmtT(bars[t.inI].hms), t.inPx.toFixed(0),
      fmtT(bars[t.outI].hms), t.outPx.toFixed(0), whyKo(t.why), t.ret.toFixed(3), t.mfe.toFixed(3), t.mae.toFixed(3), t.bars, t.reached ? 1 : 0].join(',')));
    addCsv('safezone', R.trades); addCsv('baseline', RB.trades);
    // 차트는 대상일 + 앞쪽 300봉만 표시
    const v0 = Math.max(0, start - 300), sl = a => a.slice(v0);
    const rd = (a, k) => a.slice(v0).map(x => x == null || !isFinite(x) ? null : +Number(x).toFixed(k));
    const shiftT = t => Object.assign({}, t, { inI: t.inI - v0, outI: t.outI - v0 });
    const D = {
      o: sl(bars.map(b => b.o)), h: sl(bars.map(b => b.h)), l: sl(bars.map(b => b.l)), c: sl(bars.map(b => b.c)), hms: sl(bars.map(b => b.hms)),
      mom: rd(ind.mom, 3), n: rd(ind.n, 5), sig: rd(ind.sig, 5), ema: rd(ind.ema, 1), st: rd(ind.st, 1), stDir: sl(ind.stDir),
      amt: rd(ind.amt, 0), taamt: rd(ind.taamt, 0), big: sl(ind.big), cnt1: sl(ind.cnt1), thr: rd(ind.thr, 0), tickOk: sl(ind.tickOk),
      disp: rd(ind.disp, 2), safe: sl(ind.safe),
      trades: R.trades.map(shiftT), marks: R.marks.map(m => Object.assign({}, m, { i: m.i - v0 })),
      emaLen: Pf.EmaLen, momLen: Pf.MomLen, safeTh: Pf.SafeTh, bigMode: Pf.BigMode, tickK: Pf.TickK };
    const rejTxt = Object.keys(R.rej).map(k => k + '=' + R.rej[k]).join(' ');
    const head = '<h2>' + code + ' · ' + date + '</h2><div>전일 ' + (dly && isFinite(dly.chg) ? sgn(dly.chg) + '%' : '-') +
      ' / 구분 ' + (limKind || '일반') + ' (' + R.limMode + ') · ARM ' + R.arms + ' · 신호 ' + R.sigs + ' · 탈락 ' + rejTxt + '</div>' +
      '<div class="up">SafeZone: ' + sumLine(S1) + '</div><div class="dn">기본규칙(시그널↓): ' + sumLine(S2) + '</div>' +
      warn.map(w => '<div class="warn">⚠ ' + w + '</div>').join('');
    const html = '<!doctype html><html><head><meta charset="utf-8"><title>' + code + ' ' + date + '</title>' + STYLE + '</head><body>' +
      '<a href="index.html">← 목록</a>' + head + '<canvas id="cv" style="width:100%;height:78vh;display:block"></canvas><div id="tip"></div>' +
      tradeTable('SafeZone 거래', R.trades, bars) + tradeTable('기본규칙 거래', RB.trades, bars) +
      '<script>window.SZDATA=' + JSON.stringify(D) + ';</script><script>' + RENDER + '</script></body></html>';
    const outF = code + '_' + date + '.html';
    fs.writeFileSync(path.join(outDir, outF), html, 'utf8');
    idx.push('<tr><td><a href="' + outF + '">' + code + '</a></td><td>' + date + '</td><td>' + S1.n + '</td><td class="' + (S1.sum > 0 ? 'up' : 'dn') + '">' + sgn(S1.sum) +
      '</td><td>' + S2.n + '</td><td class="' + (S2.sum > 0 ? 'up' : 'dn') + '">' + sgn(S2.sum) + '</td></tr>');
    sum.push('[' + code + ' ' + date + '] 전일 ' + (dly && isFinite(dly.chg) ? sgn(dly.chg) + '%' : '-') + ' ' + (limKind || '일반') + ' | ARM ' + R.arms + ' 신호 ' + R.sigs + ' | 탈락 ' + rejTxt);
    sum.push('   SafeZone : ' + sumLine(S1));
    R.trades.forEach((t, k) => sum.push('     ' + (k + 1) + ') ' + fmtT(bars[t.inI].hms) + ' ' + fmtPx(t.inPx) + ' → ' + fmtT(bars[t.outI].hms) + ' ' + fmtPx(t.outPx) +
      ' ' + sgn(t.ret) + '% (MFE ' + sgn(t.mfe) + ', MAE ' + sgn(t.mae) + ') ' + whyKo(t.why)));
    sum.push('   기본규칙 : ' + sumLine(S2));
    warn.forEach(w => sum.push('   [주의] ' + w));
    console.log('OK ' + f + ' sz=' + S1.n + '/' + S1.sum.toFixed(2) + ' base=' + S2.n + '/' + S2.sum.toFixed(2));
  } catch (e) { failed++; sum.push('[실패] ' + f + ': ' + e.message); console.log('FAIL ' + f + ': ' + e.message); }
}
const TS = SZ.summarize(totS), TB = SZ.summarize(totB);
sum.push('=== 전체 SafeZone : ' + sumLine(TS));
sum.push('=== 전체 기본규칙 : ' + sumLine(TB));
fs.writeFileSync(path.join(outDir, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><title>SafeZone</title>' + STYLE + '</head><body><h2>SafeZone 2단계</h2>' +
  '<div class="up">SafeZone: ' + sumLine(TS) + '</div><div class="dn">기본규칙: ' + sumLine(TB) + '</div>' +
  '<table><tr><th>종목</th><th>일자</th><th>SZ 거래</th><th>SZ 합계%</th><th>기본 거래</th><th>기본 합계%</th></tr>' + idx.join('') + '</table></body></html>', 'utf8');
fs.writeFileSync(path.join(outDir, 'trades.csv'), csv.join('\r\n'), 'utf8');
fs.writeFileSync(path.join(outDir, 'summary.txt'), sum.join('\r\n'), 'utf8');
console.log(failed ? 'DONE WITH ' + failed + ' FAIL' : 'DONE ' + files.length + ' files');
process.exit(failed ? 2 : 0);
'@

# ---------------------------------------------------------------- write files
try {
  Write-Utf8NoBom (Join-Path $tools 'sz-engine.cjs')   $engine
  Write-Utf8NoBom (Join-Path $tools 'sz-selftest.cjs') $selftest
  Write-Utf8NoBom (Join-Path $tools 'sz-render.js')   $render
  Write-Utf8NoBom (Join-Path $tools 'sz-run.cjs')      $runner
  Ok "엔진 파일 4개 기록: $tools"
} catch { Fail "파일 기록 실패: $($_.Exception.Message)"; exit 1 }

# ---------------------------------------------------------------- selftest
$ErrorActionPreference = 'Continue'; $st = & node (Join-Path $tools 'sz-selftest.cjs') 2>&1
$stCode = $LASTEXITCODE
$st | ForEach-Object { Info $_ }
if ($stCode -ne 0) { Fail '자가검증 실패 - 위 FAIL 줄을 붙여주세요'; exit 1 }
Ok '자가검증 통과'
if ($SelfTestOnly) { exit 0 }

# ---------------------------------------------------------------- params
$P = [ordered]@{}
foreach ($k in $PSBoundParameters.Keys) { }  # (명시 여부와 무관하게 전체 전달)
foreach ($name in @('Match','Date','MomLen','SafeTh','SafeExitTh','SafeConfirm','P1','P2','P3','StrongA','BigMode','BigTh','RelWin','RelK',
  'BigNeedUp','BigNeedST','ArmSkip','ArmSameSession','EmaLen','StLen','StMult','TickK','TickAbs','DispMax','DispUntil','LimPct','SurgePct',
  'LimMode','SurgeMode','PbPct','EntryStart','EntryEnd','ExitTime','SessionStartMax','TargetPct','StopPct','TrailPct',
  'SafeBelow','SafeAbove','UnsafeBelow','UnsafeAbove','FeePct','SlipPct','MaxTrades','ArmMode','SafeNoLoss','SafeMinPct','ReentryGap')) {
  $P[$name] = (Get-Variable -Name $name -ValueOnly)
}
$pFile = Join-Path $out 'params.json'
try { Write-Utf8NoBom $pFile ($P | ConvertTo-Json) } catch { Fail "params 기록 실패: $($_.Exception.Message)"; exit 1 }
Info "규칙: 안심·목표전=$SafeBelow / 안심·목표후=$SafeAbove / 이탈·목표전=$UnsafeBelow / 이탈·목표후=$UnsafeAbove"
Info "목표 $TargetPct% / 손절 $StopPct% / 진입 $EntryStart~$EntryEnd / 청산 $ExitTime / 수수료 $FeePct%"

# ---------------------------------------------------------------- run
$rn = & node (Join-Path $tools 'sz-run.cjs') $Root $pFile 2>&1
$rnCode = $LASTEXITCODE
$rn | ForEach-Object { Info $_ }
$sumF = Join-Path $out 'summary.txt'
if (Test-Path $sumF) {
  Write-Host '----- 요약 -----'
  Get-Content $sumF -Encoding UTF8 | ForEach-Object { Write-Host $_ }
}
if ($rnCode -eq 1) { Fail '실행 실패 - 위 FAIL 줄을 붙여주세요'; exit 1 }
if ($rnCode -eq 2) { Fail '일부 종목 실패 (요약의 [실패] 줄 확인)' } else { Ok "완료: $out" }
$index = Join-Path $out 'index.html'
if (-not $NoOpen -and (Test-Path $index)) { Start-Process $index }
