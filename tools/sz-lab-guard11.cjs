'use strict';
// sz-lab-guard11.cjs - PatternGuard lab for guard-1.1 (indep mode).
// Read-only: hash-checked v1/v3/risk1, guard-1.0 (parity only), guard-1.1.
// Preflight (abort on failure): synthetic selftest, guard-1.0 vs 1.1 gate parity on every guard-1.0 profile (real data),
//   causality by truncation (new profiles), v1 vs E3+GP000 trades, lab3-indep vs simulate.
// Diagnostics only (never used in delta): exits stamped after ExitTime are flagged art;
//   ret_prev = refill at close of last bar <= ExitTime, ret_krx = refill at KRX daily close (closing auction).
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const ROOT = process.argv[2];
const A = k => { const i = process.argv.indexOf('--' + k); return i > 2 && i + 1 < process.argv.length ? process.argv[i + 1] : ''; };
function die(m) { console.log('FAIL: ' + m); process.exit(1); }
if (!ROOT) die('usage: node sz-lab-guard11.cjs <root> [--strategies S000,C013] [--risk RP000,RP001] [--guards GP000,GP020]');
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const readJson = f => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const list = s => String(s == null ? '' : s).split(',').map(x => x.trim()).filter(Boolean);
const SD = path.join(ROOT, 'strategies'), ENG = path.join(SD, 'engines'), FRZ = path.join(SD, 'frozen');
const CAND = path.join(SD, 'candidates'), SURV = path.join(SD, 'survivors'), RISK = path.join(SD, 'risk');
const GDIR0 = path.join(SD, 'guard'), GDIR = path.join(SD, 'guard11');
const MAN = path.join(SD, 'manifest.json'), OUT = path.join(ROOT, 'out', 'guard11');
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
function loadGuard(dir, file, ver) {
  const mf = path.join(dir, 'manifest.json'), f = path.join(ROOT, 'tools', file);
  if (!fs.existsSync(mf) || !fs.existsSync(f)) die('guard not registered: ' + file);
  if (sha(fs.readFileSync(f)) !== readJson(mf).sha256) die('guard hash mismatch: ' + file);
  const g = require(f);
  if (g.VERSION !== ver) die(file + ': VERSION ' + g.VERSION + ' expected ' + ver);
  return g;
}
const G0 = loadGuard(GDIR0, 'sz-guard.cjs', 'guard-1.0'), G = loadGuard(GDIR, 'sz-guard11.cjs', 'guard-1.1');

