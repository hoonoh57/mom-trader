#requires -Version 5.1
# 22b_guard_lab.ps1 - PatternGuard lab runner (indep only). ASCII only. Engines/lab3/guard untouched.
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [string]$Strategies = 'S000,C013',
  [string]$Risk = 'RP000,RP001,RP005',
  [string]$Guards = ''
)
$ErrorActionPreference = 'Stop'
function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }
$utf8 = New-Object System.Text.UTF8Encoding($false)
Write-Host '=== mom-trader PatternGuard lab (22b) ==='

$js = @'
'use strict';
// sz-lab-guard.cjs - PatternGuard lab, indep mode only. Read-only use of hash-checked v1/v3/risk1 + guard-1.0.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const ROOT = process.argv[2];
const A = k => { const i = process.argv.indexOf('--' + k); return i > 2 && i + 1 < process.argv.length ? process.argv[i + 1] : ''; };
function die(m) { console.log('FAIL: ' + m); process.exit(1); }
if (!ROOT) die('usage: node sz-lab-guard.cjs <root> [--strategies S000,C013] [--risk RP000,RP001] [--guards GP000,GP001]');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const readJson = f => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const list = s => String(s == null ? '' : s).split(',').map(x => x.trim()).filter(Boolean);
const SD = path.join(ROOT, 'strategies'), ENG = path.join(SD, 'engines'), FRZ = path.join(SD, 'frozen');
const CAND = path.join(SD, 'candidates'), SURV = path.join(SD, 'survivors'), RISK = path.join(SD, 'risk'), GDIR = path.join(SD, 'guard');
const MAN = path.join(SD, 'manifest.json'), OUT = path.join(ROOT, 'out', 'guard');
const tickDir = path.join(ROOT, 'data', 'ticks'), dailyDir = path.join(ROOT, 'data', 'daily');
fs.mkdirSync(OUT, { recursive: true });
if (!fs.existsSync(MAN)) die('manifest missing');
const man = readJson(MAN);
function loadEng(name) {
  const e = man.engines && man.engines[name];
  if (!e) die('engine not registered: ' + name);
  const f = path.join(ENG, e.file);
  if (!fs.existsSync(f)) die('engine file missing: ' + f);
  if (sha(fs.readFileSync(f)) !== e.sha256) die('engine ' + name + ' hash mismatch');
  return require(f);
}
const V1 = loadEng('v1'), R = loadEng('risk1'), E3 = loadEng('v3')(V1, R);
const GMF = path.join(GDIR, 'manifest.json'), GF = path.join(ROOT, 'tools', 'sz-guard.cjs');
if (!fs.existsSync(GMF) || !fs.existsSync(GF)) die('guard not registered: run 22_guard.ps1');
if (sha(fs.readFileSync(GF)) !== readJson(GMF).sha256) die('guard hash mismatch (sz-guard.cjs modified)');
const G = require(GF);

