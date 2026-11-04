'use strict';
// sz-risk.cjs - SafeZone risk layer. Rule: may only BLOCK entries or FORCE exits.
// Never creates entries, never delays strategy exits. No I/O.
const VERSION = 'risk-1.1';
const DEF = {
  id: 'RP000',
  name: 'all off',
  account: {
    maxSlots:            { enabled: false, n: 3 },
    maxEntriesPerSource: { enabled: false, n: 1 },
    maxDailyEntries:     { enabled: false, n: 10 },
    dailyLoss:           { enabled: false, pct: 2, action: 'block' },
    dailyProfitLock:     { enabled: false, pct: 5, action: 'block' },
    consecLoss:          { enabled: false, n: 3, pauseMin: 30 },
    noReentrySameDay:    { enabled: false },
    flatten:             { enabled: false, time: '151500', allowOvernight: false }
  },
  position: {
    hardStop:   { enabled: false, pct: 3 },
    structStop: { enabled: false, lookback: 20, bufTicks: 1, maxPct: 3, onFar: 'skip' },
    takeProfit: { enabled: false, pct: 5, ratio: 0.5 },
    protect:    { enabled: false, atPct: 2, levelPct: 0 },
    trail:      { enabled: false, afterPct: 3, dropPct: 2 },
    timeStop:   { enabled: false, bars: 30, minPct: 0.5 },
    manualHoldKeepsHardStop: true
  },
  timing: { guard: 'tick', ignoreBeforeHms: 90000, startMode: 'entryFirst', restartCheck: 'confirm' },
  order: {
    entryPrice: 'market', entryOffsetTicks: 0, exitPrice: 'market', exitOffsetTicks: 0,
    pendingCancel: { enabled: false, sec: 120 }
  },
  sizing: { mode: 'fixedAmount', amount: 1000000, pctCash: 20, riskPerTradePct: 0.5, maxWeightPct: 30 }
};

function isObj(x) { return !!x && typeof x === 'object' && !Array.isArray(x); }
function merge(a, b) {
  const o = Object.assign({}, a);
  if (!isObj(b)) return o;
  for (const k of Object.keys(b)) o[k] = (isObj(a && a[k]) && isObj(b[k])) ? merge(a[k], b[k]) : b[k];
  return o;
}
function load(profile) { return merge(DEF, profile || {}); }
function enabledList(P) {
  const out = [];
  (function walk(o, pre) {
    for (const k of Object.keys(o)) {
      const v = o[k];
      if (isObj(v)) { if (v.enabled === true) out.push(pre + k); walk(v, pre + k + '.'); }
    }
  })(P, '');
  return out;
}
function isPassive(P) { return enabledList(P).length === 0; }
function unknownKeys(obj, def, pre) {
  def = def || DEF; pre = pre || '';
  const out = [];
  if (!isObj(obj)) return out;
  for (const k of Object.keys(obj)) {
    if (pre === '' && k === 'note') continue;
    if (!(k in def)) out.push(pre + k);
    else if (isObj(def[k])) out.push(...unknownKeys(obj[k], def[k], pre + k + '.'));
  }
  return out;
}
function validate(P) {
  const e = [], c = (ok, m) => { if (!ok) e.push(m); };
  const a = P.account, p = P.position;
  c(['block', 'flatten'].includes(a.dailyLoss.action), 'account.dailyLoss.action');
  c(['block', 'flatten'].includes(a.dailyProfitLock.action), 'account.dailyProfitLock.action');
  c(/^\d{6}$/.test(String(a.flatten.time)), 'account.flatten.time(HHMMSS)');
  c(p.hardStop.pct > 0, 'position.hardStop.pct');
  c(p.structStop.maxPct > 0 && p.structStop.lookback >= 1, 'position.structStop');
  c(['skip', 'cap'].includes(p.structStop.onFar), 'position.structStop.onFar');
  c(p.takeProfit.pct > 0 && p.takeProfit.ratio > 0 && p.takeProfit.ratio <= 1, 'position.takeProfit');
  c(p.trail.dropPct > 0, 'position.trail.dropPct');
  c(p.timeStop.bars >= 1, 'position.timeStop.bars');
  c(['tick', 'barClose'].includes(P.timing.guard), 'timing.guard');
  c(['fixedAmount', 'pctCash', 'riskBased'].includes(P.sizing.mode), 'sizing.mode');
  c(P.sizing.maxWeightPct > 0 && P.sizing.maxWeightPct <= 100, 'sizing.maxWeightPct');
  return e;
}