function cmpGate(a, b, upto) {
  if (upto == null && a.ok.length !== b.ok.length) return 'len ' + a.ok.length + ' vs ' + b.ok.length;
  const n = upto == null ? a.ok.length : upto + 1;
  for (let j = 0; j < n; j++) if (a.ok[j] !== b.ok[j] || a.why[j] !== b.why[j]) return 'bar ' + j + ' ok ' + a.ok[j] + '/' + b.ok[j] + ' why ' + a.why[j] + '/' + b.why[j];
  return null;
}
function selftest() {
  const out = [], t = (n, c, d) => out.push({ n, c: !!c, d: d == null ? '' : String(d) });
  const D = '20261102';
  const mkBars = spec => spec.map((x, k) => { const s = 32400 + k * 10; return { d: D, hms: Math.floor(s / 3600) * 10000 + Math.floor(s % 3600 / 60) * 100 + s % 60, o: x[0], h: x[1], l: x[2], c: x[3], v: 1000 }; });
  const NB = 20, flat = c => [c, c, c, c];
  const bars = mkBars(Array.from({ length: NB }, (_, k) => flat(k < 3 ? 100 : 103)));
  const arr = (n, f) => Array.from({ length: n }, (_, k) => (f(k) ? 1 : 0));
  const mkInd = z => ({ safe: z, stDir: new Array(z.length).fill(1), st: new Array(z.length).fill(50), n: new Array(z.length).fill(0.1), sig: new Array(z.length).fill(0) });
  const safe1 = arr(NB, () => 1), safeEp = arr(NB, k => k !== 10), safeOut = arr(NB, k => k !== 3);
  const all = (g, a, b, v) => { for (let j = a; j <= b; j++) if (g.ok[j] !== v) return false; return true; };
  const ctx = { date: D, prevClose: 100, prevChg: 0 };
  const run = (prof, safe, bs) => G.computeGate(bs || bars, mkInd(safe), ctx, G.load(prof));
  const okS = g => Array.from(g.ok).join('');
  let g = run({ patterns: { G01: { enabled: true, action: 'blockEpisode' } } }, safeEp);
  t('blockEpisode blocks until safe=0', all(g, 0, 2, 1) && all(g, 3, 9, 0) && all(g, 10, NB - 1, 1) && g.why[3] === 'G01_ep', okS(g));
  g = run({ patterns: { G01: { enabled: true, action: 'blockSec' } }, block: { sec: 30 } }, safe1);
  t('blockSec 30s', all(g, 0, 2, 1) && all(g, 3, 5, 0) && all(g, 6, NB - 1, 1) && g.why[3] === 'G01_sec', okS(g));
  g = run({ patterns: { G01: { enabled: true, action: 'rebound' } }, filter: { ignoreOutsideSafe: true } }, safeOut);
  t('ignoreOutsideSafe drops unsafe fire', all(g, 0, NB - 1, 1) && g.diag.ignored === 1, okS(g) + ' ign=' + g.diag.ignored);
  g = run({ patterns: { G01: { enabled: true, action: 'rebound' } } }, safeOut);
  t('filter off keeps unsafe fire', g.ok[3] === 0, okS(g));
  g = run({ patterns: { G01: { enabled: true, action: 'blockSec' }, G02: { enabled: true, action: 'blockEpisode', pct: 2 } }, block: { sec: 30 } }, safeEp);
  t('episode beats sec', g.why[3] === 'G02_ep' && g.ok[7] === 0 && all(g, 10, NB - 1, 1), okS(g) + ' ' + g.why[3]);
  g = run({ patterns: { G01: { enabled: true, action: 'blockDay' } } }, safeEp);
  t('blockDay holds all day', all(g, 3, NB - 1, 0), okS(g));
  const b2 = mkBars([flat(100), flat(106), [107, 110, 107.5, 110]].concat(Array.from({ length: 7 }, () => flat(110))));
  const s2 = arr(10, () => 1), pr2 = { patterns: { G01: { enabled: true, action: 'rebound', pct: 5 } }, rebound: { coolBars: 0, pbPct: 1.5 } };
  g = run(pr2, s2, b2);
  t('pbRef incl: intrabar range counts as pullback (guard-1.0)', g.ok[2] === 0 && g.ok[3] === 1, okS(g));
  g = run(Object.assign({}, pr2, { rebound: { coolBars: 0, pbPct: 1.5, pbRef: 'prior' } }), s2, b2);
  t('pbRef prior: no pullback below prior high -> still blocked', g.ok[3] === 0 && g.ok[9] === 0, okS(g));
  const pr = { patterns: { G01: { enabled: true, action: 'rebound' }, G02: { enabled: true, action: 'rebound', pct: 2 } } };
  const a0 = G0.computeGate(bars, mkInd(safe1), ctx, G0.load(pr)), a1 = G.computeGate(bars, mkInd(safe1), ctx, G.load(pr));
  t('synthetic guard-1.0 profile parity', !cmpGate(a0, a1) && a0.events.length === a1.events.length, cmpGate(a0, a1));
  let th = 0;
  for (const bad of [{ patterns: { G01: { action: 'bogus' } } }, { block: { secs: 1 } }, { filter: { ignoreOutsideSafe: 1 } }, { rebound: { pbRef: 'x' } }]) { try { G.load(bad); } catch (e) { th++; } }
  t('validation rejects bad profiles', th === 4, th);
  t('empty profile is passive', G.isPassive(G.load({})), '');
  return out;
}
const ST = selftest(), stBad = ST.filter(x => !x.c);
for (const x of stBad) console.log('  FAIL ' + x.n + ' :: ' + x.d);
if (stBad.length) die('SELFTEST ' + (ST.length - stBad.length) + '/' + ST.length + ' (guard-1.1)');
console.log('SELFTEST OK ' + ST.length + '/' + ST.length + ' (guard-1.1)');

