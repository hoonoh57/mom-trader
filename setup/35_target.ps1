param([string]$Strategies = 'S000,C013', [int]$MinWarm = 400, [string]$Targets = '0.5,0.75,1,1.25,1.5,2,3', [string]$Stops = '3,2,1.5,1', [string]$Csv = '')
$ErrorActionPreference = 'Continue'
$Root = 'E:\parent\projects\rea\projects\mom-trader'
$Out = Join-Path $Root 'out\FOR_OPUS.txt'
$Js = Join-Path $Root 'tools\ui\s4_target.cjs'
$U8 = New-Object System.Text.UTF8Encoding($false)
function Fail([string]$m, [string]$d) {
  $t = "#MT-REPORT v=report-1.0 step=S4.target ver=ps-wrapper verdict=FAIL ts=$((Get-Date).ToString('s'))`n#FAIL $m`n$d`n"
  [System.IO.File]::WriteAllText($Out, $t, $U8); Write-Host "FAIL S4.target -> $Out"; exit 1
}
$code = @'
'use strict';
// s4_target.cjs (target-1.0) - S4-2 first-stage minimum target. Read-only on engines and data.
// Engine facts (v1.cjs 141-185): entry = signal bar close*(1+SlipPct); exit checks start at i > idx;
//   per bar: stop (l<=stopPx, fill min(o,stopPx)) -> time (hms>=_exitT, fill c) -> rule on close.
//   MaxTrades counts completed trades, so MaxTrades=1 == first trade only.
// Target overlay: resting limit sell at ceilTick(entry*(1+T/100)) on bars inI+1..outI.
//   On the bar where the engine stopped or time-exited, that exit wins (conservative).
//   fill 'through': high >= target + 1 tick; 'touch': high >= target. Fill = target price.
// Exact for rules first/untilWin/untilTgt (trades before the stop point are unchanged). Re-entry after target exit is NOT simulated.
// StopPct grid = engine parameter override (engine-native).
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const VER = 'target-1.0', STEP = 'S4.target';
const ROOT = path.resolve(process.argv[2] || '.');
const A = k => { const i = process.argv.indexOf('--' + k); return i > 2 && i + 1 < process.argv.length ? process.argv[i + 1] : ''; };
const T0 = Date.now(), D0 = new Date();
const p2 = n => String(n).padStart(2, '0');
const LSTAMP = D0.getFullYear() + p2(D0.getMonth() + 1) + p2(D0.getDate()) + '-' + p2(D0.getHours()) + p2(D0.getMinutes()) + p2(D0.getSeconds());
const OUTF = path.join(ROOT, 'out', 'FOR_OPUS.txt');
const RDIR = path.join(ROOT, 'out', 'reports', STEP + '_' + LSTAMP);
const chk = [], sums = [], datas = [];
let engVer = '-';
const ok = (n, c, d) => { chk.push({ n, c: !!c, d: d == null ? '' : String(d) }); return !!c; };
const data = (name, lines) => datas.push({ name, lines });
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const readJson = f => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const list = s => String(s == null ? '' : s).split(',').map(x => x.trim()).filter(Boolean);
const fx = x => (x > 0 ? '+' : '') + Number(x).toFixed(2);
const pad = (s, n) => String(s).padStart(n);

function report(verdict, err) {
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  const L = [], pass = chk.filter(c => c.c).length;
  L.push('#MT-REPORT v=report-1.0 step=' + STEP + ' ver=' + VER + ' verdict=' + verdict + ' ts=' + new Date().toISOString() + ' dur=' + ((Date.now() - T0) / 1000).toFixed(1) + 's');
  L.push('#DIR ' + RDIR);
  L.push('#ENV node=' + process.version + ' os=' + process.platform + '-' + process.arch + ' engines=' + engVer);
  L.push('#CHK ' + pass + '/' + chk.length + ' ' + (pass === chk.length && !err ? 'PASS' : 'FAIL'));
  for (const c of chk) if (!c.c) L.push('#FAIL ' + c.n + ' :: ' + c.d);
  if (err) {
    L.push('#ERR ' + String((err && err.message) || err));
    for (const s of String((err && err.stack) || '').split('\n').slice(1, 7)) L.push('#AT ' + s.trim());
  }
  for (const s of sums) L.push('#SUM ' + s);
  for (const d of datas) { L.push('#DATA ' + d.name + ' lines=' + d.lines.length); for (const x of d.lines) L.push(x); L.push('#END'); }
  let txt = L.join('\n') + '\n';
  if (Buffer.byteLength(txt) > 200 * 1024) txt = txt.slice(0, 200 * 1024) + '\n#TRUNC 200KB\n';
  fs.mkdirSync(path.dirname(OUTF), { recursive: true });
  fs.writeFileSync(OUTF, txt);
  fs.writeFileSync(path.join(RDIR, 'FOR_OPUS.txt'), txt);
}

