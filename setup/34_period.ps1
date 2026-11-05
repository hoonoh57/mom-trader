param([string]$Strategies = 'S000,C013', [int]$MinWarm = 400, [int]$Ref = 800, [string]$Csv = '', [string]$Excl = '20261021')
$ErrorActionPreference = 'Continue'
$Root = 'E:\parent\projects\rea\projects\mom-trader'
$Out = Join-Path $Root 'out\FOR_OPUS.txt'
$Js = Join-Path $Root 'tools\ui\s4_period.cjs'
$U8 = New-Object System.Text.UTF8Encoding($false)
function Fail([string]$m, [string]$d) {
  $t = "#MT-REPORT v=report-1.0 step=S4.period ver=ps-wrapper verdict=FAIL ts=$((Get-Date).ToString('s'))`n#FAIL $m`n$d`n"
  [System.IO.File]::WriteAllText($Out, $t, $U8); Write-Host "FAIL S4.period -> $Out"; exit 1
}
$code = @'
'use strict';
// s4_period.cjs (period-1.0) - S4-1 period backtest on data\rest archive. Read-only on engines and data.
// Eligible: target-day stock-days with warmup >= MinWarm (S4-0: 400 -> 99% same trades vs 800). Runs use ALL available warmup bars.
// Gates: engine hashes, repro 11/02, rest parity (copied from s4_warmup.cjs), cross-check vs S4-0 full>=REF set.
// sumAdj: exits after 15:20 by time/eod/r_time/r_flat re-priced at KRX daily close (delta method, approx). Original ret untouched.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const VER = 'period-1.0', STEP = 'S4.period';
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

// ---- copied from s4_warmup.cjs (copied from sz-lab-guard11.cjs) ----
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
// ---- end copy ----

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
function loadCap(f) {
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), m = new Map(); let bad = 0;
  for (const r of rows.slice(1)) {
    const d = String(r[2] || '').replace(/\D/g, '').slice(0, 8);
    let c = String(r[3] || '').trim().toUpperCase(); if (c.length === 7 && c[0] === 'A') c = c.slice(1);
    let t = String(r[1] || '').replace(/\D/g, ''); t = t.length <= 4 ? t.padStart(4, '0') + '00' : t.slice(-6).padStart(6, '0');
    const hms = Number(t), px = Math.abs(num(r[5]));
    if (d.length !== 8 || !c || !(px > 0) || !(hms >= 80000 && hms <= 200000)) { bad++; continue; }
    const k = c + '|' + d, o = m.get(k), v = { hms, px, m60: num(r[14]), r60: num(r[15]), cnt: (o ? o.cnt : 0) + 1 };
    if (!o || hms < o.hms) m.set(k, v); else o.cnt++;
  }
  return { m, rows: rows.length - 1, bad };
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
function grepFile(rel, re, max) {
  const f = path.join(ROOT, rel); if (!fs.existsSync(f)) return [rel + ': missing'];
  const L = fs.readFileSync(f, 'utf8').split(/\r?\n/), out = [];
  for (let i = 0; i < L.length && out.length < max; i++) if (re.test(L[i])) out.push(rel + ':' + (i + 1) + ': ' + L[i].trim().slice(0, 220));
  return out.length ? out : [rel + ': no match'];
}