// KRX tick size (2023 unified rule)
function tickSize(p) {
  if (p < 2000) return 1; if (p < 5000) return 5; if (p < 20000) return 10;
  if (p < 50000) return 50; if (p < 200000) return 100; if (p < 500000) return 500; return 1000;
}
function hms(t) {
  if (t == null) return NaN;
  if (typeof t === 'number') {
    if (t > 1e11) t = Math.floor(t / 1000);
    const s = ((t + 32400) % 86400 + 86400) % 86400;
    return Math.floor(s / 3600) * 10000 + Math.floor((s % 3600) / 60) * 100 + (s % 60);
  }
  const d = String(t).replace(/\D/g, '');
  if (d.length >= 14) return +d.slice(8, 14);
  if (d.length === 6) return +d;
  if (d.length === 4) return +d * 100;
  return NaN;
}
function dayKey(t) {
  if (typeof t === 'number') {
    if (t > 1e11) t = Math.floor(t / 1000);
    return new Date((t + 32400) * 1000).toISOString().slice(0, 10).replace(/-/g, '');
  }
  return String(t).replace(/\D/g, '').slice(0, 8);
}
function secOfDay(h) { return Math.floor(h / 10000) * 3600 + Math.floor((h % 10000) / 100) * 60 + (h % 100); }
function ohlc(b) {
  return { o: +(b.open ?? b.o), h: +(b.high ?? b.h), l: +(b.low ?? b.l), c: +(b.close ?? b.c) };
}
function structLow(bars, i, n) {
  let m = Infinity;
  for (let j = Math.max(0, i - n + 1); j <= i; j++) m = Math.min(m, ohlc(bars[j]).l);
  return m;
}

// ---- PositionGuard ----
function openPosition(P, o) {
  const px = +o.px, p = P.position;
  let stop = null, why = null;
  if (p.hardStop.enabled) { stop = px * (1 - p.hardStop.pct / 100); why = 'hard'; }
  if (p.structStop.enabled && o.structLow != null && isFinite(o.structLow)) {
    const lo = +o.structLow;
    let s = lo - p.structStop.bufTicks * tickSize(lo);
    if (s >= px) return { reject: 'struct_invalid' };
    const dist = (px - s) / px * 100;
    if (dist > p.structStop.maxPct) {
      if (p.structStop.onFar === 'skip') return { reject: 'struct_far', dist };
      s = px * (1 - p.structStop.maxPct / 100);
    }
    if (stop == null || s > stop) { stop = s; why = 'struct'; }
  }
  return { pos: { avg: px, frac: 1, idx: o.idx | 0, peak: px, stop, stopWhy: why,
                  tpDone: false, protectOn: false, trailOn: false, timeChecked: false, manualHold: false } };
}
// bar mode, conservative: stop lines first, then partial TP, then time stop; state updates last.
function onBar(P, pos, bar, idx, env) {
  env = env || {};
  if (env.hms != null && env.hms < P.timing.ignoreBeforeHms) return [];
  const b = ohlc(bar), p = P.position, fee = +env.feePct || 0, acts = [], hold = !!pos.manualHold;
  let line = null, why = null;
  if (!hold || p.manualHoldKeepsHardStop) { line = pos.stop; why = pos.stopWhy; }
  if (!hold) {
    if (pos.protectOn) {
      const l = pos.avg * (1 + (p.protect.levelPct + fee) / 100);
      if (line == null || l > line) { line = l; why = 'protect'; }
    }
    if (pos.trailOn) {
      const l = Math.max(pos.peak * (1 - p.trail.dropPct / 100), pos.avg * (1 + fee / 100));
      if (line == null || l > line) { line = l; why = 'trail'; }
    }
  }
  if (line != null) {
    if (b.o <= line) return [{ type: 'exit', why, px: b.o, frac: pos.frac, gap: true }];
    if (b.l <= line) return [{ type: 'exit', why, px: line, frac: pos.frac }];
  }
  if (hold) return acts;
  if (p.takeProfit.enabled && !pos.tpDone) {
    const tp = pos.avg * (1 + p.takeProfit.pct / 100);
    if (b.h >= tp) {
      const f = Math.min(pos.frac, p.takeProfit.ratio), px = b.o >= tp ? b.o : tp;
      pos.tpDone = true;
      pos.frac = Math.round((pos.frac - f) * 1e9) / 1e9;
      if (pos.frac <= 0) return [{ type: 'exit', why: 'tp', px, frac: f }];
      acts.push({ type: 'partial', why: 'tp', px, frac: f });
    }
  }
  const peak = Math.max(pos.peak, b.h);
  if (p.timeStop.enabled && !pos.timeChecked && idx - pos.idx >= p.timeStop.bars) {
    pos.timeChecked = true;
    if ((peak / pos.avg - 1) * 100 < p.timeStop.minPct) {
      acts.push({ type: 'exit', why: 'time', px: b.c, frac: pos.frac });
      return acts;
    }
  }
  pos.peak = peak;
  const pk = (peak / pos.avg - 1) * 100;
  if (p.protect.enabled && pk >= p.protect.atPct) pos.protectOn = true;
  if (p.trail.enabled && pk >= p.trail.afterPct) pos.trailOn = true;
  return acts;
}

