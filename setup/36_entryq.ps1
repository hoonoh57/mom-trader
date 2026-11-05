param([string]$Strategies = 'S000', [int]$MinWarm = 400, [string]$Csv = '', [string]$ExclDate = '20261021')
$ErrorActionPreference = 'Continue'
$Root = 'E:\parent\projects\rea\projects\mom-trader'
$Out = Join-Path $Root 'out\FOR_OPUS.txt'
$Js = Join-Path $Root 'tools\ui\s4_entryq.cjs'
$U8 = New-Object System.Text.UTF8Encoding($false)
function Fail([string]$m, [string]$d) {
  $t = "#MT-REPORT v=report-1.0 step=S4.entryq ver=ps-wrapper verdict=FAIL ts=$((Get-Date).ToString('s'))`n#FAIL $m`n$d`n"
  [System.IO.File]::WriteAllText($Out, $t, $U8); Write-Host "FAIL S4.entryq -> $Out"; exit 1
}
$code = @'
'use strict';
// s4_entryq.cjs (entryq-1.0) - S4-3 first-entry quality. Read-only on engines and data.
// Base: first trade per stock-day (engine MaxTrades=1 equivalent, verified in S4-2), native StopPct.
// Overlays on the engine trade (exact for first-trade rule):
//   target: resting limit at ceilTick(entry*(1+T/100)), 'through' = high >= tp + 1 tick (copied from target-1.0).
//   BE: once high >= entry*(1+X/100), from NEXT bar stop = ceilTick(entry*(1+Fee/100)); fill min(open, be).
//   bar order: BE stop -> (engine stop/time at outI wins) -> target -> arm BE.
// Filters: exact skip of the stock-day (no substitute entry). Missing feature value = keep.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const VER = 'entryq-1.0', STEP = 'S4.entryq';
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
const fx = x => isFinite(x) ? (x > 0 ? '+' : '') + Number(x).toFixed(2) : '-';
const f2 = x => isFinite(x) ? Number(x).toFixed(2) : '-';
const f4 = x => isFinite(x) ? Number(x).toFixed(4) : '';
const pad = (s, n) => String(s).padStart(n);
const avg = arr => { const v = arr.filter(x => isFinite(x)); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : NaN; };

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

// ---- copied from s4_target.cjs ----
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
// ---- end copy ----

