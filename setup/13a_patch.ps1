#requires -Version 5.1
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
$f = 'E:\parent\projects\rea\projects\mom-trader\setup\13_trade.ps1'
$enc = New-Object System.Text.UTF8Encoding($true)
$t = [IO.File]::ReadAllText($f, $enc)
if ($t.Contains('ArmMode')) { Write-Host '[정보] 이미 패치되어 있음'; exit 0 }
$miss = New-Object System.Collections.ArrayList
function Rep([string]$a, [string]$b) { if ($script:t.Contains($a)) { $script:t = $script:t.Replace($a, $b) } else { [void]$script:miss.Add($a) } }

# --- 파라미터 기본값 / 신규 파라미터
Rep '[string]$SafeBelow = ''macd_zero''' '[string]$SafeBelow = ''hold'''
Rep '[string]$BigMode = ''rel''' '[string]$BigMode = ''abs'''
Rep '[double]$BigTh = 1e8' '[double]$BigTh = 5e7'
Rep '[double]$TickK = 1.5' '[double]$TickK = 1.0'
$newP = '[ValidateSet(''state'',''cross'')][string]$ArmMode = ''state'', [int]$SafeNoLoss = 1, [double]$SafeMinPct = 0, [int]$ReentryGap = 0,' + "`r`n  " + '[switch]$SelfTestOnly, [switch]$NoOpen'
Rep '[switch]$SelfTestOnly, [switch]$NoOpen' $newP
Rep "'FeePct','SlipPct','MaxTrades'))" "'FeePct','SlipPct','MaxTrades','ArmMode','SafeNoLoss','SafeMinPct','ReentryGap'))"
# --- 엔진 DEFAULTS
Rep "SafeBelow: 'macd_zero'" "SafeBelow: 'hold'"
Rep "BigMode: 'rel'" "BigMode: 'abs'"
Rep "BigTh: 1e8" "BigTh: 5e7"
Rep "TickK: 1.5" "TickK: 1.0"
Rep "FeePct: 0.25, SlipPct: 0, MaxTrades: 10," "FeePct: 0.25, SlipPct: 0, MaxTrades: 10, ArmMode: 'state', SafeNoLoss: 1, SafeMinPct: 0, ReentryGap: 0,"

# --- simulate 교체
$sim = @'
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
'@

# --- selftest 교체 (기존 16 + 신규 5 = 21항목)
$self = @'
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

$a = $t.IndexOf('  function simulate(')
$b = $t.IndexOf('  function summarize(')
if ($a -lt 0 -or $b -le $a) { [void]$miss.Add('engine simulate block') } else { $t = $t.Substring(0, $a) + $sim + "`r`n" + $t.Substring($b) }
$a = $t.IndexOf("`$selftest = @'")
$b = $t.IndexOf("`$render = @'")
if ($a -lt 0 -or $b -le $a) { [void]$miss.Add('selftest block') } else { $t = $t.Substring(0, $a) + "`$selftest = @'`r`n" + $self + "`r`n'@`r`n`r`n# ---- renderer (browser)`r`n" + $t.Substring($b) }

if ($miss.Count) { Write-Host '[실패] 다음 부분을 찾지 못해 파일을 바꾸지 않았습니다:' -ForegroundColor Red; $miss | ForEach-Object { Write-Host "  $_" }; exit 1 }
[IO.File]::Copy($f, $f + '.bak', $true)
[IO.File]::WriteAllText($f, $t, $enc)
Write-Host '[성공] 패치 완료 (백업: 13_trade.ps1.bak)' -ForegroundColor Green