// ---- copied from s4_period.cjs (loaders copied from sz-lab-guard11.cjs) ----
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
function loadDaily2(dailyDir, code, date, warn) {
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
const TF = ['inPx', 'outPx', 'why', 'gross', 'ret', 'mfe', 'mae', 'bars', 'reached', 'held'];
const REJ = ['time', 'count', 'gap', 'lim', 'ema', 'disp', 'tick'];
function sameTr(a, b, off) {
  if (a.trades.length !== b.trades.length) return 'trades ' + a.trades.length + ' vs ' + b.trades.length;
  for (let k = 0; k < a.trades.length; k++) {
    const x = a.trades[k], y = b.trades[k];
    if (x.inI !== y.inI + off) return 'trade#' + (k + 1) + ' inI ' + x.inI + ' vs ' + (y.inI + off);
    if (x.outI !== y.outI + off) return 'trade#' + (k + 1) + ' outI ' + x.outI + ' vs ' + (y.outI + off);
    for (const f of TF) if (x[f] !== y[f]) return 'trade#' + (k + 1) + ' ' + f + ' ' + x[f] + ' vs ' + y[f];
  }
  return null;
}
function sameCnt(a, b) {
  for (const k of REJ) if (a.rej[k] !== b.rej[k]) return 'rej.' + k + ' ' + a.rej[k] + ' vs ' + b.rej[k];
  if (a.arms !== b.arms || a.sigs !== b.sigs || a.held !== b.held) return 'arms/sigs/held ' + [a.arms, a.sigs, a.held] + ' vs ' + [b.arms, b.sigs, b.held];
  return null;
}
const DCACHE = new Map();
function dayClose(dailyDir, code, date) {
  let m = DCACHE.get(code);
  if (!m) {
    m = new Map(); const f = path.join(dailyDir, code + '.csv');
    if (fs.existsSync(f)) {
      const rows = parseCsv(fs.readFileSync(f, 'utf8')), h = rows[0].map(x => x.trim().toLowerCase()), iD = h.indexOf('date'), iC = h.indexOf('close');
      if (iD >= 0 && iC >= 0) for (const r of rows.slice(1)) { const d = String(r[iD]).replace(/\D/g, '').slice(0, 8), c = Math.abs(num(r[iC])); if (d.length === 8 && c > 0) m.set(d, c); }
    }
    DCACHE.set(code, m);
  }
  return m.get(date) || null;
}
function findCapCsv() {
  const a = A('csv'); if (a) return path.resolve(a);
  const cand = [], walk = (d, depth) => {
    let ents; try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch (e) { return; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { if (depth > 0 && !/^(ticks|raw|daily|node_modules|\.git)$/i.test(e.name)) walk(p, depth - 1); }
      else if (/\.csv$/i.test(e.name) && !e.name.includes('_AL_')) cand.push(p);
    }
  };
  walk(path.join(ROOT, 'data'), 2); walk(ROOT, 0);
  for (const p of cand) {
    try {
      const fd = fs.openSync(p, 'r'), b = Buffer.alloc(2048), n = fs.readSync(fd, b, 0, 2048, 0); fs.closeSync(fd);
      const h = b.slice(0, n).toString('utf8').replace(/^\uFEFF/, '').split(/\r?\n/)[0].split(',').map(x => x.trim());
      if (h.length >= 16 && h[8] === '1_mfe' && h[14] === '60_mfe') return p;
    } catch (e) { }
  }
  return '';
}
const toT = (d, hms) => Date.UTC(+d.slice(0, 4), +d.slice(4, 6) - 1, +d.slice(6, 8), Math.floor(hms / 10000), Math.floor(hms / 100) % 100, hms % 100) / 1000;
function tickMfe(it, cp) {
  const capT = toT(it.date, cp.hms); let h60 = 0, hD = 0;
  for (let j = it.start; j < it.bars.length; j++) {
    const b = it.bars[j]; if (b.d !== it.date || b.t < capT || b.hms > 153000) continue;
    if (b.h > hD) hD = b.h; if (b.t <= capT + 3600 && b.h > h60) h60 = b.h;
  }
  return { m60: h60 > 0 ? (h60 / cp.px - 1) * 100 : NaN, mD: hD > 0 ? (hD / cp.px - 1) * 100 : NaN };
}
// ---- end copy ----

// fixed: csv percent cells look like "+3.24%" and "+0.87% @ 10:05"
const pct = s => num(String(s == null ? '' : s).split('@')[0].replace(/%/g, ''));
function loadCap(f) {
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), m = new Map(), stat = {}; let bad = 0;
  for (const r of rows.slice(1)) {
    const sv = String(r[7] || '').trim(); stat[sv] = (stat[sv] || 0) + 1;
    const d = String(r[2] || '').replace(/\D/g, '').slice(0, 8);
    let c = String(r[3] || '').trim().toUpperCase(); if (c.length === 7 && c[0] === 'A') c = c.slice(1);
    let t = String(r[1] || '').replace(/\D/g, ''); t = t.length <= 4 ? t.padStart(4, '0') + '00' : t.slice(-6).padStart(6, '0');
    const hms = Number(t), px = Math.abs(num(r[5]));
    if (d.length !== 8 || !c || !(px > 0) || !(hms >= 80000 && hms <= 200000)) { bad++; continue; }
    const k = c + '|' + d, o = m.get(k);
    const v = { hms, px, m60: pct(r[14]), r60: pct(r[15]), r60t: (String(r[15] || '').split('@')[1] || '').trim() };
    if (!o || hms < o.hms) m.set(k, v);
  }
  return { m, rows: rows.length - 1, bad, stat };
}