function main() {
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  const REF = Number(A('ref') || 800), MINW = Number(A('minWarm') || 400);
  const EXCL = list(A('excl') || '20261021'), CH = Number(A('chase') || 0.5), GV = Number(A('give') || 1.0);
  const TGT = list(A('targets') || '0.5,1,1.5,2,3,5').map(Number);
  const XP = {}; for (const s of list(A('expect') || 'S000:1074:-138.19,C013:959:-172.54')) { const q = s.split(':'); XP[q[0]] = { n: Number(q[1]), sum: Number(q[2]) }; }
  const E = require(path.join(ROOT, 'tools', 'ui', 'engines.cjs'));
  engVer = E.VERSION;
  const vr = E.verify(ROOT);
  if (!ok('engine hash gate (' + E.VERSION + ')', vr && vr.ok, 'missing=' + JSON.stringify(vr && vr.missing))) return 'FAIL';
  const V1 = E.load(ROOT).V1;
  if (!ok('V1 api prep/compute/simulate', V1 && ['prep', 'compute', 'simulate'].every(k => typeof V1[k] === 'function'), Object.keys(V1 || {}).join(','))) return 'FAIL';

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

  // gate 2: repro 11/02
  const oldT = path.join(ROOT, 'data', 'ticks'), oldD = path.join(ROOT, 'data', 'daily');
  const oldItems = fs.readdirSync(oldT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort().map(f => loadItem(oldT, oldD, f));
  const EXP = { S000: { n: 33, sum: '5.94' }, C013: { n: 31, sum: '8.29' } };
  let reproOk = true;
  for (const s of strats) {
    const st = stats([].concat(...oldItems.map(it => run(it, it.bars, it.start, s.params).r.trades))), e = EXP[s.id];
    if (e && !ok('repro 11/02 ' + s.id, st.n === e.n && st.sum.toFixed(2) === e.sum, 'n=' + st.n + ' sum=' + st.sum.toFixed(2) + ' expected n=' + e.n + ' sum=' + e.sum)) reproOk = false;
  }
  if (!reproOk) return 'FAIL';
  // gate 3: rest parity
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

  // capture csv (optional)
  const capF = findCapCsv(); let cap = new Map(), capInfo = 'capture csv not found (pass -Csv)';
  if (capF) { const c = loadCap(capF); cap = c.m; capInfo = 'capture csv=' + capF + ' rows=' + c.rows + ' bad=' + c.bad + ' stockDays=' + cap.size; }

  // scan archive
  const files = fs.readdirSync(restT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort();
  const items = []; let loaded = 0, excl = 0, noDaily = 0, full = 0; const exL = [];
  for (const f of files) {
    let it; try { it = loadItem(restT, restD, f); } catch (e) { excl++; if (exL.length < 20) exL.push(f + ': ' + e.message); continue; }
    loaded++; if (!it.dly) noDaily++; if (it.start >= REF) full++;
    if (it.start >= MINW) items.push(it);
  }
  items.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : (a.code < b.code ? -1 : 1));
  if (!ok('eligible stock-days >= 1', items.length > 0, 'eligible=' + items.length)) return 'FAIL';

  // run
  const cls = t => t.ret > 0 ? 'win' : (t.mfe < CH ? 'chase' : (t.mfe >= GV ? 'giveback' : 'mid'));
  const trRows = ['strategy,code,date,warm,no,inHms,inPx,outHms,outPx,why,ret,retAdj,mfe,mae,cls'];
  const dayRows = ['strategy,code,date,warm,n,sum,sumAdj,capHms,capPx,mfe60csv,mfe60tick,mfeDayTick'];
  const R = {}; let adjN = 0, mWarn = 0; const mWarnL = [];
  for (const s of strats) {
    const trs = [], days = [];
    for (const it of items) {
      const r = run(it, it.bars, it.start, s.params).r, cD = dayClose(restD, it.code, it.date);
      const cp = cap.get(it.code + '|' + it.date), tm = cp ? tickMfe(it, cp) : null;
      const dt = []; let sum = 0, sumA = 0;
      r.trades.forEach((t, k) => {
        const inH = it.bars[t.inI].hms, outH = it.bars[t.outI].hms;
        let ra = t.ret;
        if (cD && outH > 152000 && /^(time|eod|r_time|r_flat)$/.test(t.why)) { ra = t.ret + (cD - t.outPx) / t.inPx * 100; if (s === strats[0]) adjN++; }
        const x = { sid: s.id, code: it.code, date: it.date, warm: it.start, no: k + 1, inH, outH, inPx: t.inPx, outPx: t.outPx, why: t.why, ret: t.ret, retAdj: ra, mfe: t.mfe, mae: t.mae };
        x.cls = cls(x); trs.push(x); dt.push(x); sum += t.ret; sumA += ra;
        trRows.push([s.id, it.code, it.date, it.start, k + 1, inH, t.inPx, outH, t.outPx, t.why, t.ret.toFixed(3), ra.toFixed(3), Number(t.mfe).toFixed(3), Number(t.mae).toFixed(3), x.cls].join(','));
      });
      days.push({ code: it.code, date: it.date, n: dt.length, sum, sumA, trs: dt, cp, tm });
      dayRows.push([s.id, it.code, it.date, it.start, dt.length, sum.toFixed(3), sumA.toFixed(3), cp ? cp.hms : '', cp ? cp.px : '', cp ? cp.m60 : '', tm ? tm.m60.toFixed(3) : '', tm ? tm.mD.toFixed(3) : ''].join(','));
      if (s === strats[0] && cp && tm && isFinite(cp.m60) && isFinite(tm.m60) && Math.abs(cp.m60 - tm.m60) > 1) { mWarn++; if (mWarnL.length < 15) mWarnL.push(it.code + ' ' + it.date + ' cap=' + cp.hms + ' px=' + cp.px + ' csv=' + cp.m60 + ' tick=' + tm.m60.toFixed(2)); }
    }
    R[s.id] = { trs, days };
  }
  fs.writeFileSync(path.join(RDIR, 'detail', 'trades.csv'), trRows.join('\r\n') + '\r\n');
  fs.writeFileSync(path.join(RDIR, 'detail', 'days.csv'), dayRows.join('\r\n') + '\r\n');

  // gate 4: cross-check vs S4-0 (reported, not early-exit)
  for (const s of strats) {
    const e = XP[s.id]; if (!e) continue;
    const S = stats(R[s.id].trs.filter(x => x.warm >= REF));
    ok('cross-check S4-0 full>=' + REF + ' ' + s.id, S.n === e.n && S.sum.toFixed(2) === e.sum.toFixed(2), 'n=' + S.n + ' sum=' + S.sum.toFixed(2) + ' expected ' + e.n + '/' + e.sum.toFixed(2));
  }

  const st2 = trs => { const s = stats(trs); s.sumA = trs.reduce((a, t) => a + t.retAdj, 0); return s; };
  const HD = 'label'.padEnd(24) + '     n     w   win%      sum   sumAdj     avg    PF     MDD avgMfe';
  const line = (lab, s) => lab.padEnd(24) + pad(s.n, 6) + pad(s.w, 6) + pad(s.n ? (s.w / s.n * 100).toFixed(1) : '-', 7) + pad(fx(s.sum), 9) + pad(fx(s.sumA), 9) + pad(s.avg.toFixed(3), 8) + pad(s.pf.toFixed(2), 6) + pad(s.mdd.toFixed(2), 8) + pad(s.avgMfe.toFixed(2), 7);

  const sl = [HD];
  for (const s of strats) {
    const { trs, days } = R[s.id];
    const fo = days.filter(d => d.n).map(d => d.trs[0]);
    const uw = []; for (const d of days) for (const t of d.trs) { uw.push(t); if (t.ret > 0) break; }
    sl.push(line(s.id + ' all W>=' + MINW, st2(trs)));
    sl.push(line(s.id + ' excl ' + EXCL.join('+'), st2(trs.filter(x => !EXCL.includes(x.date)))));
    sl.push(line(s.id + ' full W>=' + REF, st2(trs.filter(x => x.warm >= REF))));
    sl.push(line(s.id + ' firstOnly', st2(fo)));
    sl.push(line(s.id + ' untilFirstWin', st2(uw)));
  }
  data('summary (MDD = sequential by date/code, approx)', sl);

  const dates = [...new Set(items.map(x => x.date))].sort();
  const dl = ['date     items' + strats.map(s => pad(s.id + ' n', 9) + pad('sum', 9) + pad('sumAdj', 9)).join('')];
  for (const d of dates) {
    let ln = d + pad(items.filter(x => x.date === d).length, 6);
    for (const s of strats) { const t = R[s.id].trs.filter(x => x.date === d), S = st2(t); ln += pad(S.n, 9) + pad(fx(S.sum), 9) + pad(fx(S.sumA), 9); }
    dl.push(ln);
  }
  data('by_date', dl);

  const wl = ['strategy why                 n      sum     avg'];
  for (const s of strats) {
    const g = {}; for (const t of R[s.id].trs) { const k = t.why; (g[k] = g[k] || []).push(t); }
    for (const k of Object.keys(g).sort((a, b) => g[b].length - g[a].length)) { const S = stats(g[k]); wl.push(s.id.padEnd(9) + k.padEnd(18) + pad(S.n, 5) + pad(fx(S.sum), 9) + pad(S.avg.toFixed(3), 8)); }
  }
  data('by_why', wl);

  const cl = ['strategy class        n      sum  avgMfe  avgMae   (chase: loss & mfe<' + CH + ', giveback: loss & mfe>=' + GV + ')'];
  for (const s of strats) for (const k of ['win', 'chase', 'mid', 'giveback']) {
    const t = R[s.id].trs.filter(x => x.cls === k), S = stats(t), mae = t.length ? t.reduce((a, x) => a + Number(x.mae), 0) / t.length : 0;
    cl.push(s.id.padEnd(9) + k.padEnd(10) + pad(S.n, 5) + pad(fx(S.sum), 9) + pad(S.avgMfe.toFixed(2), 8) + pad(mae.toFixed(2), 8));
  }
  data('loss_decomposition', cl);

  const tl = ['strategy   T  trades%mfe>=T  first%mfe>=T  losers%mfe>=T   (engine mfe definition, see probe_v1_mfe)'];
  for (const s of strats) {
    const trs = R[s.id].trs, fo = R[s.id].days.filter(d => d.n).map(d => d.trs[0]), ls = trs.filter(x => x.ret <= 0);
    const pc = (a, T) => a.length ? (a.filter(x => x.mfe >= T).length / a.length * 100).toFixed(1) : '-';
    for (const T of TGT) tl.push(s.id.padEnd(9) + pad(T, 4) + pad(pc(trs, T), 15) + pad(pc(fo, T), 14) + pad(pc(ls, T), 15));
  }
  data('target_reach', tl);

  const pl = ['strategy days  realized  sumMfe60csv  cap60%  sumMfeDayTick  capDay%'];
  for (const s of strats) {
    const d = R[s.id].days.filter(x => x.cp && isFinite(x.cp.m60) && x.tm && isFinite(x.tm.mD));
    const rs = d.reduce((a, x) => a + x.sum, 0), m6 = d.reduce((a, x) => a + x.cp.m60, 0), mD = d.reduce((a, x) => a + x.tm.mD, 0);
    pl.push(s.id.padEnd(9) + pad(d.length, 5) + pad(fx(rs), 10) + pad(m6.toFixed(2), 13) + pad(m6 > 0 ? (rs / m6 * 100).toFixed(1) : '-', 8) + pad(mD.toFixed(2), 15) + pad(mD > 0 ? (rs / mD * 100).toFixed(1) : '-', 9));
  }
  pl.push('csv vs tick mfe60 |diff|>1%p: ' + mWarn + ' stock-days');
  data('capture', pl.concat(mWarnL));

  const kl = ['strategy rank code      days   n      sum'];
  for (const s of strats) {
    const g = {}; for (const t of R[s.id].trs) (g[t.code] = g[t.code] || []).push(t);
    const arr = Object.keys(g).map(k => ({ k, n: g[k].length, d: new Set(g[k].map(x => x.date)).size, sum: g[k].reduce((a, x) => a + x.ret, 0) })).sort((a, b) => b.sum - a.sum);
    const pick = arr.slice(0, 8).map((x, i) => ['top' + (i + 1), x]).concat(arr.slice(-8).map((x, i) => ['bot' + (8 - i), x]));
    for (const [r, x] of pick) kl.push(s.id.padEnd(9) + r.padEnd(6) + x.k.padEnd(9) + pad(x.d, 5) + pad(x.n, 4) + pad(fx(x.sum), 9));
  }
  data('by_code (top/bottom 8)', kl);

  data('probe_v1_mfe', grepFile('strategies/engines/v1.cjs', /mfe|mae/, 25));
  data('probe_guard11_wiring', grepFile('tools/sz-lab-guard11.cjs', /require\(|makeHook|E3\.simulate|runPortfolio|GP0|hooks|G11/, 45).concat(grepFile('tools/sz-guard11.cjs', /module\.exports|function makeHook|VERSION/, 10)));
  if (exL.length) data('excluded (max 20)', exL);

  sums.push('archive files=' + files.length + ' loaded=' + loaded + ' excluded=' + excl + ' noDaily=' + noDaily + ' eligible(>=' + MINW + ')=' + items.length + ' full(>=' + REF + ')=' + full + ' range=' + dates[0] + '~' + dates[dates.length - 1] + ' dates=' + dates.length);
  sums.push(capInfo);
  sums.push('strategies=' + strats.map(s => s.id).join(',') + ' excl=' + EXCL.join(',') + ' timeExitAdj trades(' + strats[0].id + ')=' + adjN);
  try {
    const pg = path.join(ROOT, 'docs', 'progress.md');
    if (fs.existsSync(pg)) fs.appendFileSync(pg, '\n- S4-1 period (' + VER + ') ' + LSTAMP + ': eligible=' + items.length + ' ' + strats.map(s => s.id + '=' + stats(R[s.id].trs).sum.toFixed(2)).join(' ') + ' report=' + RDIR + '\n');
  } catch (e) { sums.push('progress.md append failed: ' + e.message); }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL';
try { verdict = main(); report(verdict); }
catch (e) { verdict = 'FAIL'; try { report('FAIL', e); } catch (e2) { console.log('report write failed: ' + e2.message); } }
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);
'@
if (Test-Path $Js) { Copy-Item $Js "$Js.bak34" -Force }
[System.IO.File]::WriteAllText($Js, $code, $U8)
$chk = & node --check $Js 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail 'node --check s4_period.cjs' $chk }
$na = @($Js, $Root, '--strategies', $Strategies, '--minWarm', "$MinWarm", '--ref', "$Ref")
if ($Excl) { $na += @('--excl', $Excl) }
if ($Csv) { $na += @('--csv', $Csv) }
& node @na
exit $LASTEXITCODE