// ---- copied from sz-lab3.cjs (lab3 executes on require) ----
const V1REJ = ['time', 'count', 'gap', 'lim', 'ema', 'disp', 'tick'];
const TF = ['inI', 'inPx', 'outI', 'outPx', 'why', 'gross', 'ret', 'mfe', 'mae', 'bars', 'reached', 'held'];
function same(a, b) {
  if (a.trades.length !== b.trades.length) return 'trades ' + a.trades.length + ' vs ' + b.trades.length;
  for (let k = 0; k < a.trades.length; k++) for (const f of TF)
    if (a.trades[k][f] !== b.trades[k][f]) return 'trade#' + (k + 1) + ' ' + f + ' ' + a.trades[k][f] + ' vs ' + b.trades[k][f];
  for (const k of V1REJ) if (a.rej[k] !== b.rej[k]) return 'rej.' + k + ' ' + a.rej[k] + ' vs ' + b.rej[k];
  if (a.arms !== b.arms || a.sigs !== b.sigs || a.held !== b.held) return 'arms/sigs/held ' + [a.arms, a.sigs, a.held] + ' vs ' + [b.arms, b.sigs, b.held];
  return null;
}
function stats(tr) {
  let n = tr.length, w = 0, sum = 0, gw = 0, gl = 0, eq = 0, pk = 0, mdd = 0, mfe = 0;
  for (const t of tr) {
    if (t.ret > 0) { w++; gw += t.ret; } else gl -= t.ret;
    sum += t.ret; mfe += t.mfe; eq += t.ret; if (eq > pk) pk = eq; if (pk - eq > mdd) mdd = pk - eq;
  }
  return { n, w, sum, avg: n ? sum / n : 0, pf: gl > 0 ? gw / gl : (gw > 0 ? 99 : 0), mdd, avgMfe: n ? mfe / n : 0 };
}
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
function loadTicksText(text) {
  const rows = parseCsv(text);
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
  if (bars.length < 10) throw new Error('too few bars: ' + bars.length);
  if (bars[0].t > bars[bars.length - 1].t) bars.reverse();
  for (let i = 1; i < bars.length; i++) if (bars[i].t < bars[i - 1].t) { bars.sort((a, b) => a.t - b.t); break; }
  return bars;
}
// ---- daily: same file as lab3, but also returns prev close ----
function loadDaily2(code, date, warn) {
  const f = path.join(dailyDir, code + '.csv');
  if (!fs.existsSync(f)) { warn.push('no daily csv'); return null; }
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), h = rows[0].map(x => x.trim().toLowerCase());
  const iD = h.indexOf('date'), iC = h.indexOf('close'), iP = h.indexOf('chg_pct');
  if (iD < 0 || iC < 0) { warn.push('daily columns missing'); return null; }
  const lst = rows.slice(1).map(r => ({ d: String(r[iD]).replace(/\D/g, '').slice(0, 8), c: Math.abs(num(r[iC])), p: iP >= 0 ? num(r[iP]) : NaN }))
    .filter(x => x.d.length === 8 && x.c > 0).sort((a, b) => a.d < b.d ? -1 : a.d > b.d ? 1 : 0);
  let k = -1; for (let j = 0; j < lst.length; j++) if (lst[j].d < date) k = j;
  if (k < 0) { warn.push('no prev daily row'); return null; }
  let chg = lst[k].p;
  if (!isFinite(chg) && k > 0) chg = (lst[k].c / lst[k - 1].c - 1) * 100;
  return { d: lst[k].d, c: lst[k].c, chg };
}
function dailyHash(code) { const f = path.join(dailyDir, code + '.csv'); return fs.existsSync(f) ? sha(fs.readFileSync(f)).slice(0, 12) : 'none'; }

// ---- strategies (same rules as lab3) ----
const lib = {};
for (const f of fs.readdirSync(FRZ).filter(x => x.endsWith('.json'))) {
  const s = readJson(path.join(FRZ, f));
  if (!man.frozen || man.frozen[s.id] !== sha(JSON.stringify(s.params))) die('frozen strategy modified or unknown: ' + s.id);
  lib[s.id] = Object.assign({ kind: 'frozen' }, s);
}
const B = lib[man.baseline]; if (!B) die('baseline missing: ' + man.baseline);
if (fs.existsSync(SURV)) for (const f of fs.readdirSync(SURV).filter(x => x.endsWith('.json'))) {
  const s = readJson(path.join(SURV, f)); if (!lib[s.id]) lib[s.id] = Object.assign({ kind: 'survivor' }, s);
}
function resolve(id) {
  if (lib[id]) return lib[id];
  const f = path.join(CAND, id + '.json'); if (!fs.existsSync(f)) die('strategy not found: ' + id);
  const c = readJson(f), b = lib[c.base || B.id]; if (!b) die('base not found: ' + c.base);
  const p = Object.assign({}, b.params);
  for (const k of Object.keys(c.overrides || {})) { if (!(k in p)) die('unknown param ' + k + ' in ' + id); p[k] = c.overrides[k]; }
  return { id: c.id, name: c.name, params: p, kind: 'candidate', engine: c.engine || 'v1' };
}
let sids = list(A('strategies')); if (!sids.length) sids = [B.id];
sids = [B.id].concat(sids.filter(x => x !== B.id));
const strats = sids.map(resolve);
for (const s of strats) if ((s.engine || 'v1') !== 'v1') die(s.id + ': engine ' + s.engine + ' not supported');

// ---- risk profiles: position.* only (account items need portfolio runner = v3.1) ----
const notes = [], addNote = m => { if (notes.indexOf(m) < 0) notes.push(m); };
let rwant = list(A('risk')); if (!rwant.length) rwant = ['RP000'];
if (rwant.indexOf('RP000') < 0) rwant.unshift('RP000');
const profs = [];
for (const id of rwant) {
  const f = path.join(RISK, id + '.json'); if (!fs.existsSync(f)) die('risk profile missing: ' + id);
  const raw = readJson(f), unk = R.unknownKeys(raw); if (unk.length) die(id + ': unknown keys ' + unk.join(','));
  const P = R.load(raw), v = R.validate(P); if (v.length) die(id + ': invalid ' + v.join(','));
  const on = R.enabledList(P), bad = on.filter(x => x.indexOf('position.') !== 0);
  if (bad.length) { addNote('skip ' + id + ' (non-position items: ' + bad.join(' ') + ') -> needs v3.1 portfolio hook'); continue; }
  profs.push({ id, P, on });
}
if (!profs.length || profs[0].id !== 'RP000' || !R.isPassive(profs[0].P)) die('RP000 missing or not passive');

