'use strict';
// sz-engine3.cjs - SafeZone engine v3 = v1 simulate (same order) + risk hooks + portfolio runner.
// Factory: require(v3)(V1, R). V1 and R must be hash-verified by caller.
module.exports = function make(V1, R) {
  const VERSION = 'v3.0';
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
  function createSim(bars, ind, P, ctx, RP, hooks) {
    hooks = hooks || {};
    const trades = [], marks = [];
    const rej = { time: 0, count: 0, gap: 0, lim: 0, ema: 0, disp: 0, tick: 0 };
    const armMode = P.ArmMode === 'cross' ? 'cross' : 'state';
    const noLoss = Number(P.SafeNoLoss == null ? 1 : P.SafeNoLoss) > 0;
    const minPct = Number(P.SafeMinPct || 0), gap = Number(P.ReentryGap || 0);
    let armed = false, pos = null, hiDay = 0, pbDone = false, arms = 0, sigs = 0, lastI = -1, lastExit = -1e9, held = 0;
    const limMode = ctx.limKind === 'limit' ? P.LimMode : ctx.limKind === 'surge' ? P.SurgeMode : 'off';
    const useR = !!RP, fee = P.FeePct, env = { feePct: P.FeePct, hms: 0 };
    const closeTrade = (i, px, why) => {
      let gross;
      if (!pos.parts.length) gross = (px / pos.entry - 1) * 100;
      else {
        gross = 0;
        for (const q of pos.parts) gross += q.frac * (q.px / pos.entry - 1) * 100;
        gross += pos.frac * (px / pos.entry - 1) * 100;
      }
      const ret = gross - fee;
      const t = { inI: pos.idx, inPx: pos.entry, outI: i, outPx: px, why, gross, ret,
        mfe: (pos.hi / pos.entry - 1) * 100, mae: (pos.lo / pos.entry - 1) * 100, bars: i - pos.idx, reached: pos.reached, held: pos.held };
      if (pos.parts.length) t.parts = pos.parts.map(q => ({ i: q.i, px: q.px, frac: q.frac, why: q.why }));
      trades.push(t);
      marks.push({ i, k: 'exit', why, ret });
      const lastRet = (px / pos.entry - 1) * 100 - fee;
      pos = null; lastExit = i;
      if (hooks.onExit) hooks.onExit(t, lastRet, bars[i]);
    };
    function step(i) {
      const b = bars[i];
      if (i < ctx.start || b.d !== ctx.date) return;
      lastI = i;
      if (b.h > hiDay) hiDay = b.h;
      if (hiDay > 0 && (hiDay - b.l) / hiDay * 100 >= P.PbPct) pbDone = true;
      if (pos && i > pos.idx) {
        if (b.h > pos.hi) pos.hi = b.h;
        if (b.l < pos.lo) pos.lo = b.l;
        const stopPx = P.StopPct > 0 ? pos.entry * (1 - P.StopPct / 100) : -1;
        let xPx = null, xWhy = null;
        if (b.l <= stopPx) { xPx = Math.min(b.o, stopPx); xWhy = 'stop'; }
        let racts = [];
        if (useR) { env.hms = b.hms; racts = R.onBar(RP, pos.r, b, i, env); }
        const rl = racts.find(a => a.type === 'exit' && a.why !== 'tp' && a.why !== 'time');
        if (rl && (xPx == null || rl.px > xPx)) { xPx = rl.px; xWhy = 'r_' + rl.why; }
        if (xPx != null) closeTrade(i, xPx, xWhy);
        else {
          for (const a of racts) if (a.type === 'partial') {
            pos.parts.push({ i, px: a.px, frac: a.frac, why: 'r_tp' });
            pos.frac = pos.r.frac;
            if (hooks.onPartial) hooks.onPartial(a.frac, (a.px / pos.entry - 1) * 100 - fee);
          }
          const tpx = racts.find(a => a.type === 'exit' && a.why === 'tp');
          if (tpx) closeTrade(i, tpx.px, 'r_tp');
          else if (b.hms >= P._exitT) closeTrade(i, b.c, 'time');
          else if (useR && R.flattenDue(RP, b.hms)) closeTrade(i, b.c, 'r_flat');
          else if (racts.some(a => a.type === 'exit' && a.why === 'time')) closeTrade(i, b.c, 'r_time');
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
        }
        if (!pos) return;
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
      if (pos || !armed) return;
      const signal = ind.big[i] && (!P.BigNeedUp || b.c > b.o) && (!P.BigNeedST || (ind.st[i] != null && b.c > ind.st[i]));
      if (!signal) return;
      sigs++;
      let why = null;
      if (b.hms < P._entS || b.hms >= P._entE) why = 'time';
      else if (P.MaxTrades > 0 && trades.length >= P.MaxTrades) why = 'count';
      else if (i - lastExit <= gap) why = 'gap';
      else if (limMode === 'block' || (limMode === 'pullback' && !pbDone)) why = 'lim';
      else if (!(b.c > ind.ema[i])) why = 'ema';
      else if (b.hms < P._dispU && ind.disp[i] > P.DispMax) why = 'disp';
      else if (!ind.tickOk[i]) why = 'tick';
      let op = null;
      if (!why && useR) {
        if (R.flattenDue(RP, b.hms)) why = 'r_flat';
        else {
          const ss = RP.position.structStop;
          const o = R.openPosition(RP, { px: b.c * (1 + P.SlipPct / 100), idx: i, structLow: ss.enabled ? R.structLow(bars, i, ss.lookback) : null });
          if (o.reject) why = 'r_' + o.reject; else op = o.pos;
        }
      }
      if (!why && hooks.canEnter) { const g = hooks.canEnter(i, b); if (!g.ok) why = 'r_' + g.why; }
      if (why) { rej[why] = (rej[why] || 0) + 1; marks.push({ i, k: 'rej', why }); return; }
      pos = { idx: i, entry: b.c * (1 + P.SlipPct / 100), hi: b.c, lo: b.c, peakC: b.c, reached: false, held: 0, parts: [], frac: 1, r: op };
      armed = false;
      marks.push({ i, k: 'entry' });
      if (hooks.onEntry) hooks.onEntry(i, b);
    }
    const result = () => ({ trades, marks, rej, arms, sigs, limMode, pbDone, held });
    return {
      step,
      curRet: () => (pos && lastI >= 0 ? (bars[lastI].c / pos.entry - 1) * 100 - fee : null),
      forceExit: why => { if (pos && lastI >= 0) closeTrade(lastI, bars[lastI].c, why); },
      finish: () => { if (pos && lastI >= 0) closeTrade(lastI, bars[lastI].c, 'eod'); return result(); }
    };
  }
  function simulate(bars, ind, P, ctx, RP, hooks) {
    const sim = createSim(bars, ind, P, ctx, RP, hooks);
    for (let i = ctx.start; i < bars.length; i++) sim.step(i);
    return sim.finish();
  }
  // items: [{code, source, bars, ind, P, ctx}] ; opts: {topK, rankBy:'ticks'|'amount'}
  function runPortfolio(items, RP, opts) {
    opts = opts || {};
    const topK = opts.topK | 0, by = opts.rankBy === 'amount' ? 'amount' : 'ticks';
    const acc = RP ? R.createAccount(RP) : null;
    const w = RP ? Math.min(RP.account.maxSlots.enabled ? 1 / RP.account.maxSlots.n : 1, RP.sizing.maxWeightPct / 100) : 1;
    const out = items.map(() => null);
    const dates = Array.from(new Set(items.map(x => x.ctx.date))).sort();
    for (const d of dates) {
      const ks = []; items.forEach((x, k) => { if (x.ctx.date === d) ks.push(k); });
      const cnt = {}, amt = {}, sims = {};
      ks.forEach(k => { cnt[k] = 0; amt[k] = 0; });
      const rankOk = k => {
        if (topK <= 0) return true;
        const m = by === 'amount' ? amt : cnt; let r = 0;
        for (const j of ks) if (j !== k && (m[j] > m[k] || (m[j] === m[k] && j < k))) r++;
        return r < topK;
      };
      for (const k of ks) {
        const it = items[k], code = it.code, src = it.source || '_', hooks = {};
        if (acc || topK > 0) hooks.canEnter = (i, b) => {
          if (!rankOk(k)) return { ok: false, why: 'rank' };
          return acc ? acc.canEnter({ code, source: src, tsec: R.secOfDay(b.hms), day: b.d }) : { ok: true };
        };
        if (acc) {
          hooks.onEntry = (i, b) => acc.onEntry({ code, source: src, tsec: R.secOfDay(b.hms), day: b.d, w });
          hooks.onPartial = (frac, ret) => acc.onPartial(code, w * frac, ret);
          hooks.onExit = (t, lastRet, b) => acc.onExit({ code, retPct: lastRet, tradeRetPct: t.ret, tsec: R.secOfDay(b.hms) });
        }
        sims[k] = createSim(it.bars, it.ind, it.P, it.ctx, RP, hooks);
      }
      const ev = [];
      for (const k of ks) { const it = items[k]; for (let i = it.ctx.start; i < it.bars.length; i++) if (it.bars[i].d === d) ev.push([it.bars[i].t, k, i]); }
      ev.sort((a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2]);
      for (const e of ev) {
        const k = e[1], i = e[2], b = items[k].bars[i];
        cnt[k]++; amt[k] += (b.o + b.h + b.l + b.c) / 4 * b.v;
        sims[k].step(i);
        if (acc) {
          const cr = sims[k].curRet();
          if (cr != null && acc.mark(items[k].code, cr) === 'flatten') for (const j of ks) sims[j].forceExit('r_dlflat');
        }
      }
      for (const k of ks) out[k] = sims[k].finish();
    }
    return out;
  }
  return { VERSION, hit, createSim, simulate, runPortfolio };
};