// ---- copied from sz-lab-guard.cjs ----
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
function dailyClose(code, date) {
  const f = path.join(dailyDir, code + '.csv'); if (!fs.existsSync(f)) return null;
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), h = rows[0].map(x => x.trim().toLowerCase());
  const iD = h.indexOf('date'), iC = h.indexOf('close'); if (iD < 0 || iC < 0) return null;
  for (let r = 1; r < rows.length; r++) if (String(rows[r][iD]).replace(/\D/g, '').slice(0, 8) === date) { const c = Math.abs(num(rows[r][iC])); return c > 0 ? c : null; }
  return null;
}
function dailyHash(code) { const f = path.join(dailyDir, code + '.csv'); return fs.existsSync(f) ? sha(fs.readFileSync(f)).slice(0, 12) : 'none'; }
function adjExit(t, bars, krx, xt) {
  const ob = bars[t.outI];
  if (!(xt > 0) || !(ob.hms > xt)) return null;
  const fee = (t.outPx / t.inPx - 1) * 100 - t.ret, r = px => (px > 0 ? (px / t.inPx - 1) * 100 - fee : null);
  const j = t.outI - 1, pb = j >= t.inI && bars[j].d === ob.d && bars[j].hms <= xt ? bars[j] : null;
  return { prev: pb ? r(pb.c) : null, prevHms: pb ? pb.hms : null, krx: r(krx) };
}

// ---- strategies ----
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

// ---- risk profiles: position.* only ----
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
const gwant = list(A('guards')), guards = [];
for (const f of fs.readdirSync(GDIR).filter(x => /^GP\d+\.json$/.test(x)).sort()) {
  const id = f.replace('.json', '');
  if (gwant.length && gwant.indexOf(id) < 0 && id !== 'GP000') continue;
  guards.push({ id, P: G.load(readJson(path.join(GDIR, f))) });
}
if (!guards.length || guards[0].id !== 'GP000' || !G.isPassive(guards[0].P)) die('GP000 missing or not passive');
const oldGuards = fs.readdirSync(GDIR0).filter(x => /^GP\d+\.json$/.test(x)).sort().map(f => {
  const raw = readJson(path.join(GDIR0, f)); return { id: f.replace('.json', ''), P0: G0.load(raw), P1: G.load(raw) };
});
if (!oldGuards.length) die('no guard-1.0 profiles for parity');

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
    const warn = [], dly = loadDaily2(code, date, warn), krx = dailyClose(code, date);
    for (const w of warn) addNote(f + ': ' + w);
    if (!krx) addNote(f + ': no KRX daily close for ' + date + ' (adjKrx falls back to engine ret)');
    items0.push({ f, code, date, bars, start, scope: m ? Number(m[1]) : 120, dly, krx, fp: f + ':' + sha(buf).slice(0, 16) + ':' + dailyHash(code) });
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
const HDR = ' guard   trades     sum    PF   MDD lossDays worstDay worstTr blocked removed(n/sum) added(n/sum)   delta  art adjPrev  adjKrx';