// ---- guard profiles ----
let gwant = list(A('guards'));
const guards = [];
for (const f of fs.readdirSync(GDIR).filter(x => /^GP\d+\.json$/.test(x)).sort()) {
  const id = f.replace('.json', '');
  if (gwant.length && gwant.indexOf(id) < 0 && id !== 'GP000') continue;
  guards.push({ id, P: G.load(readJson(path.join(GDIR, f))) });
}
if (!guards.length || guards[0].id !== 'GP000' || !G.isPassive(guards[0].P)) die('GP000 missing or not passive');

// ---- dataset ----
const files = fs.readdirSync(tickDir).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(B.params.Match)).sort();
if (!files.length) die('no tick csv matching ' + B.params.Match);
const items0 = [];
for (const f of files) {
  try {
    const buf = fs.readFileSync(path.join(tickDir, f)), bars = loadTicksText(buf.toString('utf8'));
    const code = f.split('_')[0], dm = f.match(/(\d{8})\.csv$/i), m = f.match(/_(\d+)t_/);
    const date = dm ? dm[1] : bars[bars.length - 1].d, start = bars.findIndex(b => b.d === date);
    if (start < 0) throw new Error('target date not in file');
    const warn = [], dly = loadDaily2(code, date, warn);
    for (const w of warn) addNote(f + ': ' + w);
    items0.push({ f, code, date, bars, start, scope: m ? Number(m[1]) : 120, dly, fp: f + ':' + sha(buf).slice(0, 16) + ':' + dailyHash(code) });
  } catch (e) { addNote('[excluded] ' + f + ': ' + e.message); }
}
if (!items0.length) die('no usable tick files');
const dsId = sha(items0.map(x => x.fp).join('|')).slice(0, 10);
function mkItems(params) {
  return items0.map(it => {
    const P = V1.prep(Object.assign({}, params, { Date: '', TickScope: it.scope }));
    const dayComplete = it.bars[it.start].hms <= P._sessMax;
    let limKind = null;
    if (it.dly && isFinite(it.dly.chg)) { if (it.dly.chg >= P.LimPct) limKind = 'limit'; else if (it.dly.chg >= P.SurgePct) limKind = 'surge'; }
    return { code: it.code, source: '_', bars: it.bars, ind: V1.compute(it.bars, P), P,
      ctx: { start: it.start, date: it.date, dayComplete, limKind, prevClose: it.dly ? it.dly.c : null, prevChg: it.dly ? it.dly.chg : null } };
  });
}
const fx = x => (x > 0 ? '+' : '') + Number(x).toFixed(2);
const pad = (s, n) => String(s).padStart(n);
const hmsS = h => { const s = String(h).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };

// ---- run ----
const rep = [], runRows = [], trRows = [];
let parityN = 0;
for (const s of strats) {
  const items = mkItems(s.params);
  const gates = {};
  for (const g of guards) {
    gates[g.id] = items.map(x => G.computeGate(x.bars, x.ind, x.ctx, g.P));
    gates[g.id].forEach((r, k) => { for (const m of r.diag.missing) addNote(g.id + ' ' + items0[k].f + ': missing ' + m); });
  }
  for (const rp of profs) {
    const hook = (gid, k) => ({ canEnter: G.makeHook(gates[gid][k]) });
    const base = items.map((x, k) => E3.simulate(x.bars, x.ind, x.P, x.ctx, rp.P, hook('GP000', k)));
    items.forEach((x, k) => {
      if (rp.id === 'RP000') { const m = same(V1.simulate(x.bars, x.ind, x.P, x.ctx), base[k]); if (m) die('PARITY v1 vs guard GP000 ' + s.id + ' ' + items0[k].f + ': ' + m); }
      const m2 = same(E3.runPortfolio([x], rp.P)[0], base[k]); if (m2) die('PARITY lab3-indep vs simulate ' + s.id + '/' + rp.id + ' ' + items0[k].f + ': ' + m2);
      parityN++;
    });
    const bst = stats([].concat(...base.map(r => r.trades)));
    rep.push('', '== ' + s.id + ' x ' + rp.id + ' (risk on=[' + rp.on.join(' ') + ']) ==');
    rep.push(' guard   trades     sum    PF   MDD lossDays worstDay worstTr blocked removed(n/sum) added(n/sum)   delta');
    for (const g of guards) {
      const res = g.id === 'GP000' ? base : items.map((x, k) => E3.simulate(x.bars, x.ind, x.P, x.ctx, rp.P, hook(g.id, k)));
      const per = res.map((r, k) => ({ code: items0[k].code, date: items0[k].date, trades: r.trades, rej: r.rej, sum: r.trades.reduce((a, t) => a + t.ret, 0) }));
      const st = stats([].concat(...per.map(p => p.trades)));
      let lossDays = 0, worstDay = 0, worstTr = 0, blk = 0, rmN = 0, rmS = 0, adN = 0, adS = 0;
      const why = {}, diffs = [];
      per.forEach((p, k) => {
        if (p.sum < 0) lossDays++;
        worstDay = Math.min(worstDay, p.sum);
        for (const t of p.trades) worstTr = Math.min(worstTr, t.ret);
        for (const key of Object.keys(p.rej)) if (/^r_G0/.test(key)) { blk += p.rej[key]; why[key] = (why[key] || 0) + p.rej[key]; }
        const bt = base[k].trades, gi = new Set(p.trades.map(t => t.inI)), bi = new Set(bt.map(t => t.inI));
        for (const t of bt) if (!gi.has(t.inI)) { rmN++; rmS += t.ret; }
        for (const t of p.trades) if (!bi.has(t.inI)) { adN++; adS += t.ret; }
        const bs = bt.reduce((a, t) => a + t.ret, 0);
        if (Math.abs(p.sum - bs) > 1e-9) diffs.push(p.code + ' ' + fx(bs) + '->' + fx(p.sum));
        p.trades.forEach((t, j) => {
          const b0 = items[k].bars;
          trRows.push([s.id + '__' + rp.id + '__' + g.id, p.code, p.date, j + 1, hmsS(b0[t.inI].hms), t.inPx, hmsS(b0[t.outI].hms), t.outPx, t.why, t.ret.toFixed(3), t.mfe.toFixed(3)].join(','));
        });
      });
      const delta = st.sum - bst.sum;
      rep.push(' ' + g.id.padEnd(6) + pad(st.n, 7) + pad(fx(st.sum), 8) + pad(st.pf.toFixed(2), 6) + pad(st.mdd.toFixed(2), 6) + pad(lossDays, 9) +
        pad(fx(worstDay), 9) + pad(fx(worstTr), 8) + pad(blk, 8) + pad(rmN + '/' + fx(rmS), 15) + pad(adN + '/' + fx(adS), 13) + pad(fx(delta), 8));
      if (g.id !== 'GP000') {
        const w = Object.keys(why).sort().map(k => k.replace('r_', '') + ':' + why[k]).join(' ');
        if (w) rep.push('        block reasons: ' + w);
        if (diffs.length) rep.push('        by stock: ' + diffs.join(' | '));
      }
      runRows.push([s.id, rp.id, g.id, st.n, st.sum.toFixed(3), st.pf.toFixed(3), st.mdd.toFixed(3), lossDays, worstDay.toFixed(3), worstTr.toFixed(3), blk, rmN, rmS.toFixed(3), adN, adS.toFixed(3), delta.toFixed(3)].join(','));
    }
  }
}