// ---- AccountGuard (weights: fraction of account, returns in %) ----
function createAccount(P) {
  const A = P.account;
  const st = { day: null, realized: 0, open: new Map(), entries: 0, bySource: Object.create(null),
               sold: new Set(), consec: 0, pauseUntil: -1, halt: null, kill: false };
  const no = why => ({ ok: false, why });
  function roll(day) {
    if (day == null || day === st.day) return;
    st.day = day; st.realized = 0; st.entries = 0; st.bySource = Object.create(null);
    st.sold.clear(); st.consec = 0; st.pauseUntil = -1; st.halt = null; for (const v of st.open.values()) v.base = v.ret;
  }
  function equityPct() { let e = st.realized; for (const v of st.open.values()) e += v.w * (v.ret - v.base); return e; }
  function check() {
    const e = equityPct();
    if (!st.halt && A.dailyLoss.enabled && e <= -A.dailyLoss.pct) st.halt = 'daily_loss:' + A.dailyLoss.action;
    if (!st.halt && A.dailyProfitLock.enabled && e >= A.dailyProfitLock.pct) st.halt = 'profit_lock:' + A.dailyProfitLock.action;
    return st.halt;
  }
  return {
    st, equityPct,
    kill(on) { st.kill = !!on; },
    canEnter(q) {
      roll(q.day);
      if (st.kill) return no('kill');
      if (check()) return no(st.halt.split(':')[0]);
      if (A.consecLoss.enabled && (q.tsec || 0) < st.pauseUntil) return no('pause');
      if (st.open.has(q.code)) return no('dup');
      if (A.maxSlots.enabled && st.open.size >= A.maxSlots.n) return no('slots');
      const s = q.source || '_';
      if (A.maxEntriesPerSource.enabled && (st.bySource[s] || 0) >= A.maxEntriesPerSource.n) return no('per_source');
      if (A.maxDailyEntries.enabled && st.entries >= A.maxDailyEntries.n) return no('daily_entries');
      if (A.noReentrySameDay.enabled && st.sold.has(q.code)) return no('no_reentry');
      return { ok: true };
    },
    onEntry(q) {
      roll(q.day);
      st.open.set(q.code, { w: q.w != null ? q.w : 1, ret: 0, base: 0 });
      st.entries++;
      const s = q.source || '_'; st.bySource[s] = (st.bySource[s] || 0) + 1;
    },
    cancelEntry(q) {
      if (!st.open.delete(q.code)) return;
      st.entries = Math.max(0, st.entries - 1);
      const s = q.source || '_'; st.bySource[s] = Math.max(0, (st.bySource[s] || 0) - 1);
    },
    mark(code, retPct) {
      const v = st.open.get(code); if (v) v.ret = retPct;
      const h = check();
      return h && h.endsWith(':flatten') ? 'flatten' : null;
    },
    onPartial(code, wPart, retPct) {
      const v = st.open.get(code); if (!v) return;
      st.realized += wPart * (retPct - v.base); v.w = Math.max(0, v.w - wPart);
    },
    onExit(q) {
      const v = st.open.get(q.code); if (!v) return;
      st.realized += v.w * (q.retPct - v.base);
      st.open.delete(q.code); st.sold.add(q.code);
      const tr = q.tradeRetPct != null ? q.tradeRetPct : q.retPct;
      if (tr < 0) st.consec++; else st.consec = 0;
      if (A.consecLoss.enabled && st.consec >= A.consecLoss.n) {
        st.pauseUntil = (q.tsec || 0) + A.consecLoss.pauseMin * 60; st.consec = 0;
      }
    }
  };
}
function flattenDue(P, h) { const f = P.account.flatten; return !!(f.enabled && !f.allowOvernight && h >= +f.time); }

// ---- Sizer ----
function size(P, q) {
  const S = P.sizing, eq = +q.equity, cash = q.cash != null ? +q.cash : eq, cap = eq * S.maxWeightPct / 100;
  let amt;
  if (S.mode === 'riskBased' && q.stop && q.stop < q.px) amt = eq * S.riskPerTradePct / 100 / ((q.px - q.stop) / q.px);
  else if (S.mode === 'pctCash' || S.mode === 'riskBased') amt = cash * S.pctCash / 100;
  else amt = S.amount;
  amt = Math.min(amt, cap, cash);
  const qty = Math.max(0, Math.floor(amt / q.px));
  return { qty, amt: qty * q.px, w: eq > 0 ? qty * q.px / eq : 0 };
}
function pendingExpired(P, sentMs, nowMs) {
  const c = P.order.pendingCancel; return !!(c.enabled && nowMs - sentMs >= c.sec * 1000);
}

module.exports = { VERSION, DEF, load, merge, isPassive, enabledList, unknownKeys, validate,
  tickSize, hms, dayKey, secOfDay, structLow, openPosition, onBar, createAccount, flattenDue, size, pendingExpired };