// ---- run ----
const rep = [], runRows = [], trRows = [];
let parityN = 0, p10N = 0, causN = 0;
for (const s of strats) {
  const items = mkItems(s.params);
  const xr = Number(s.params.ExitTime), xt = xr > 0 && xr < 10000 ? xr * 100 : xr;
  if (!(xt > 0)) addNote(s.id + ': ExitTime not numeric, art diagnostics off');
  for (const og of oldGuards) items.forEach((x, k) => {
    const a = G0.computeGate(x.bars, x.ind, x.ctx, og.P0), b = G.computeGate(x.bars, x.ind, x.ctx, og.P1);
    let m = cmpGate(a, b);
    if (!m && a.events.length !== b.events.length) m = 'events ' + a.events.length + ' vs ' + b.events.length;
    if (!m) for (let e = 0; e < a.events.length; e++) { const u = a.events[e], v = b.events[e]; if (u.pid !== v.pid || u.i !== v.i || u.state !== v.state) { m = 'event#' + e; break; } }
    if (m) die('PARITY guard-1.0 vs 1.1 ' + s.id + ' ' + og.id + ' ' + items0[k].f + ': ' + m);
    p10N++;
  });
  const gates = {};
  for (const g of guards) {
    gates[g.id] = items.map(x => G.computeGate(x.bars, x.ind, x.ctx, g.P));
    gates[g.id].forEach((r, k) => { for (const m of r.diag.missing) addNote(g.id + ' ' + items0[k].f + ': missing ' + m); });
    if (G.isPassive(g.P)) continue;
    items.forEach((x, k) => {
      const full = gates[g.id][k], N = x.bars.length, st = x.ctx.start;
      for (const fr of [0.1, 0.3, 0.5, 0.7, 0.9]) {
        const cut = st + Math.floor((N - 1 - st) * fr), ic = Object.assign({}, x.ind);
        for (const key of ['safe', 'stDir', 'st', 'n', 'sig']) if (x.ind[key]) ic[key] = Array.prototype.slice.call(x.ind[key], 0, cut + 1);
        const m = cmpGate(full, G.computeGate(x.bars.slice(0, cut + 1), ic, x.ctx, g.P), cut);
        if (m) die('CAUSAL ' + s.id + ' ' + g.id + ' ' + items0[k].f + ' cut=' + cut + ': ' + m);
        causN++;
      }
    });
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
    rep.push('', '== ' + s.id + ' x ' + rp.id + ' (risk on=[' + rp.on.join(' ') + '], ExitTime ' + xt + ') ==');
    rep.push(HDR);
    for (const g of guards) {
      const res = g.id === 'GP000' ? base : items.map((x, k) => E3.simulate(x.bars, x.ind, x.P, x.ctx, rp.P, hook(g.id, k)));
      const per = res.map((r, k) => ({ code: items0[k].code, date: items0[k].date, trades: r.trades, rej: r.rej, sum: r.trades.reduce((a, t) => a + t.ret, 0) }));
      const st = stats([].concat(...per.map(p => p.trades)));
      let lossDays = 0, worstDay = 0, worstTr = 0, blk = 0, rmN = 0, rmS = 0, adN = 0, adS = 0, artN = 0, sumP = 0, sumK = 0;
      const why = {}, diffs = [], artL = [];
      const ign = gates[g.id].reduce((a, r) => a + (r.diag.ignored || 0), 0);
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
        const b0 = items[k].bars;
        p.trades.forEach((t, j) => {
          const a = adjExit(t, b0, items0[k].krx, xt);
          const rP = a && a.prev != null ? a.prev : t.ret, rK = a && a.krx != null ? a.krx : t.ret;
          sumP += rP; sumK += rK;
          if (a) {
            artN++;
            if (g.id === 'GP000') artL.push(p.code + ' ' + hmsS(b0[t.inI].hms) + ' ' + t.inPx + ' -> ' + hmsS(b0[t.outI].hms) + ' ' + t.outPx + ' ' + t.why + ' ret ' + fx(t.ret) +
              ' | prev(' + (a.prevHms != null ? hmsS(a.prevHms) : '-') + ') ' + (a.prev != null ? fx(a.prev) : '-') + ' | krx(' + (items0[k].krx || '-') + ') ' + (a.krx != null ? fx(a.krx) : '-'));
          }
          trRows.push([s.id + '__' + rp.id + '__' + g.id, p.code, p.date, j + 1, hmsS(b0[t.inI].hms), t.inPx, hmsS(b0[t.outI].hms), t.outPx, t.why, t.ret.toFixed(3), t.mfe.toFixed(3),
            a ? 1 : 0, a && a.prev != null ? a.prev.toFixed(3) : '', a && a.krx != null ? a.krx.toFixed(3) : ''].join(','));
        });
      });
      const delta = st.sum - bst.sum;
      rep.push(' ' + g.id.padEnd(6) + pad(st.n, 7) + pad(fx(st.sum), 8) + pad(st.pf.toFixed(2), 6) + pad(st.mdd.toFixed(2), 6) + pad(lossDays, 9) +
        pad(fx(worstDay), 9) + pad(fx(worstTr), 8) + pad(blk, 8) + pad(rmN + '/' + fx(rmS), 15) + pad(adN + '/' + fx(adS), 13) + pad(fx(delta), 8) +
        pad(artN, 5) + pad(fx(sumP), 8) + pad(fx(sumK), 8));
      if (g.id !== 'GP000') {
        const w = (Object.keys(why).sort().map(k => k.replace('r_', '') + ':' + why[k]).join(' ') + (ign ? ' ignoredOutsideSafe:' + ign : '')).trim();
        if (w) rep.push('        block reasons: ' + w);
        if (diffs.length) rep.push('        by stock: ' + diffs.join(' | '));
      }
      for (const l of artL) rep.push('        art: ' + l);
      runRows.push([s.id, rp.id, g.id, st.n, st.sum.toFixed(3), st.pf.toFixed(3), st.mdd.toFixed(3), lossDays, worstDay.toFixed(3), worstTr.toFixed(3), blk, rmN, rmS.toFixed(3), adN, adS.toFixed(3), delta.toFixed(3), artN, sumP.toFixed(3), sumK.toFixed(3)].join(','));
    }
  }
}
console.log('PARITY guard-1.0=1.1 OK gates=' + p10N + ' | CAUSAL OK checks=' + causN + ' | PARITY v1/E3 OK ' + parityN);