// ---- event ledger: all patterns on, default thresholds, baseline strategy indicators ----
const LG = G.load({ id: 'LEDGER', patterns: { G01: { enabled: true }, G02: { enabled: true }, G03: { enabled: true }, G04: { enabled: true }, G05: { enabled: true }, G06: { enabled: true } } });
const itemsB = mkItems(B.params), evRows = [], agg = {};
let baseN = 0, baseCrash = 0, baseMae = 0, baseMfe = 0;
itemsB.forEach((x, k) => {
  const g = G.computeGate(x.bars, x.ind, x.ctx, LG);
  for (const e of G.forward(x.bars, g.events, LG.ledger)) {
    const safe = x.ind.safe[e.i] ? 1 : 0, mom = x.ind.mom[e.i];
    evRows.push([e.pid, items0[k].code, e.d, hmsS(e.hms), e.px, safe, mom == null ? '' : mom.toFixed(2), e.state,
      e.mfe10.toFixed(3), e.mae10.toFixed(3), e.mfe30.toFixed(3), e.mae30.toFixed(3), e.mfe60.toFixed(3), e.mae60.toFixed(3), e.crash ? 1 : 0].join(','));
    const a = agg[e.pid] || (agg[e.pid] = { n: 0, safe: 0, crash: 0, mae: 0, mfe: 0, codes: new Set() });
    a.n++; a.safe += safe; a.crash += e.crash ? 1 : 0; a.mae += e.mae30; a.mfe += e.mfe30; a.codes.add(items0[k].code);
  }
  const pe = [];
  for (let i = x.ctx.start; i < x.bars.length; i++) { const b = x.bars[i]; if (b.d === x.ctx.date && b.hms >= 90000 && b.hms <= 150000) pe.push({ pid: 'BASE', i, d: b.d, hms: b.hms, px: b.c }); }
  for (const e of G.forward(x.bars, pe, LG.ledger)) { baseN++; if (e.crash) baseCrash++; baseMae += e.mae30; baseMfe += e.mfe30; }
});
const baseRate = baseN ? baseCrash / baseN : 0;
rep.push('', '== Event ledger (all patterns, default thresholds, ' + B.id + ' indicators) ==');
rep.push(' base (every bar 09:00-15:00): bars=' + baseN + ' crash30(<=-' + LG.ledger.crashPct + '%)=' + (baseRate * 100).toFixed(1) + '% avgMFE30=' + fx(baseN ? baseMfe / baseN : 0) + ' avgMAE30=' + fx(baseN ? baseMae / baseN : 0));
rep.push(' pid   events stocks inSafe crash30   lift avgMFE30 avgMAE30');
for (const p of G.PIDS) {
  const a = agg[p];
  if (!a) { rep.push(' ' + p + '      0'); continue; }
  const cr = a.crash / a.n;
  rep.push(' ' + p + pad(a.n, 9) + pad(a.codes.size, 7) + pad(a.safe, 7) + pad((cr * 100).toFixed(1) + '%', 8) + pad(baseRate > 0 ? (cr / baseRate).toFixed(2) : '-', 7) + pad(fx(a.mfe / a.n), 9) + pad(fx(a.mae / a.n), 9));
}

const head = ['PatternGuard lab ' + G.VERSION + ' | data ' + dsId + ' | stock-days ' + items0.length + ' | parity ' + parityN + ' ok',
  'strategies=' + strats.map(s => s.id).join(',') + ' risk=' + profs.map(p => p.id).join(',') + ' guards=' + guards.map(g => g.id).join(','),
  'delta = sum(guard) - sum(GP000) under same strategy x risk. removed = GP000 trades the guard blocked, added = new entries after block.'];
for (const n of notes) head.push('[note] ' + n);
fs.writeFileSync(path.join(OUT, 'report.txt'), head.concat(rep).join('\n') + '\n', 'utf8');
fs.writeFileSync(path.join(OUT, 'runs.csv'), 'strategy,risk,guard,trades,sum,pf,mdd,loss_days,worst_day,worst_trade,blocked,removed_n,removed_sum,added_n,added_sum,delta\n' + runRows.join('\n') + '\n', 'utf8');
fs.writeFileSync(path.join(OUT, 'trades.csv'), 'key,code,date,no,in,in_px,out,out_px,why,ret,mfe\n' + trRows.join('\n') + '\n', 'utf8');
fs.writeFileSync(path.join(OUT, 'events.csv'), 'pid,code,date,time,px,in_safe,mom,state,mfe10,mae10,mfe30,mae30,mfe60,mae60,crash30\n' + evRows.join('\n') + '\n', 'utf8');
console.log('DONE runs=' + runRows.length + ' parity=' + parityN + ' events=' + evRows.length + ' stockdays=' + items0.length + ' data=' + dsId);
'@

$p = Join-Path $Root 'tools\sz-lab-guard.cjs'
try {
  if (Test-Path $p) { Copy-Item $p "$p.bak22b" -Force }
  [IO.File]::WriteAllText($p, $js, $utf8)
  if ([IO.File]::ReadAllText($p, $utf8) -ne $js) { throw 'write verify failed' }
  Ok 'tools\sz-lab-guard.cjs written'
} catch { Fail $_.Exception.Message; exit 1 }

$ErrorActionPreference = 'Continue'
& node --check $p 2>&1 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Fail 'syntax error: sz-lab-guard.cjs'; exit 1 }
Ok 'syntax check'

$a = @($p, $Root)
if ($Strategies) { $a += @('--strategies', $Strategies) }
if ($Risk) { $a += @('--risk', $Risk) }
if ($Guards) { $a += @('--guards', $Guards) }
& node @a 2>&1 | ForEach-Object { "  $_" }
if ($LASTEXITCODE -ne 0) { Fail 'lab failed - paste the FAIL line'; exit 1 }

$out = Join-Path $Root 'out\guard'
Get-Content (Join-Path $out 'report.txt') -Encoding UTF8
Ok "results: $out\report.txt , runs.csv , trades.csv , events.csv"
