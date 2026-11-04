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