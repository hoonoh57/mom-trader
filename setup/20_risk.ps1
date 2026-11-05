#requires -Version 5.1
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [switch]$NoProbe
)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "[성공] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[실패] $m" -ForegroundColor Red }
function Info($m) { Write-Host "[정보] $m" }
$enc = New-Object System.Text.UTF8Encoding($false)
function Put([string]$rel, [string]$text) {
  $p = Join-Path $Root $rel
  $d = Split-Path $p -Parent
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  $text = $text -replace "`r`n", "`n"
  [IO.File]::WriteAllText($p, $text, $enc)
  $b = [IO.File]::ReadAllBytes($p)
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { throw "BOM 발견: $rel" }
  if ([IO.File]::ReadAllText($p, $enc) -ne $text) { throw "재읽기 불일치: $rel" }
}

Write-Host '=== mom-trader 리스크 계층 (risk-1) ==='
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'node 없음'; exit 1 }

# ---------------- tools\sz-risk.cjs ----------------
Put 'tools\sz-risk.cjs' @'
'use strict';
// sz-risk.cjs - SafeZone risk layer. Rule: may only BLOCK entries or FORCE exits.
// Never creates entries, never delays strategy exits. No I/O.
const VERSION = 'risk-1';
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
    st.sold.clear(); st.consec = 0; st.pauseUntil = -1; st.halt = null;
  }
  function equityPct() { let e = st.realized; for (const v of st.open.values()) e += v.w * v.ret; return e; }
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
      st.open.set(q.code, { w: q.w != null ? q.w : 1, ret: 0 });
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
      st.realized += wPart * retPct; v.w = Math.max(0, v.w - wPart);
    },
    onExit(q) {
      const v = st.open.get(q.code); if (!v) return;
      st.realized += v.w * q.retPct;
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
'@

# ---------------- tools\sz-risk-selftest.cjs ----------------
Put 'tools\sz-risk-selftest.cjs' @'
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
'@

# ---------------- risk profiles ----------------
Put 'strategies\risk\RP000.json' @'
{ "id": "RP000", "name": "all off (S000 parity)" }
'@
Put 'strategies\risk\RP001.json' @'
{ "id": "RP001", "name": "struct stop only",
  "position": { "structStop": { "enabled": true, "lookback": 20, "bufTicks": 1, "maxPct": 3, "onFar": "skip" } } }
'@
Put 'strategies\risk\RP002.json' @'
{ "id": "RP002", "name": "RP001 + daily loss -2% block",
  "account":  { "dailyLoss": { "enabled": true, "pct": 2, "action": "block" } },
  "position": { "structStop": { "enabled": true, "lookback": 20, "bufTicks": 1, "maxPct": 3, "onFar": "skip" } } }
'@
Put 'strategies\risk\RP003.json' @'
{ "id": "RP003", "name": "RP002 + partial TP 50% + breakeven protect",
  "note": "takeProfit.pct must match S000 TargetPct",
  "account":  { "dailyLoss": { "enabled": true, "pct": 2, "action": "block" } },
  "position": { "structStop": { "enabled": true, "lookback": 20, "bufTicks": 1, "maxPct": 3, "onFar": "skip" },
                "takeProfit": { "enabled": true, "pct": 5, "ratio": 0.5 },
                "protect":    { "enabled": true, "atPct": 2, "levelPct": 0 } } }
'@
Put 'strategies\risk\RP004.json' @'
{ "id": "RP004", "name": "RP003 + no reentry + 1 per source + pending cancel 120s",
  "account":  { "dailyLoss": { "enabled": true, "pct": 2, "action": "block" },
                "noReentrySameDay": { "enabled": true },
                "maxEntriesPerSource": { "enabled": true, "n": 1 } },
  "position": { "structStop": { "enabled": true, "lookback": 20, "bufTicks": 1, "maxPct": 3, "onFar": "skip" },
                "takeProfit": { "enabled": true, "pct": 5, "ratio": 0.5 },
                "protect":    { "enabled": true, "atPct": 2, "levelPct": 0 } },
  "order":    { "pendingCancel": { "enabled": true, "sec": 120 } } }
'@
Put 'strategies\risk\RPK1.json' @'
{ "id": "RPK1", "name": "KATCH stoploss style (loss -3 / profit +5 full / protect)",
  "account":  { "maxSlots": { "enabled": true, "n": 3 }, "noReentrySameDay": { "enabled": true } },
  "position": { "hardStop": { "enabled": true, "pct": 3 },
                "takeProfit": { "enabled": true, "pct": 5, "ratio": 1 },
                "protect": { "enabled": true, "atPct": 3, "levelPct": 1 } },
  "sizing":   { "mode": "fixedAmount", "amount": 1000000 } }
'@
Put 'strategies\risk\RPK2.json' @'
{ "id": "RPK2", "name": "KATCH trailing style (after +3, drop 1.5)",
  "account":  { "maxSlots": { "enabled": true, "n": 3 }, "noReentrySameDay": { "enabled": true } },
  "position": { "hardStop": { "enabled": true, "pct": 3 },
                "trail": { "enabled": true, "afterPct": 3, "dropPct": 1.5 } },
  "sizing":   { "mode": "fixedAmount", "amount": 1000000 } }
'@

# ---------------- tools\sz-probe.cjs ----------------
Put 'tools\sz-probe.cjs' @'
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const root = process.argv[2];
const outDir = path.join(root, 'out', 'probe'); fs.mkdirSync(outDir, { recursive: true });
const L = [], add = s => L.push(s);
const targets = ['strategies/engines/v1.cjs', 'tools/sz-lab.cjs', 'tools/sz-engine.cjs', 'strategies/manifest.json'];
const p1 = /^\s*(async\s+)?function\s+\w+|^\s*(const|let|var)\s+\w+\s*=\s*(async\s*)?(function|\([^)]*\)\s*=>)|module\.exports|^\s*exports\./;
const p2 = /simulate|trades?\.push|\bwhy\b|StopPct|SafeNoLoss|ExitTime|EntryStart|TargetPct|fee|ctx\.|\bret\b|mfe/i;
for (const rel of targets) {
  const p = path.join(root, rel); add('=== ' + rel);
  if (!fs.existsSync(p)) { add('MISSING'); continue; }
  const buf = fs.readFileSync(p);
  add('bytes=' + buf.length + ' sha256=' + crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16));
  if (!rel.endsWith('.cjs')) { add(buf.toString('utf8').slice(0, 2000)); continue; }
  const lines = buf.toString('utf8').split(/\r?\n/); add('lines=' + lines.length);
  if (rel.endsWith('v1.cjs')) {
    try { const m = require(p); add('exports: ' + Object.keys(m).map(k => k + ':' + typeof m[k] + (typeof m[k] === 'function' ? '(' + m[k].length + ')' : '')).join(', ')); }
    catch (e) { add('require error: ' + e.message); }
  }
  let n = 0;
  lines.forEach((s, i) => { if (n < 180 && (p1.test(s) || p2.test(s))) { add(String(i + 1).padStart(5) + ': ' + s.slice(0, 170)); n++; } });
}
const out = path.join(outDir, 'v1_probe.txt');
fs.writeFileSync(out, L.join('\n'), 'utf8');
console.log('PROBE written: ' + out + ' lines=' + L.length);
'@
Ok '파일 11개 기록 (tools 3, risk 프로필 7, probe 1)'

# ---------------- verify ----------------
$ErrorActionPreference = 'Continue'
$out = & node (Join-Path $Root 'tools\sz-risk-selftest.cjs') (Join-Path $Root 'strategies\risk') 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$out | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0) { Fail "리스크 자가검증 실패 (exit $code) - 위 FAIL 줄을 그대로 붙여 주세요"; exit 1 }
Ok '리스크 자가검증 통과'

if (-not $NoProbe) {
  $ErrorActionPreference = 'Continue'
  $pr = & node (Join-Path $Root 'tools\sz-probe.cjs') $Root 2>&1
  $pc = $LASTEXITCODE
  $ErrorActionPreference = 'Stop'
  $pr | ForEach-Object { Write-Host "  $_" }
  if ($pc -ne 0) { Fail "v1 조사 실패 (exit $pc)"; exit 1 }
  Ok "v1 조사 완료: $Root\out\probe\v1_probe.txt"
}
Ok '완료 - 다음: v1.cjs, sz-lab.cjs 두 파일을 대화창에 첨부'