function main() {
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  const MINW = Number(A('minWarm') || 400), EXCL = A('excl') || '20261021';
  const XP = {};
  for (const q of list(A('expect') || 'S000:87.90:96.53:46.90:-52.09:-2.02').map(s => s.split(':'))) XP[q[0]] = { first: q[1], adj: q[2], t15: q[3], fA: q[4], tA: q[5] };
  const E = require(path.join(ROOT, 'tools', 'ui', 'engines.cjs'));
  engVer = E.VERSION;
  const vr = E.verify(ROOT);
  if (!ok('engine hash gate (' + E.VERSION + ')', vr && vr.ok, 'missing=' + JSON.stringify(vr && vr.missing))) return 'FAIL';
  const LD = E.load(ROOT), V1 = LD.V1, RK = LD.R;
  if (!ok('V1 api prep/compute/simulate', V1 && ['prep', 'compute', 'simulate'].every(k => typeof V1[k] === 'function'), Object.keys(V1 || {}).join(','))) return 'FAIL';
  const TS = RK && typeof RK.tickSize === 'function' ? p => RK.tickSize(p) : null;
  const TSMP = [1500, 3000, 15000, 30000, 150000, 300000];
  if (!ok('risk1 tickSize()', TS && TSMP.every(p => TS(p) > 0), TS ? TSMP.map(p => p + '=' + TS(p)).join(' ') : 'R.tickSize missing')) return 'FAIL';

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
  let sids = list(A('strategies') || 'S000'); sids = [B.id].concat(sids.filter(x => x !== B.id));
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
  if (capF) { const c = loadCap(capF); cap = c.m; capInfo = 'capture csv=' + capF + ' rows=' + c.rows + ' bad=' + c.bad + ' stockDays=' + cap.size; }
  sums.push(capInfo);

  // archive
  const files = fs.readdirSync(restT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort();
  const items = []; let excl = 0;
  for (const f of files) { let it; try { it = loadItem(restT, restD, f); } catch (e) { excl++; continue; } if (it.start >= MINW) items.push(it); }
  items.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : (a.code < b.code ? -1 : 1));
  if (!ok('eligible stock-days >= 1', items.length > 0, 'eligible=' + items.length)) return 'FAIL';
  const dates = [...new Set(items.map(x => x.date))].sort(), HA = new Set(dates.slice(0, Math.ceil(dates.length / 2)));
  for (const it of items) { it.cD = dayClose(restD, it.code, it.date); it.cp = cap.get(it.code + '|' + it.date) || null; }
  sums.push('eligible=' + items.length + ' excludedFiles=' + excl + ' dates=' + dates.length + ' A=' + dates[0] + '~' + [...HA].pop() + ' B=rest exclDate=' + EXCL);

  const tgtPx = (entry, T) => { const raw = entry * (1 + T / 100), ts = TS(raw); return Math.ceil(raw / ts - 1e-9) * ts; };
  const ov35 = (it, t, T, mode) => {
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
  const sim = (it, t, T, X, mode, FEE) => {
    const tp = T == null ? Infinity : tgtPx(t.inPx, T);
    const need = T == null ? Infinity : (mode === 'through' ? tp + TS(tp) : tp);
    const trig = X == null ? Infinity : t.inPx * (1 + X / 100);
    const be = X == null ? -Infinity : tgtPx(t.inPx, FEE);
    let armed = false;
    for (let j = t.inI + 1; j <= t.outI; j++) {
      const b = it.bars[j];
      if (armed && b.l <= be) return { j, px: Math.min(b.o, be), why: 'be' };
      if (j === t.outI && (t.why === 'stop' || t.why === 'time')) break;
      if (b.h >= need) return { j, px: tp, why: 'tgt' };
      if (b.h >= trig) armed = true;
    }
    return null;
  };
  const KEY = (T, X) => String(T) + '|' + String(X), K0 = KEY(null, null), K15 = KEY(1.5, null);
  const XS = [null, 0.75, 1, 1.5, 2], TL = [null, 1.5];
  const BK = [['chase', [-1, 0, 1, 2, 3, 5]], ['delay', [0, 5, 15, 30, 60, 120]], ['rise', [5, 10, 15, 20, 25]], ['openGap', [0, 2, 5, 10]], ['prevChg', [0, 5, 10, 20]], ['inHms', [90500, 91500, 93000, 100000, 110000, 130000]]];
  const FL = [['none', null, [null]], ['chaseMax', 'chase', [0, 0.5, 1, 2, 3, 5]], ['riseMax', 'rise', [10, 15, 20, 25, 30]], ['delayMax', 'delay', [0, 5, 15, 30, 60]],
    ['inHmsMax', 'inHms', [90500, 91500, 93000, 100000, 110000]], ['openGapMax', 'openGap', [2, 5, 10]], ['prevChgMax', 'prevChg', [5, 10, 20]]];
  const labsOf = e => { const L = []; for (let k = 0; k <= e.length; k++) L.push(k === 0 ? '<' + e[0] : k === e.length ? '>=' + e[k - 1] : e[k - 1] + '~' + e[k]); L.push('n/a'); return L; };
  const bOf = (v, e) => { if (!isFinite(v)) return 'n/a'; let k = 0; while (k < e.length && v >= e[k]) k++; return k === 0 ? '<' + e[0] : k === e.length ? '>=' + e[k - 1] : e[k - 1] + '~' + e[k]; };

  for (const s of strats) {
    const P = s.params, FEE = P.FeePct, rows = [];
    for (const it of items) {
      const tr = run(it, it.bars, it.start, P).r.trades; if (!tr.length) continue;
      const t = tr[0], capT = it.cp ? toT(it.date, it.cp.hms) : null;
      rows.push({ it, t, code: it.code, date: it.date, half: HA.has(it.date) ? 'A' : 'B', inHms: it.bars[t.inI].hms,
        chase: it.cp ? (t.inPx / it.cp.px - 1) * 100 : NaN, delay: it.cp ? (it.bars[t.inI].t - capT) / 60 : NaN,
        rise: it.dly ? (t.inPx / it.dly.c - 1) * 100 : NaN, openGap: it.dly ? (it.bars[it.start].o / it.dly.c - 1) * 100 : NaN,
        prevChg: it.dly ? it.dly.chg : NaN });
    }
    if (!ok('first-trade rows >= 1 ' + s.id, rows.length > 0, 'rows=' + rows.length)) continue;
    // gate: BE-off sim == target-1.0 overlay
    let pm = 0, pc = 0, p1 = '';
    for (const r of rows) for (const T of [0.5, 1, 1.5, 2, 3]) for (const mode of ['through', 'touch']) {
      const a = ov35(r.it, r.t, T, mode), b = sim(r.it, r.t, T, null, mode, FEE); pc++;
      if ((a == null) !== (b == null) || (a && (a.j !== b.j || a.px !== b.px))) { pm++; if (!p1) p1 = r.code + ' ' + r.date + ' T' + T + ' ' + mode; }
    }
    ok('BE-off sim = target-1.0 overlay ' + s.id, pm === 0, 'mismatch=' + pm + '/' + pc + ' ' + p1);
    for (const r of rows) {
      r.R = {};
      for (const T of TL) for (const X of XS) {
        const o = (T == null && X == null) ? null : sim(r.it, r.t, T, X, 'through', FEE);
        if (o) { const ret = (o.px / r.t.inPx - 1) * 100 - FEE; r.R[KEY(T, X)] = { ret, adj: ret, why: o.why }; }
        else r.R[KEY(T, X)] = { ret: r.t.ret, adj: adjRet(r.it, r.t), why: '' };
      }
    }
    const agg = (sel, key) => {
      const trs = []; let sumA = 0, Aa = 0, Bb = 0, xx = 0, lossD = 0, worst = 0, tg = 0, be = 0;
      for (const r of sel) {
        const z = r.R[key]; trs.push({ ret: z.ret, mfe: r.t.mfe }); sumA += z.adj;
        if (r.half === 'A') Aa += z.adj; else Bb += z.adj; if (r.date !== EXCL) xx += z.adj;
        if (z.adj < 0) lossD++; if (z.adj < worst) worst = z.adj; if (z.why === 'tgt') tg++; if (z.why === 'be') be++;
      }
      return Object.assign(stats(trs), { sumA, A: Aa, B: Bb, x: xx, lossD, worst, tg, be });
    };
    const base = agg(rows, K0), t15 = agg(rows, K15), e = XP[s.id];
    sums.push(s.id + ' first rows=' + rows.length + ' capMatched=' + rows.filter(r => r.it.cp).length + ' prevClose=' + rows.filter(r => r.it.dly).length +
      ' | off: sum=' + fx(base.sum) + ' adj=' + fx(base.sumA) + ' A=' + fx(base.A) + ' B=' + fx(base.B) + ' | T1.5: adj=' + fx(t15.sumA) + ' A=' + fx(t15.A) + ' B=' + fx(t15.B));
    if (e) {
      const got = [base.sum, base.sumA, t15.sumA, base.A, t15.A].map(v => v.toFixed(2)), exp = [e.first, e.adj, e.t15, e.fA, e.tA].map(v => Number(v).toFixed(2));
      ok('repro S4-2 ' + s.id + ' first sum/adj, T1.5 adj, A(first), A(T1.5)', got.join() === exp.join(), 'got ' + got.join(' ') + ' expected ' + exp.join(' '));
    }

    // buckets
    const bl = ['feat     bucket          n  win%  sumAdj  avgAdj  T15adj   avgT15   A_adj   B_adj loss%  avgMfe'];
    for (const [fk, edges] of BK) for (const lb of labsOf(edges)) {
      const sel = rows.filter(r => bOf(r[fk], edges) === lb); if (!sel.length) continue;
      const a = agg(sel, K0), b = agg(sel, K15);
      bl.push(fk.padEnd(8) + ' ' + lb.padEnd(14) + pad(a.n, 4) + pad((a.w / a.n * 100).toFixed(1), 6) + pad(fx(a.sumA), 8) + pad(fx(a.sumA / a.n), 8) + pad(fx(b.sumA), 8) + pad(fx(b.sumA / b.n), 9) +
        pad(fx(a.A), 8) + pad(fx(a.B), 8) + pad((a.lossD / a.n * 100).toFixed(1), 6) + pad(a.avgMfe.toFixed(2), 8));
    }
    data(s.id + ' first-trade buckets (native stop; T off vs T1.5 through; chase=entry vs capture px %, delay=min after capture, rise=entry vs prev close %)', bl);

    // scan
    const sc = [];
    for (const [fn, fk, ths] of FL) for (const th of ths) {
      const sel = fk == null ? rows : rows.filter(r => !isFinite(r[fk]) || r[fk] <= th);
      for (const T of TL) for (const X of XS) sc.push({ fn, th, T, X, skip: rows.length - sel.length, a: agg(sel, KEY(T, X)) });
    }
    const SH = 'filter          th     T    BE    n  skip  win%     sum  sumAdj   A_adj   B_adj  xExcl    PF    MDD loss%  worstD  tgt%   be%';
    const scL = z => z.fn.padEnd(11) + pad(z.th == null ? '-' : z.th, 7) + pad(z.T == null ? 'off' : z.T, 6) + pad(z.X == null ? 'off' : z.X, 6) + pad(z.a.n, 5) + pad(z.skip, 6) +
      pad(z.a.n ? (z.a.w / z.a.n * 100).toFixed(1) : '-', 6) + pad(fx(z.a.sum), 8) + pad(fx(z.a.sumA), 8) + pad(fx(z.a.A), 8) + pad(fx(z.a.B), 8) + pad(fx(z.a.x), 7) +
      pad(z.a.pf.toFixed(2), 6) + pad(z.a.mdd.toFixed(1), 7) + pad(z.a.n ? (z.a.lossD / z.a.n * 100).toFixed(1) : '-', 6) + pad(fx(z.a.worst), 8) +
      pad(z.a.n ? (z.a.tg / z.a.n * 100).toFixed(1) : '-', 6) + pad(z.a.n ? (z.a.be / z.a.n * 100).toFixed(1) : '-', 6);
    data(s.id + ' top15 sumAdj with A_adj>0 and B_adj>0', [SH].concat(sc.filter(z => z.a.A > 0 && z.a.B > 0).sort((a, b) => b.a.sumA - a.a.sumA).slice(0, 15).map(scL)));
    data(s.id + ' lowest loss-day% (sumAdj>0, n>=100)', [SH].concat(sc.filter(z => z.a.sumA > 0 && z.a.n >= 100).sort((a, b) => a.a.lossD / a.a.n - b.a.lossD / b.a.n || b.a.sumA - a.a.sumA).slice(0, 10).map(scL)));
    data(s.id + ' scan: single filter x T{off,1.5} x BE{off,.75,1,1.5,2} (xExcl = sumAdj without ' + EXCL + ')', [SH].concat(sc.map(scL)));

    // dates
    const dl = ['date      half elig trd  win%  sumAdj  T15adj  avgChase  avgMfe60csv  avgPrevChg'];
    const dRow = (lab, hf, el, sel) => {
      if (!sel.length) return lab.padEnd(10) + hf.padEnd(5) + pad(el, 4) + pad(0, 4);
      const a = agg(sel, K0), b = agg(sel, K15);
      return lab.padEnd(10) + hf.padEnd(5) + pad(el, 4) + pad(a.n, 4) + pad((a.w / a.n * 100).toFixed(1), 6) + pad(fx(a.sumA), 8) + pad(fx(b.sumA), 8) +
        pad(f2(avg(sel.map(r => r.chase))), 10) + pad(f2(avg(sel.map(r => r.it.cp ? r.it.cp.m60 : NaN))), 13) + pad(f2(avg(sel.map(r => r.prevChg))), 12);
    };
    for (const d of dates) dl.push(dRow(d, HA.has(d) ? 'A' : 'B', items.filter(x => x.date === d).length, rows.filter(r => r.date === d)));
    dl.push(dRow('A', '', items.filter(x => HA.has(x.date)).length, rows.filter(r => r.half === 'A')));
    dl.push(dRow('B', '', items.filter(x => !HA.has(x.date)).length, rows.filter(r => r.half === 'B')));
    dl.push(dRow('excl' + EXCL.slice(4), '', items.filter(x => x.date !== EXCL).length, rows.filter(r => r.date !== EXCL)));
    data(s.id + ' by date (first trade, T off vs T1.5)', dl);

    // detail
    const fc = ['code,date,half,inHms,inPx,capHms,capPx,chase,delay,rise,openGap,prevChg,why,ret,retAdj,mfe,mae,retT15,whyT15'];
    for (const r of rows) fc.push([r.code, r.date, r.half, r.inHms, r.t.inPx, r.it.cp ? r.it.cp.hms : '', r.it.cp ? r.it.cp.px : '', f4(r.chase), f4(r.delay), f4(r.rise), f4(r.openGap), f4(r.prevChg),
      r.t.why, f4(r.R[K0].ret), f4(r.R[K0].adj), f4(r.t.mfe), f4(r.t.mae), f4(r.R[K15].adj), r.R[K15].why || r.t.why].join(','));
    fs.writeFileSync(path.join(RDIR, 'detail', 'first_' + s.id + '.csv'), fc.join('\n') + '\n');
    const sv = ['filter,th,T,BE,n,skip,win,sum,sumAdj,A,B,xExcl,pf,mdd,lossD,worst,tgt,be'];
    for (const z of sc) sv.push([z.fn, z.th == null ? '' : z.th, z.T == null ? '' : z.T, z.X == null ? '' : z.X, z.a.n, z.skip, z.a.w, f4(z.a.sum), f4(z.a.sumA), f4(z.a.A), f4(z.a.B), f4(z.a.x), f4(z.a.pf), f4(z.a.mdd), z.a.lossD, f4(z.a.worst), z.a.tg, z.a.be].join(','));
    fs.writeFileSync(path.join(RDIR, 'detail', 'scan_' + s.id + '.csv'), sv.join('\n') + '\n');
  }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL', err = null;
try { verdict = main(); } catch (e) { err = e; verdict = 'FAIL'; }
report(verdict, err);
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);
'@
try {
  if (Test-Path $Js) { Copy-Item $Js "$Js.bak36" -Force }
  [System.IO.File]::WriteAllText($Js, $code, $U8)
} catch { Fail 'write s4_entryq.cjs failed' $_.Exception.Message }
$c = & node --check $Js 2>&1
if ($LASTEXITCODE -ne 0) { Fail 'node --check failed' ($c | Out-String) }
$before = if (Test-Path $Out) { (Get-Item $Out).LastWriteTimeUtc } else { [datetime]::MinValue }
$na = @($Js, $Root, '--strategies', $Strategies, '--minWarm', "$MinWarm", '--excl', $ExclDate)
if ($Csv) { $na += @('--csv', $Csv) }
$o = & node @na 2>&1
$ec = $LASTEXITCODE
if (-not (Test-Path $Out) -or (Get-Item $Out).LastWriteTimeUtc -le $before) { Fail "node exit=$ec, report not written" ($o | Out-String) }
Write-Host ($o | Select-Object -Last 1)
exit $ec
