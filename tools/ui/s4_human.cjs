'use strict';
// s4_causal.cjs (causal-1.0) - S4-3b first entry AFTER capture only. Read-only on engines and data.
// Engine facts (v1.cjs 25-31, 177): _entS = EntryStart*100 compared with bar hms (HHMMSS); 'time' reject = continue.
// Per stock-day: EntryStart = max(native, capture minute [cap] or capture minute + 1 [next]), MaxTrades = 1.
// Indicators/arming before capture are computed exactly as live. Overlays (target/BE) copied from entryq-1.0.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const VER = 'human-1.0', STEP = 'S4.human';
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

// ---- copied from s4_entryq.cjs ----
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
    const v = { hms, px, amt: num(r[6]), m60: pct(r[14]), r60: pct(r[15]), r60t: (String(r[15] || '').split('@')[1] || '').trim() };
    if (!o || hms < o.hms) m.set(k, v);
  }
  return { m, rows: rows.length - 1, bad, stat };
}
// ---- end copy ----

function main() {
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  const MINW = Number(A('minWarm') || 400), EXCL = new Set(list(A('excl') || '20261021,20261028'));
  const XN = (A('expect') || '87.90:96.53:177:-59.45').split(':').map(Number);
  const E = require(path.join(ROOT, 'tools', 'ui', 'engines.cjs'));
  engVer = E.VERSION;
  const vr = E.verify(ROOT);
  if (!ok('engine hash gate (' + E.VERSION + ')', vr && vr.ok, 'missing=' + JSON.stringify(vr && vr.missing))) return 'FAIL';
  const LD = E.load(ROOT), V1 = LD.V1, RK = LD.R;
  if (!ok('V1 api prep/compute/simulate', V1 && ['prep', 'compute', 'simulate'].every(k => typeof V1[k] === 'function'), Object.keys(V1 || {}).join(','))) return 'FAIL';
  const TS = RK && typeof RK.tickSize === 'function' ? p => RK.tickSize(p) : null;
  if (!ok('risk1 tickSize()', TS && [1500, 3000, 15000, 30000].every(p => TS(p) > 0), TS ? 'ok' : 'R.tickSize missing')) return 'FAIL';

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

  const capF = findCapCsv(); let cap = new Map();
  if (!ok('capture csv found', !!capF, 'pass -Csv')) return 'FAIL';
  { const c = loadCap(capF); cap = c.m; sums.push('capture csv=' + capF + ' rows=' + c.rows + ' bad=' + c.bad + ' stockDays=' + cap.size); }

  const files = fs.readdirSync(restT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort();
  const items = []; let excl = 0;
  for (const f of files) { let it; try { it = loadItem(restT, restD, f); } catch (e) { excl++; continue; } if (it.start >= MINW) items.push(it); }
  items.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : (a.code < b.code ? -1 : 1));
  if (!ok('eligible stock-days >= 1', items.length > 0, 'eligible=' + items.length)) return 'FAIL';
  const dates = [...new Set(items.map(x => x.date))].sort(), HA = new Set(dates.slice(0, Math.ceil(dates.length / 2)));
  for (const it of items) { it.cD = dayClose(restD, it.code, it.date); it.cp = cap.get(it.code + '|' + it.date) || null; }
  const capHist = {}; for (const it of items) if (it.cp) { const k = String(it.cp.hms); capHist[k] = (capHist[k] || 0) + 1; }
  sums.push('eligible=' + items.length + ' withCapture=' + items.filter(x => x.cp).length + ' capSec!=0:' + items.filter(x => x.cp && x.cp.hms % 100).length +
    ' dates=' + dates.length + ' A=' + dates[0] + '~' + [...HA].pop() + ' excl=' + [...EXCL].join('/'));
  sums.push('capture hms histogram (top 8): ' + Object.entries(capHist).sort((a, b) => b[1] - a[1]).slice(0, 8).map(e => e[0] + ':' + e[1]).join(' '));

  const tgtPx = (entry, T) => { const raw = entry * (1 + T / 100), ts = TS(raw); return Math.ceil(raw / ts - 1e-9) * ts; };
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
  const KEY = (T, X) => String(T) + '|' + String(X), K0 = KEY(null, null), K15 = KEY(1.5, null), KB1 = KEY(null, 1);
  const XS = [null, 0.75, 1, 1.5, 2], TL = [null, 1.5];
  const SHOW = [[null, null], [null, 1], [null, 2], [1.5, null]];
  const hh = hms => Math.floor(hms / 100);
  const nextMin = x => { let h = Math.floor(x / 100), m = x % 100 + 1; if (m >= 60) { h++; m -= 60; } return h * 100 + m; };
  const VARS = [
    { id: 'cap', es: hms => hms % 100 ? nextMin(hh(hms)) : hh(hms) },
    { id: 'next', es: hms => nextMin(hh(hms)) }];
  const BK = [['chase', [-1, 0, 1, 2, 3, 5]], ['delay', [1, 5, 15, 30, 60, 120]], ['rise', [5, 10, 15, 20, 25]], ['openGap', [0, 2, 5, 10]],
    ['prevChg', [0, 5, 10, 20]], ['capRise', [5, 7, 10, 15, 20, 25]], ['capAmt', [500, 1000, 2000, 5000, 10000]], ['inHms', [91000, 91500, 93000, 100000, 110000, 130000]]];
  const FL = [['none', null, 0, [null]], ['chaseMax', 'chase', 1, [0, 0.5, 1, 2, 3]], ['delayMax', 'delay', 1, [5, 15, 30, 60]], ['riseMax', 'rise', 1, [10, 15, 20]],
    ['openGapMax', 'openGap', 1, [2, 5, 10]], ['capRiseMax', 'capRise', 1, [10, 15, 20, 25]], ['capRiseMin', 'capRise', -1, [5, 7, 10]],
    ['capAmtMin', 'capAmt', -1, [500, 1000, 2000, 5000]], ['inHmsMax', 'inHms', 1, [91500, 93000, 100000, 110000]]];
  const labsOf = e => { const L = []; for (let k = 0; k <= e.length; k++) L.push(k === 0 ? '<' + e[0] : k === e.length ? '>=' + e[k - 1] : e[k - 1] + '~' + e[k]); L.push('n/a'); return L; };
  const bOf = (v, e) => { if (!isFinite(v)) return 'n/a'; let k = 0; while (k < e.length && v >= e[k]) k++; return k === 0 ? '<' + e[0] : k === e.length ? '>=' + e[k - 1] : e[k - 1] + '~' + e[k]; };

  const mkRow = (it, t, FEE) => {
    const capT = it.cp ? toT(it.date, it.cp.hms) : null, bi = it.bars[t.inI];
    const r = { it, t, code: it.code, date: it.date, half: HA.has(it.date) ? 'A' : 'B', inHms: bi.hms,
      chase: it.cp ? (t.inPx / it.cp.px - 1) * 100 : NaN, delay: it.cp ? (bi.t - capT) / 60 : NaN,
      rise: it.dly ? (t.inPx / it.dly.c - 1) * 100 : NaN, openGap: it.dly ? (it.bars[it.start].o / it.dly.c - 1) * 100 : NaN,
      prevChg: it.dly ? it.dly.chg : NaN, capRise: it.cp && it.dly ? (it.cp.px / it.dly.c - 1) * 100 : NaN, capAmt: it.cp ? it.cp.amt : NaN, R: {} };
    for (const T of TL) for (const X of XS) {
      const o = (T == null && X == null) ? null : sim(it, t, T, X, 'through', FEE);
      if (o) { const ret = (o.px / t.inPx - 1) * 100 - FEE; r.R[KEY(T, X)] = { ret, adj: ret, why: o.why }; }
      else r.R[KEY(T, X)] = { ret: t.ret, adj: adjRet(it, t), why: '' };
    }
    return r;
  };
  const agg = (sel, key) => {
    const trs = []; let sumA = 0, Aa = 0, Bb = 0, xx = 0, lossD = 0, worst = 0, tg = 0, be = 0;
    for (const r of sel) {
      const z = r.R[key]; trs.push({ ret: z.ret, mfe: r.t.mfe }); sumA += z.adj;
      if (r.half === 'A') Aa += z.adj; else Bb += z.adj; if (!EXCL.has(r.date)) xx += z.adj;
      if (z.adj < 0) lossD++; if (z.adj < worst) worst = z.adj; if (z.why === 'tgt') tg++; if (z.why === 'be') be++;
    }
    return Object.assign(stats(trs), { sumA, A: Aa, B: Bb, x: xx, lossD, worst, tg, be });
  };
  const SH = 'filter          th     T    BE    n  skip  win%  sumAdj   A_adj   B_adj   xExcl    PF    MDD loss%  worstD  tgt%   be%  nb';
  const scL = z => z.fn.padEnd(11) + pad(z.th == null ? '-' : z.th, 7) + pad(z.T == null ? 'off' : z.T, 6) + pad(z.X == null ? 'off' : z.X, 6) + pad(z.a.n, 5) + pad(z.skip, 6) +
    pad(z.a.n ? (z.a.w / z.a.n * 100).toFixed(1) : '-', 6) + pad(fx(z.a.sumA), 8) + pad(fx(z.a.A), 8) + pad(fx(z.a.B), 8) + pad(fx(z.a.x), 8) +
    pad(z.a.pf.toFixed(2), 6) + pad(z.a.mdd.toFixed(1), 7) + pad(z.a.n ? (z.a.lossD / z.a.n * 100).toFixed(1) : '-', 6) + pad(fx(z.a.worst), 8) +
    pad(z.a.n ? (z.a.tg / z.a.n * 100).toFixed(1) : '-', 6) + pad(z.a.n ? (z.a.be / z.a.n * 100).toFixed(1) : '-', 6) + pad(z.nbOk + '/' + z.nbN, 5);

  { // ================= S4-3d human pattern section (human-1.0) =================
  // Pre-registered human "do-not-enter" patterns on S4-3b 'cap' trades. Tags only; frozen engine untouched.
  const SS = strats.find(x => x.id === B.id);
  if (!ok('baseline in strategies', !!SS, 'strats=' + strats.map(x => x.id).join(','))) return 'FAIL';
  const P0 = SS.params, FEE = P0.FeePct, GAP = 3;
  const natES = V1.prep(Object.assign({}, P0, { Date: '', TickScope: 120 }))._entS / 100;
  const capV = VARS.find(v => v.id === 'cap');
  const adj = r => r.R[K0].adj, sumA = a => a.reduce((s, r) => s + adj(r), 0);
  const med = a => { const v = a.filter(x => isFinite(x)).sort((x, y) => x - y); return v.length ? (v.length % 2 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2) : NaN; };
  const rows = [];
  for (const it of items) {
    if (!it.cp) continue;
    const es = Math.max(natES, capV.es(it.cp.hms));
    const rr = run(it, it.bars, it.start, Object.assign({}, P0, { EntryStart: es, MaxTrades: 1 }));
    if (!rr.r.trades.length) continue;
    const r = mkRow(it, rr.r.trades[0], FEE); r.es = es; r.rr = rr.r; r.ind = rr.ind; rows.push(r);
  }
  const a0 = agg(rows, K0);
  if (!ok('repro S4-3b cap S000 (382 / -106.50)', rows.length === 382 && a0.sumA.toFixed(2) === '-106.50', 'got ' + rows.length + ' ' + a0.sumA.toFixed(2))) return 'FAIL';
  if (!ok('indicator arrays from run()', rows.every(r => r.ind && r.ind.mom && r.rr.marks), '')) return 'FAIL';

  const dC = {};
  const dailyRows = code => {
    if (dC[code]) return dC[code]; let out = [];
    try {
      const L = fs.readFileSync(path.join(restD, code + '.csv'), 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/).filter(x => x.trim());
      const h = L[0].split(','), id = h.indexOf('date'), ic = h.indexOf('close');
      if (id >= 0 && ic >= 0) out = L.slice(1).map(x => x.split(',')).map(c => ({ d: c[id], c: Math.abs(Number(c[ic])) })).filter(x => /^\d{8}$/.test(x.d) && x.c > 0).sort((a, b) => a.d < b.d ? -1 : 1);
    } catch (e) { }
    return (dC[code] = out);
  };
  const closeNBack = (code, date, n) => { const p = dailyRows(code).filter(x => x.d < date); return p.length >= n ? p[p.length - n].c : NaN; };
  const m80 = (b, i) => i >= 80 && b[i - 80].c > 0 ? b[i].c / b[i - 80].c * 100 : NaN;

  for (const r of rows) {
    const it = r.it, b = it.bars, s = it.start, iI = r.t.inI, px = r.t.inPx;
    const sg = r.rr.marks.filter(m => (m.k === 'rej' || m.k === 'entry') && m.i >= s && m.i <= iI).map(m => m.i).sort((x, y) => x - y);
    let cl = 0, last = -1e9; for (const i of sg) { if (i - last > GAP) cl++; last = i; }
    r.sigN = sg.length; r.clN = cl; r.fsI = sg.length ? sg[0] : -1;
    r.drift = r.fsI >= 0 ? (px / b[r.fsI].c - 1) * 100 : NaN;
    r.momS = r.ind.mom[iI] == null ? NaN : r.ind.mom[iI]; r.mom80 = m80(b, iI);
    let hi = b[s].h, pb = 0; for (let j = s + 1; j <= iI; j++) { pb = Math.max(pb, (hi - b[j].l) / hi * 100); if (b[j].h > hi) hi = b[j].h; }
    r.runUp = (px / b[s].o - 1) * 100; r.maxPb = pb;
    let ph = -Infinity, phI = -1; for (let j = s; j < iI; j++) if (b[j].h >= ph) { ph = b[j].h; phI = j; }
    r.phI = phI; r.offHigh = phI >= 0 ? (1 - px / ph) * 100 : NaN; r.minHigh = phI >= 0 ? (b[iI].t - b[phI].t) / 60 : NaN;
    let k2 = 0; for (let j = s; j <= iI; j++) if (b[j].o > 0 && (b[j].c / b[j].o - 1) * 100 >= 2) k2++; r.big2 = k2;
    const c3 = closeNBack(it.code, it.date, 3); r.rise3 = c3 > 0 ? (px / c3 - 1) * 100 : NaN;
    r.nxt = b[s].hms < 90000;
    let kI = s; while (kI < b.length && b[kI].d === it.date && b[kI].hms < 90000) kI++;
    r.gapK = it.dly && kI < b.length && b[kI].d === it.date ? (b[kI].o / it.dly.c - 1) * 100 : NaN;
    r.gapF = it.dly ? (b[s].o / it.dly.c - 1) * 100 : NaN;
  }

  const RULES = [
    ['X1', 'run-up from first bar open >= th% with no 2% pullback', (r, v) => r.runUp >= v && r.maxPb < 2, 5, [3, 7]],
    ['X2', 'entry signal cluster no. > th (gap<=' + GAP + ' bars)', (r, v) => r.clN > v, 1, [2]],
    ['X2b', 'entry > th% above first signal close', (r, v) => r.drift > v, 2, [1, 3]],
    ['X3s', 'Mom(' + P0.MomLen + ') at entry >= th', (r, v) => r.momS >= v, 110, [105, 115]],
    ['X3m80', 'Mom(80) at entry >= th', (r, v) => r.mom80 >= v, 110, [105, 115]],
    ['X4', 'today bars with body >= +2% count >= th', (r, v) => r.big2 >= v, 3, [2, 4]],
    ['X5', 'entry vs close 3 trading days ago >= th%', (r, v) => r.rise3 >= v, 20, [15, 25]],
    ['H1', 'entry >= th% below prior day high, high >= 5 min old', (r, v) => r.offHigh >= v && r.minHigh >= 5, 1, [0.5, 1.5]],
    ['H3', 'chase vs capture px >= th%', (r, v) => r.chase >= v, 3, [2, 5]],
    ['H4k', 'gap at KRX open >= th%', (r, v) => r.gapK >= v, 5, [3, 10]],
    ['H4f', 'gap at first bar open (NXT 08:00) >= th%', (r, v) => r.gapF >= v, 5, [3, 10]]];
  const dayWorst = sel => { const m = {}; for (const r of sel) m[r.date] = (m[r.date] || 0) + adj(r); const v = Object.values(m); return v.length ? Math.min(...v) : 0; };
  const ev = (fn, v) => {
    const blk = rows.filter(r => fn(r, v)), sel = rows.filter(r => !fn(r, v)), a = agg(sel, K0), bl = blk.filter(r => adj(r) < 0), bw = blk.filter(r => adj(r) >= 0);
    return { v, blk, nB: blk.length, nL: bl.length, sL: sumA(bl), nW: bw.length, sW: sumA(bw), net: a.sumA - a0.sumA, dA: a.A - a0.A, dB: a.B - a0.B, a, wd: dayWorst(sel) };
  };
  const good = e => e.dA > 0 && e.dB > 0;
  const line = (id, e, tag) => id.padEnd(6) + pad(e.v, 5) + pad(e.nB, 6) + pad(e.nL, 6) + pad(fx(e.sL), 9) + pad(e.nW, 5) + pad(fx(e.sW), 9) + pad(fx(e.net), 9) + pad(fx(e.dA), 8) + pad(fx(e.dB), 8) +
    pad(e.a.n, 5) + pad(fx(e.a.sumA), 9) + pad(isFinite(e.a.pf) ? e.a.pf.toFixed(2) : '-', 6) + pad(e.a.n ? (e.a.lossD / e.a.n * 100).toFixed(1) : '-', 7) + pad(fx(e.wd), 9) + '  ' + tag;
  const RH = 'rule     th   blk lossN  lossSum winN   winSum      net      dA      dB    n   sumAdj    PF  loss%  worstD  verdict';
  const rl = [RH], RES = [];
  for (const [id, desc, fn, base, nbs] of RULES) {
    const eb = ev(fn, base), en = nbs.map(v => ev(fn, v));
    const pass = good(eb) && eb.nB >= 10 && en.every(good);
    const vd = pass ? 'PASS' : (eb.nB < 10 ? 'FEW' : (!good(eb) ? 'BASE' : 'NEIGHBOR'));
    RES.push({ id, desc, fn, base, eb, pass, vd });
    rl.push(line(id, eb, vd + '  ' + desc)); for (const e of en) rl.push(line('', e, 'nb'));
  }
  for (const r of rows) r.tags = RES.filter(z => z.fn(r, z.base)).map(z => z.id);
  const PSET = new Set(RES.filter(z => z.pass).map(z => z.id));
  rl.push(line('ANY', ev(r => r.tags.length > 0, '-'), 'info: union of all rules (not a verdict)'));
  rl.push(line('PASSU', ev(r => r.tags.some(x => PSET.has(x)), '-'), 'info: union of PASS rules=' + ([...PSET].join('|') || 'none')));
  data('S000 cap human rules (base n=' + a0.n + ' adj=' + fx(a0.sumA) + ' A=' + fx(a0.A) + ' B=' + fx(a0.B) + ' worstDay=' + fx(dayWorst(rows)) + '; pass = dA>0,dB>0 at base & neighbors, blk>=10)', rl);

  const losses = rows.filter(r => adj(r) < 0), wins = rows.filter(r => adj(r) >= 0), unexp = losses.filter(r => !r.tags.length);
  const FK = ['clN', 'sigN', 'drift', 'momS', 'mom80', 'runUp', 'maxPb', 'offHigh', 'minHigh', 'big2', 'rise3', 'chase', 'gapK', 'gapF', 'delay'];
  const fl = ['feature   med_loss  med_win   (n loss=' + losses.length + ' win=' + wins.length + ')'];
  for (const f of FK) fl.push(f.padEnd(9) + pad(f2(med(losses.map(r => r[f]))), 10) + pad(f2(med(wins.map(r => r[f]))), 10));
  data('feature medians loss vs win (entry-time values)', fl);
  const tl = ['tags  lossN  lossSum  winN   winSum'];
  for (let n = 0; n <= 6; n++) { const L = losses.filter(r => Math.min(r.tags.length, 6) === n), W = wins.filter(r => Math.min(r.tags.length, 6) === n); if (L.length || W.length) tl.push(pad(n === 6 ? '6+' : n, 4) + pad(L.length, 7) + pad(fx(sumA(L)), 9) + pad(W.length, 6) + pad(fx(sumA(W)), 9)); }
  data('tag count distribution (unexplained losses = tags 0: n=' + unexp.length + ' sum=' + fx(sumA(unexp)) + ')', tl);

  const z9 = rows.find(r => r.code === '0009K0' && r.date === '20261021');
  if (z9) {
    const it = z9.it, b = it.bars, nat = run(it, b, it.start, P0);
    const L = ['src  time        close  kind   why     momS   mom80          n  big'];
    for (const [src, R, ind] of [['cap', z9.rr, z9.ind], ['nat', nat.r, nat.ind]]) for (const m of R.marks) {
      if (m.i < it.start || m.k === 'exit') continue; const q = b[m.i];
      L.push(src + '  ' + String(q.hms).padStart(6, '0') + pad(q.c, 10) + '  ' + m.k.padEnd(6) + ' ' + String(m.why || '').padEnd(6) + pad(f2(ind.mom[m.i]), 8) + pad(f2(m80(b, m.i)), 8) + pad(f2(ind.n[m.i]), 11) + pad(ind.big[m.i] ? 1 : 0, 4));
    }
    data('HTS check 0009K0 20261021 engine marks (arm/rej/entry) from day start; compare with HTS arrows 08:00:03, 08:06:03, 09:00', L);
  } else sums.push('0009K0 20261021 not in cap rows');
  const ul = ['code   date     in        adj    mfe  why            clN drift  momS mom80 runUp offHi  big2 rise3 chase'];
  for (const r of unexp.slice().sort((x, y) => adj(x) - adj(y)).slice(0, 60))
    ul.push(r.code.padEnd(6) + ' ' + r.date + ' ' + String(r.inHms).padStart(6, '0') + pad(fx(adj(r)), 8) + pad(f2(r.t.mfe), 6) + '  ' + String(r.t.why).padEnd(14) + pad(r.clN, 3) +
      pad(f2(r.drift), 6) + pad(f2(r.momS), 6) + pad(f2(r.mom80), 6) + pad(f2(r.runUp), 6) + pad(f2(r.offHigh), 6) + pad(r.big2, 5) + pad(f2(r.rise3), 6) + pad(f2(r.chase), 6));
  data('unexplained losses (no tag), worst 60', ul);

  const used = new Set(), cases = [], kk = r => r.code + '_' + r.date;
  const take = (cat, list, n) => { let c = 0; for (const r of list) { if (c >= n) break; if (used.has(kk(r))) continue; used.add(kk(r)); cases.push({ cat, r }); c++; } };
  const byAdj = a => a.slice().sort((x, y) => adj(x) - adj(y));
  take('U_unexplained', byAdj(unexp), 60);
  for (const z of RES) { take(z.id + '_blkLoss', byAdj(z.eb.blk.filter(r => adj(r) < 0)), 3); take(z.id + '_blkWin', byAdj(z.eb.blk.filter(r => adj(r) >= 0)).reverse(), 3); }

  const STY = '<style>body{background:#111;color:#ddd;font:13px sans-serif;margin:8px}a{color:#6cf}table{border-collapse:collapse;margin:6px 0}td,th{border:1px solid #333;padding:2px 6px;text-align:right}th{background:#222}.up{color:#ff6b6b}.dn{color:#5cc8ff}pre{font:12px monospace}#tip{position:absolute;display:none;pointer-events:none;background:rgba(0,0,0,.88);border:1px solid #555;padding:6px 8px;font:12px sans-serif;line-height:1.45}</style>';
  const ANCH = "        else if (m.k === 'rej') cross(x, y(D.h[m.i]) - 8, 4, REJ[m.why] || '#fff');\n      });\n";
  const rbuf = fs.readFileSync(path.join(ROOT, 'tools', 'sz-render.js')), rsrc = rbuf.toString('utf8').replace(/\r\n/g, '\n');
  const nA = rsrc.split(ANCH).length - 1;
  if (!ok('sz-render.js overlay anchor unique', nA === 1, 'count=' + nA + ' sha12=' + sha(rbuf).slice(0, 12))) return 'FAIL';
  const OVL = [
    "      if (D.ov) {",
    "        var O = D.ov, vl = function (ii, col, txt, dy) { if (ii == null || ii < v0 || ii >= v1) return; g.strokeStyle = col; g.setLineDash([3, 3]); g.beginPath(); g.moveTo(X(ii), p.y); g.lineTo(X(ii), p.y + p.h); g.stroke(); g.setLineDash([]); g.fillStyle = col; g.font = '11px sans-serif'; g.textAlign = 'left'; g.fillText(txt, X(ii) + 3, p.y + dy); };",
    "        vl(O.capI, '#ffffff', 'CAP ' + O.capTxt, 28); vl(O.esI, '#ffdd00', 'ES ' + O.esTxt, 42);",
    "        (O.stops || []).forEach(function (q) { var a = Math.max(q.a, v0), b = Math.min(q.b, v1 - 1); if (a > b) return; g.strokeStyle = '#ff3333'; g.setLineDash([6, 3]); g.beginPath(); g.moveTo(X(a), y(q.px)); g.lineTo(X(b), y(q.px)); g.stroke(); g.setLineDash([]); g.fillStyle = '#ff6666'; g.font = '10px sans-serif'; g.textAlign = 'left'; g.fillText('stop ' + q.px.toFixed(0), X(a) + 2, y(q.px) + 11); });",
    "        g.font = '10px sans-serif'; g.textAlign = 'center';",
    "        D.marks.forEach(function (m) { if (m.i < v0 || m.i >= v1) return; if (m.k === 'rej' && m.why !== 'time') { g.fillStyle = REJ[m.why] || '#fff'; g.fillText(m.why, X(m.i), y(D.h[m.i]) - 15); } else if (m.k === 'exit') { g.fillStyle = '#ffcc66'; g.fillText(m.why, X(m.i), y(D.h[m.i]) - 36); } });",
    "      }"].join('\n') + '\n';
  const RENDER = rsrc.replace(ANCH, ANCH + OVL);

  const outDir = path.join(ROOT, 'out', 'charts', 'S4-3d'); fs.mkdirSync(outDir, { recursive: true });
  const tm = h => { const s = String(h).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };
  const g2 = (x, d) => x == null || !isFinite(x) ? '-' : Number(x).toFixed(d);
  const firstIdx = (it, hms) => { for (let j = it.start; j < it.bars.length; j++) if (it.bars[j].d === it.date && it.bars[j].hms >= hms) return j; return null; };
  const HH = 'case cat              code   date     bar   time           O        H        L        C     momS    mom80          n        sig safe big';
  const idxR = [], fmap = {};
  cases.forEach((cs, k) => {
    const r = cs.r, it = r.it, bars = it.bars, R1 = r.rr, ind = r.ind, t = r.t, v0 = Math.max(0, it.start - 300);
    const Pp = V1.prep(Object.assign({}, P0, { EntryStart: r.es, MaxTrades: 1, Date: '', TickScope: 120 }));
    const A_ = a => Array.from(a).slice(v0);
    const rd = (a, d) => Array.from(a).slice(v0).map(x => x == null || !isFinite(x) ? null : +Number(x).toFixed(d));
    const capI = firstIdx(it, it.cp.hms), esI = firstIdx(it, r.es * 100);
    const D = {
      o: A_(bars.map(b => b.o)), h: A_(bars.map(b => b.h)), l: A_(bars.map(b => b.l)), c: A_(bars.map(b => b.c)), hms: A_(bars.map(b => b.hms)),
      mom: rd(ind.mom, 3), n: rd(ind.n, 5), sig: rd(ind.sig, 5), ema: rd(ind.ema, 1), st: rd(ind.st, 1), stDir: A_(ind.stDir),
      amt: rd(ind.amt, 0), taamt: rd(ind.taamt, 0), big: A_(ind.big), cnt1: A_(ind.cnt1), thr: rd(ind.thr, 0), tickOk: A_(ind.tickOk),
      disp: rd(ind.disp, 2), safe: A_(ind.safe),
      trades: R1.trades.map(x => Object.assign({}, x, { inI: x.inI - v0, outI: x.outI - v0 })),
      marks: R1.marks.filter(m => m.i >= v0).map(m => Object.assign({}, m, { i: m.i - v0 })),
      emaLen: Pp.EmaLen, momLen: Pp.MomLen, safeTh: Pp.SafeTh, bigMode: Pp.BigMode, tickK: Pp.TickK,
      ov: { capI: capI == null ? null : capI - v0, capTxt: tm(it.cp.hms) + ' ' + it.cp.px, esI: esI == null ? null : esI - v0, esTxt: String(r.es),
        stops: R1.trades.map(x => ({ a: x.inI - v0, b: x.outI - v0, px: x.inPx * (1 - P0.StopPct / 100) })) } };
    const pg = [HH];
    const hl = (lab, j) => {
      if (j == null || j < 0 || j >= bars.length) return; const b = bars[j];
      pg.push(pad(k + 1, 4) + ' ' + cs.cat.padEnd(16) + ' ' + it.code.padEnd(6) + ' ' + it.date + ' ' + lab.padEnd(5) + ' ' + tm(b.hms) + pad(b.o, 9) + pad(b.h, 9) + pad(b.l, 9) + pad(b.c, 9) +
        pad(g2(ind.mom[j], 2), 9) + pad(g2(m80(bars, j), 2), 9) + pad(g2(ind.n[j], 5), 11) + pad(g2(ind.sig[j], 5), 11) + pad(ind.safe[j] ? 1 : 0, 5) + pad(ind.big[j] ? 1 : 0, 4));
    };
    hl('sig1', r.fsI); hl('cap', capI); hl('high', r.phI); hl('in-1', t.inI - 1); hl('in', t.inI); hl('out', t.outI);
    const fn = 'h' + String(k + 1).padStart(3, '0') + '_' + it.code + '_' + it.date + '.html'; fmap[kk(r)] = fn;
    const info = [['category', cs.cat], ['code date', it.code + ' ' + it.date], ['tags', r.tags.join(' ') || '-'], ['capture', tm(it.cp.hms) + ' ' + it.cp.px], ['ES', r.es],
      ['entry', tm(bars[t.inI].hms) + ' ' + t.inPx], ['exit', tm(bars[t.outI].hms) + ' ' + g2(t.outPx, 1) + ' ' + t.why], ['adj', fx(adj(r))], ['mfe/mae', fx(t.mfe) + ' / ' + fx(t.mae)],
      ['sig/cluster', r.sigN + ' / ' + r.clN], ['sig1', r.fsI >= 0 ? tm(bars[r.fsI].hms) + ' ' + bars[r.fsI].c : '-'], ['drift', fx(r.drift)], ['momS/m80', g2(r.momS, 1) + ' / ' + g2(r.mom80, 1)],
      ['runUp/maxPb', fx(r.runUp) + ' / ' + g2(r.maxPb, 2)], ['offHigh/min', g2(r.offHigh, 2) + ' / ' + g2(r.minHigh, 1)], ['big2', r.big2], ['rise3', fx(r.rise3)], ['chase', fx(r.chase)],
      ['gapK/gapF', fx(r.gapK) + ' / ' + fx(r.gapF)], ['NXT', r.nxt ? 'Y' : 'N']];
    let tb = '<table>'; for (let q = 0; q < info.length; q += 10) { const s = info.slice(q, q + 10); tb += '<tr>' + s.map(x => '<th>' + x[0] + '</th>').join('') + '</tr><tr>' + s.map(x => '<td>' + x[1] + '</td>').join('') + '</tr>'; } tb += '</table>';
    const html = '<!doctype html><html><head><meta charset="utf-8"><title>' + (k + 1) + ' ' + cs.cat + ' ' + it.code + ' ' + it.date + '</title>' + STY + '</head><body>' +
      '<a href="index.html">index</a> &nbsp; <b>#' + (k + 1) + ' ' + cs.cat + '</b>' + tb +
      '<canvas id="cv" style="width:100%;height:80vh;display:block"></canvas><div id="tip"></div><pre>' + pg.join('\n') + '</pre>' +
      '<script>window.SZDATA=' + JSON.stringify(D) + ';</script><script>' + RENDER + '</script></body></html>';
    fs.writeFileSync(path.join(outDir, fn), html, 'utf8');
    idxR.push('<tr><td>' + (k + 1) + '</td><td>' + cs.cat + '</td><td><a href="' + fn + '">' + it.code + '</a></td><td>' + it.date + '</td><td>' + tm(bars[t.inI].hms) + '</td><td>' + t.why +
      '</td><td class="' + (adj(r) > 0 ? 'up' : 'dn') + '">' + fx(adj(r)) + '</td><td>' + fx(t.mfe) + '</td><td>' + (r.tags.join(' ') || '-') + '</td></tr>');
  });
  fs.writeFileSync(path.join(outDir, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><title>S4-3d human patterns</title>' + STY + '</head><body><h3>S4-3d S000 cap n=' + rows.length + ' adj=' + fx(a0.sumA) +
    '</h3><pre>' + rl.join('\n') + '\n\n' + fl.join('\n') + '\n\n' + tl.join('\n') + '</pre><table><tr><th>#</th><th>cat</th><th>code</th><th>date</th><th>in</th><th>why</th><th>adj</th><th>mfe</th><th>tags</th></tr>' + idxR.join('') + '</table></body></html>', 'utf8');

  const hdir = path.join(ROOT, 'out', 'human'); fs.mkdirSync(hdir, { recursive: true });
  const rf = path.join(hdir, 'review.csv'), prev = {}; let kept = 0;
  if (fs.existsSync(rf)) {
    for (const ln of fs.readFileSync(rf, 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/).slice(1)) {
      if (!ln.trim()) continue; const c = ln.split(','); prev[c[0] + '|' + c[1]] = { h: c[8] || '', why: c.slice(9).join(',') };
    }
    fs.copyFileSync(rf, rf + '.bak39');
  }
  const rv = ['code,date,inHms,adj,mfe,exit,tags,chart,human,reason'];
  const ord = rows.slice().sort((x, y) => ((adj(x) < 0 && !x.tags.length) ? 0 : adj(x) < 0 ? 1 : 2) - ((adj(y) < 0 && !y.tags.length) ? 0 : adj(y) < 0 ? 1 : 2) || adj(x) - adj(y));
  for (const r of ord) { const p = prev[r.code + '|' + r.date]; if (p && (p.h || p.why)) kept++;
    rv.push([r.code, r.date, r.inHms, f4(adj(r)), f4(r.t.mfe), r.t.why, r.tags.join('|'), fmap[kk(r)] || '', p ? p.h : '', p ? p.why : ''].join(',')); }
  fs.writeFileSync(rf, '\uFEFF' + rv.join('\r\n') + '\r\n', 'utf8');
  const fc = ['code,date,half,inHms,adj,mfe,why,tags,sigN,clN,drift,momS,mom80,runUp,maxPb,offHigh,minHigh,big2,rise3,chase,gapK,gapF,nxt'];
  for (const r of rows) fc.push([r.code, r.date, r.half, r.inHms, f4(adj(r)), f4(r.t.mfe), r.t.why, r.tags.join('|'), r.sigN, r.clN, f4(r.drift), f4(r.momS), f4(r.mom80), f4(r.runUp), f4(r.maxPb), f4(r.offHigh), f4(r.minHigh), r.big2, f4(r.rise3), f4(r.chase), f4(r.gapK), f4(r.gapF), r.nxt ? 1 : 0].join(','));
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  fs.writeFileSync(path.join(RDIR, 'detail', 'human_rows.csv'), fc.join('\n') + '\n');
  sums.push('charts=' + path.join(outDir, 'index.html') + ' cases=' + cases.length + ' review=' + rf + ' rows=' + rows.length + ' keptLabels=' + kept + ' unexplainedLoss=' + unexp.length + ' momLen=' + P0.MomLen + ' render.sha12=' + sha(rbuf).slice(0, 12));
  }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL', err = null;
try { verdict = main(); } catch (e) { err = e; verdict = 'FAIL'; }
report(verdict, err);
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);