// ---- event ledger ----
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

const head = ['PatternGuard lab ' + G.VERSION + ' | data ' + dsId + ' | stock-days ' + items0.length + ' | selftest ' + ST.length + '/' + ST.length +
  ' | parity v1/E3 ' + parityN + ' | parity guard-1.0=1.1 ' + p10N + ' gates | causal ' + causN,
  'strategies=' + strats.map(s => s.id).join(',') + ' risk=' + profs.map(p => p.id).join(',') + ' guards=' + guards.map(g => g.id).join(','),
  'delta = sum(guard) - sum(GP000) under same strategy x risk. removed = GP000 trades the guard blocked, added = new entries after block.',
  'art = exits stamped after ExitTime. adjPrev/adjKrx = sums with those exits refilled at last bar <= ExitTime / KRX daily close. Diagnostic only.'];
for (const g of guards) head.push('  ' + g.id + ' ' + g.P.name + ' on=[' + G.enabledList(g.P).map(p => p + ':' + g.P.patterns[p].action).join(' ') + ']' +
  (g.P.filter.ignoreOutsideSafe ? ' ignoreOutsideSafe' : '') + (g.P.rebound.pbRef !== 'incl' ? ' pbRef=' + g.P.rebound.pbRef : ''));
for (const n of notes) head.push('[note] ' + n);
fs.writeFileSync(path.join(OUT, 'report.txt'), head.concat(rep).join('\n') + '\n', 'utf8');
fs.writeFileSync(path.join(OUT, 'runs.csv'), 'strategy,risk,guard,trades,sum,pf,mdd,loss_days,worst_day,worst_trade,blocked,removed_n,removed_sum,added_n,added_sum,delta,art_n,sum_adj_prev,sum_adj_krx\n' + runRows.join('\n') + '\n', 'utf8');
fs.writeFileSync(path.join(OUT, 'trades.csv'), 'key,code,date,no,in,in_px,out,out_px,why,ret,mfe,art,ret_prev,ret_krx\n' + trRows.join('\n') + '\n', 'utf8');
fs.writeFileSync(path.join(OUT, 'events.csv'), 'pid,code,date,time,px,in_safe,mom,state,mfe10,mae10,mfe30,mae30,mfe60,mae60,crash30\n' + evRows.join('\n') + '\n', 'utf8');
console.log('DONE runs=' + runRows.length + ' parity=' + parityN + ' events=' + evRows.length + ' stockdays=' + items0.length + ' data=' + dsId);