function main() {
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  const REF = Number(A('ref') || 800), MINW = Number(A('minWarm') || 400);
  const TG = list(A('targets') || '0.5,0.75,1,1.25,1.5,2,3').map(Number).filter(x => x > 0);
  const STOPS = list(A('stops') || '3,2,1.5,1').map(Number).filter(x => x > 0);
  const XP = {};
  for (const q of list(A('expect') || 'S000:-295.86:-257.52:87.90:-6.92,C013:-318.87:-276.12:58.10:-59.37').map(s => s.split(':'))) XP[q[0]] = { all: q[1], adj: q[2], first: q[3], uw: q[4] };
  const E = require(path.join(ROOT, 'tools', 'ui', 'engines.cjs'));
  engVer = E.VERSION;
  const vr = E.verify(ROOT);
  if (!ok('engine hash gate (' + E.VERSION + ')', vr && vr.ok, 'missing=' + JSON.stringify(vr && vr.missing))) return 'FAIL';
  const LD = E.load(ROOT), V1 = LD.V1, RK = LD.R;
  if (!ok('V1 api prep/compute/simulate', V1 && ['prep', 'compute', 'simulate'].every(k => typeof V1[k] === 'function'), Object.keys(V1 || {}).join(','))) return 'FAIL';
  const TS = RK && typeof RK.tickSize === 'function' ? p => RK.tickSize(p) : null;
  const TSMP = [1500, 3000, 15000, 30000, 150000, 300000];
  if (!ok('risk1 tickSize()', TS && TSMP.every(p => TS(p) > 0), TS ? TSMP.map(p => p + '=' + TS(p)).join(' ') : 'R.tickSize missing')) return 'FAIL';
  sums.push('tickSize sample ' + TSMP.map(p => p + '=' + TS(p)).join(' '));

  const SD = path.join(ROOT, 'strategies'), man = readJson(path.join(SD, 'manifest.json')), lib = {};
  for (const f of fs.readdirSync(path.join(SD, 'frozen')).filter(x => x.endsWith('.json'))) {
    const s = readJson(path.join(SD, 'frozen', f));
    if (!man.frozen || man.frozen[s.id] !== sha(JSON.stringify(s.params))) throw new Error('frozen strategy modified or unknown: ' + s.id);
    lib[s.id] = s;
  }
  const B = lib[man.baseline]; if (!B) throw new Error('baseline missing: ' + man.baseline);
  const SURV = path.join(SD, 'survivors');
  if (fs.existsSync(SURV)) for (const f of fs.readdirSync(SURV).filter(x => x.endsWith('.json'))) { const s = readJson(path.join(SURV, f)); if (!lib[s.id]) lib[s.id] = s; }
  const resolve = id => {
    if (lib[id]) return lib[id];
    const f = path.join(SD, 'candidates', id + '.json'); if (!fs.existsSync(f)) throw new Error('strategy not found: ' + id);
    const c = readJson(f), b = lib[c.base || B.id]; if (!b) throw new Error('base not found: ' + c.base);
    const p = Object.assign({}, b.params);
    for (const k of Object.keys(c.overrides || {})) { if (!(k in p)) throw new Error('unknown param ' + k + ' in ' + id); p[k] = c.overrides[k]; }
    return { id: c.id, name: c.name, params: p, engine: c.engine || 'v1' };
  };
  let sids = list(A('strategies') || 'S000,C013'); sids = [B.id].concat(sids.filter(x => x !== B.id));
  const strats = sids.map(resolve);
  for (const s of strats) if ((s.engine || 'v1') !== 'v1') throw new Error(s.id + ': engine ' + s.engine + ' not supported');
  const Match = B.params.Match || '_AL_120t_';
  const loadItem = (tickDir, dailyDir, f) => {
    const buf = fs.readFileSync(path.join(tickDir, f)), bars = loadTicksText(buf.toString('utf8'));
    const code = f.split('_')[0], dm = f.match(/(\d{8})\.csv$/i), m = f.match(/_(\d+)t_/);
    const date = dm ? dm[1] : bars[bars.length - 1].d, start = bars.findIndex(b => b.d === date);
    if (start < 0) throw new Error('target date not in file');
    const warn = [], dly = loadDaily2(dailyDir, code, date, warn);
    return { f, code, date, bars, start, scope: m ? Number(m[1]) : 120, dly, warn, sha: sha(buf) };
  };
  const run = (it, bars, start, params) => {
    const P = V1.prep(Object.assign({}, params, { Date: '', TickScope: it.scope }));
    const dayComplete = bars[start].hms <= P._sessMax;
    let limKind = null;
    if (it.dly && isFinite(it.dly.chg)) { if (it.dly.chg >= P.LimPct) limKind = 'limit'; else if (it.dly.chg >= P.SurgePct) limKind = 'surge'; }
    const ind = V1.compute(bars, P);
    const r = V1.simulate(bars, ind, P, { start, date: it.date, dayComplete, limKind, prevClose: it.dly ? it.dly.c : null, prevChg: it.dly ? it.dly.chg : null });
    return { r, ind };
  };

  // gate: repro 11/02
  const oldT = path.join(ROOT, 'data', 'ticks'), oldD = path.join(ROOT, 'data', 'daily');
  const oldItems = fs.readdirSync(oldT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort().map(f => loadItem(oldT, oldD, f));
  const EXP = { S000: { n: 33, sum: '5.94' }, C013: { n: 31, sum: '8.29' } };
  let reproOk = true;
  for (const s of strats) {
    const st = stats([].concat(...oldItems.map(it => run(it, it.bars, it.start, s.params).r.trades))), e = EXP[s.id];
    if (e && !ok('repro 11/02 ' + s.id, st.n === e.n && st.sum.toFixed(2) === e.sum, 'n=' + st.n + ' sum=' + st.sum.toFixed(2) + ' expected n=' + e.n + ' sum=' + e.sum)) reproOk = false;
  }
  if (!reproOk) return 'FAIL';
  // gate: rest parity
  const restT = path.join(ROOT, 'data', 'rest', 'ticks'), restD = path.join(ROOT, 'data', 'rest', 'daily');
  const PF = '0011A0_AL_120t_20261102.csv', a0 = oldItems.find(x => x.f === PF);
  if (!ok('rest parity file present', a0 && fs.existsSync(path.join(restT, PF)), PF)) return 'FAIL';
  const b0 = loadItem(restT, restD, PF);
  ok('rest bytes = data/ticks (' + PF + ')', a0.sha === b0.sha, a0.sha.slice(0, 12) + ' vs ' + b0.sha.slice(0, 12));
  for (const s of strats) {
    const x = run(a0, a0.bars, a0.start, s.params).r, y = run(b0, b0.bars, b0.start, s.params).r;
    const m = sameTr(x, y, 0) || sameCnt(x, y);
    ok('rest pipeline = old pipeline ' + s.id, !m, m);
  }
  if (chk.some(c => !c.c)) return 'FAIL';

  // capture csv
  const capF = findCapCsv(); let cap = new Map(), capInfo = 'capture csv not found (pass -Csv)';
  if (capF) { const c = loadCap(capF); cap = c.m; capInfo = 'capture csv=' + capF + ' rows=' + c.rows + ' bad=' + c.bad + ' stockDays=' + cap.size + ' status=' + JSON.stringify(c.stat); }

  // archive
  const files = fs.readdirSync(restT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort();
  const items = []; let excl = 0;
  for (const f of files) { let it; try { it = loadItem(restT, restD, f); } catch (e) { excl++; continue; } if (it.start >= MINW) items.push(it); }
  items.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : (a.code < b.code ? -1 : 1));
  if (!ok('eligible stock-days >= 1', items.length > 0, 'eligible=' + items.length)) return 'FAIL';
  const dates = [...new Set(items.map(x => x.date))].sort(), HA = new Set(dates.slice(0, Math.ceil(dates.length / 2)));
  for (const it of items) { it.cD = dayClose(restD, it.code, it.date); it.cp = cap.get(it.code + '|' + it.date) || null; it.tm = it.cp ? tickMfe(it, it.cp) : null; }

  const tgtPx = (entry, T) => { const raw = entry * (1 + T / 100), ts = TS(raw); return Math.ceil(raw / ts - 1e-9) * ts; };
  const overlay = (it, t, T, mode) => {
    const tp = tgtPx(t.inPx, T), need = mode === 'through' ? tp + TS(tp) : tp;
    for (let j = t.inI + 1; j <= t.outI; j++) {
      if (j === t.outI && (t.why === 'stop' || t.why === 'time')) break;
      if (it.bars[j].h >= need) return { j, px: tp };
    }
    return null;
  };
  const adjRet = (it, t) => {
    const outH = it.bars[t.outI].hms;
    return (it.cD && outH > 152000 && (t.why === 'time' || t.why === 'eod')) ? t.ret + (it.cD - t.outPx) / t.inPx * 100 : t.ret;
  };

  // grid
  const RULES = ['all', 'first', 'untilWin', 'untilTgt'], grid = [], native = {};
  for (const s of strats) {
    native[s.id] = s.params.StopPct;
    const stops = [...new Set([s.params.StopPct].concat(STOPS))];
    for (const sp of stops) {
      const params = sp === s.params.StopPct ? s.params : Object.assign({}, s.params, { StopPct: sp });
      const FEE = params.FeePct, per = items.map(it => run(it, it.bars, it.start, params).r.trades);
      if (sp === s.params.StopPct) {
        const p1 = Object.assign({}, s.params, { MaxTrades: 1 }); let bad = 0, first = '';
        items.forEach((it, k) => { const r1 = run(it, it.bars, it.start, p1).r, m = sameTr({ trades: per[k].slice(0, 1) }, r1, 0); if (m) { bad++; if (!first) first = it.code + ' ' + it.date + ': ' + m; } });
        ok('MaxTrades=1 engine = first-trade overlay ' + s.id, bad === 0, 'mismatch=' + bad + ' ' + first);
      }
      for (const rule of RULES) for (const T of [null].concat(TG)) {
        if (rule === 'all' && T != null) continue;
        if (rule === 'untilTgt' && T == null) continue;
        for (const mode of (T == null ? ['-'] : ['through', 'touch'])) {
          const trs = [], ds = []; let hit = 0, Aa = 0, Bb = 0;
          items.forEach((it, k) => {
            let dsum = 0, dadj = 0, n = 0;
            for (const t of per[k]) {
              const o = T == null ? null : overlay(it, t, T, mode);
              let ret, ra;
              if (o) { ret = (o.px / t.inPx - 1) * 100 - FEE; ra = ret; hit++; } else { ret = t.ret; ra = adjRet(it, t); }
              trs.push({ ret, retAdj: ra, mfe: t.mfe }); dsum += ret; dadj += ra; n++;
              if (HA.has(it.date)) Aa += ra; else Bb += ra;
              if (rule === 'first') break;
              if (rule === 'untilTgt' && o) break;
              if (rule === 'untilWin' && ret > 0) break;
            }
            if (n) ds.push({ code: it.code, date: it.date, sum: dsum, adj: dadj, it });
          });
          const S = stats(trs);
          grid.push({ sid: s.id, sp, rule, T, mode, n: S.n, w: S.w, sum: S.sum, sumA: trs.reduce((a, x) => a + x.retAdj, 0), pf: S.pf, mdd: S.mdd,
            days: ds.length, lossD: ds.filter(d => d.adj < 0).length, worst: ds.length ? Math.min(...ds.map(d => d.adj)) : 0, A: Aa, B: Bb, hit, ds });
        }
      }
    }
  }

  // gate: reproduce S4-1
  const g = (sid, rule) => grid.find(r => r.sid === sid && r.sp === native[sid] && r.rule === rule && r.T == null);
  for (const s of strats) {
    const e = XP[s.id]; if (!e) continue;
    const ra = g(s.id, 'all'), rf = g(s.id, 'first'), ru = g(s.id, 'untilWin');
    const got = [ra.sum, ra.sumA, rf.sum, ru.sum].map(x => x.toFixed(2)), exp = [e.all, e.adj, e.first, e.uw].map(x => Number(x).toFixed(2));
    ok('repro S4-1 ' + s.id + ' all/adj/first/untilWin', got.join() === exp.join(), 'got ' + got.join(' ') + ' expected ' + exp.join(' '));
  }

  const fT = r => r.T == null ? 'off' : String(r.T);
  const RH = 'strat stop rule       T  fill       n  win%     sum  sumAdj   A_adj   B_adj    PF    MDD days loss%  worstD  hit%';
  const rowL = r => r.sid.padEnd(6) + pad(r.sp, 4) + ' ' + r.rule.padEnd(9) + pad(fT(r), 5) + ' ' + r.mode.padEnd(8) + pad(r.n, 6) + pad(r.n ? (r.w / r.n * 100).toFixed(1) : '-', 6) +
    pad(fx(r.sum), 8) + pad(fx(r.sumA), 8) + pad(fx(r.A), 8) + pad(fx(r.B), 8) + pad(r.pf.toFixed(2), 6) + pad(r.mdd.toFixed(1), 7) + pad(r.days, 5) +
    pad(r.days ? (r.lossD / r.days * 100).toFixed(1) : '-', 6) + pad(fx(r.worst), 8) + pad(r.n ? (r.hit / r.n * 100).toFixed(1) : '-', 6);
  const main = grid.filter(r => r.mode !== 'touch');
  const rk = main.filter(r => r.A > 0 && r.B > 0).sort((a, b) => b.sumA - a.sumA).slice(0, 15);
  data('top15 by sumAdj (A_adj>0 and B_adj>0, fill=through). A=' + [...HA][0] + '~' + [...HA].pop() + ' B=rest', [RH].concat(rk.map(rowL)));
  const lk = main.filter(r => r.sumA > 0 && r.days >= 30).sort((a, b) => a.lossD / a.days - b.lossD / b.days || b.sumA - a.sumA).slice(0, 10);
  data('lowest loss-day% (sumAdj>0, days>=30)', [RH].concat(lk.map(rowL)));
  data('grid (fill=through; MDD sequential by date/code on ret)', [RH].concat(main.map(rowL)));
  const tl = ['strat rule        T  sumAdj(through)  sumAdj(touch)  hit%(through)  hit%(touch)'];
  for (const s of strats) for (const rule of ['first', 'untilTgt']) for (const T of TG) {
    const a = grid.find(r => r.sid === s.id && r.sp === native[s.id] && r.rule === rule && r.T === T && r.mode === 'through');
    const b = grid.find(r => r.sid === s.id && r.sp === native[s.id] && r.rule === rule && r.T === T && r.mode === 'touch');
    tl.push(s.id.padEnd(6) + rule.padEnd(9) + pad(T, 5) + pad(fx(a.sumA), 17) + pad(fx(b.sumA), 15) + pad((a.hit / a.n * 100).toFixed(1), 15) + pad((b.hit / b.n * 100).toFixed(1), 13));
  }
  data('fill model: through vs touch (native stop)', tl);

  // capture
  const pl = ['strat rule   T   days  realizedAdj  sumMfe60csv  cap60%  sumMfeDayTick  capDay%   (traded days with csv match only)'];
  const capRows = [g(strats[0].id, 'all'), g(strats[0].id, 'first')].concat(strats.slice(1).map(s => g(s.id, 'first'))).concat(rk.slice(0, 3));
  for (const r of capRows) {
    const d = r.ds.filter(x => x.it.cp && isFinite(x.it.cp.m60) && x.it.tm && isFinite(x.it.tm.mD));
    const rs = d.reduce((a, x) => a + x.adj, 0), m6 = d.reduce((a, x) => a + x.it.cp.m60, 0), mD = d.reduce((a, x) => a + x.it.tm.mD, 0);
    pl.push(r.sid.padEnd(6) + r.rule.padEnd(9) + pad(fT(r), 4) + ' s' + r.sp + pad(d.length, 5) + pad(fx(rs), 13) + pad(m6.toFixed(2), 13) + pad(m6 > 0 ? (rs / m6 * 100).toFixed(1) : '-', 8) + pad(mD.toFixed(2), 15) + pad(mD > 0 ? (rs / mD * 100).toFixed(1) : '-', 9));
  }
  let matched = 0, diff = 0; const dl = [], cr = ['code,date,capHms,capPx,mfe60csv,ret60csv,ret60at,mfe60tick,mfeDayTick'];
  for (const it of items) {
    if (!it.cp) continue; matched++;
    cr.push([it.code, it.date, it.cp.hms, it.cp.px, it.cp.m60, it.cp.r60, it.cp.r60t, it.tm ? it.tm.m60.toFixed(3) : '', it.tm ? it.tm.mD.toFixed(3) : ''].join(','));
    if (it.tm && isFinite(it.cp.m60) && isFinite(it.tm.m60) && Math.abs(it.cp.m60 - it.tm.m60) > 1) { diff++; if (dl.length < 15) dl.push(it.code + ' ' + it.date + ' cap=' + it.cp.hms + ' px=' + it.cp.px + ' csv=' + it.cp.m60 + ' tick=' + it.tm.m60.toFixed(2)); }
  }
  pl.push('eligible stock-days matched to csv: ' + matched + '/' + items.length + '  csv vs tick mfe60 |diff|>1%p: ' + diff);
  data('capture', pl.concat(dl));

  const gh = ['strategy,stop,rule,T,fill,n,w,sum,sumAdj,A_adj,B_adj,PF,MDD,days,lossDays,worstDay,hits'];
  for (const r of grid) gh.push([r.sid, r.sp, r.rule, fT(r), r.mode, r.n, r.w, r.sum.toFixed(3), r.sumA.toFixed(3), r.A.toFixed(3), r.B.toFixed(3), r.pf.toFixed(3), r.mdd.toFixed(3), r.days, r.lossD, r.worst.toFixed(3), r.hit].join(','));
  fs.writeFileSync(path.join(RDIR, 'detail', 'grid.csv'), gh.join('\r\n') + '\r\n');
  fs.writeFileSync(path.join(RDIR, 'detail', 'capture_days.csv'), cr.join('\r\n') + '\r\n');

  sums.push('eligible(>=' + MINW + ')=' + items.length + ' excluded=' + excl + ' dates=' + dates.length + ' range=' + dates[0] + '~' + dates[dates.length - 1]);
  sums.push(capInfo);
  sums.push('strategies=' + strats.map(s => s.id).join(',') + ' targets=' + TG.join(',') + ' stops=' + STOPS.join(',') + ' gridRows=' + grid.length);
  try {
    const pg = path.join(ROOT, 'docs', 'progress.md');
    if (fs.existsSync(pg)) fs.appendFileSync(pg, '\n- S4-2 target (' + VER + ') ' + LSTAMP + ': eligible=' + items.length + ' top=' + (rk[0] ? rk[0].sid + '/s' + rk[0].sp + '/' + rk[0].rule + '/T' + fT(rk[0]) + ' adj=' + rk[0].sumA.toFixed(2) : 'none') + ' report=' + RDIR + '\n');
  } catch (e) { sums.push('progress.md append failed: ' + e.message); }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL';
try { verdict = main(); report(verdict); }
catch (e) { verdict = 'FAIL'; try { report('FAIL', e); } catch (e2) { console.log('report write failed: ' + e2.message); } }
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);
'@
if (Test-Path $Js) { Copy-Item $Js "$Js.bak35" -Force }
[System.IO.File]::WriteAllText($Js, $code, $U8)
$chk = & node --check $Js 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail 'node --check s4_target.cjs' $chk }
$na = @($Js, $Root, '--strategies', $Strategies, '--minWarm', "$MinWarm", '--targets', $Targets, '--stops', $Stops)
if ($Csv) { $na += @('--csv', $Csv) }
& node @na
exit $LASTEXITCODE
