# 33_warmup.ps1 - S4-0 warmup sensitivity (warmup-1.0). ASCII only.
param(
  [string]$Strategies = 'S000,C013',
  [string]$Grid = '0,50,100,150,200,300,400,600',
  [int]$Ref = 800
)
$ErrorActionPreference = 'Continue'
$Root = 'E:\parent\projects\rea\projects\mom-trader'
$OutFile = Join-Path $Root 'out\FOR_OPUS.txt'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$StartTime = Get-Date

function Write-Fallback([string]$why, [string]$detail) {
  $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $lines = @($detail -split "`r?`n")
  $t = "#MT-REPORT v=report-1.0 step=S4.warmup ver=warmup-1.0 verdict=FAIL ts=$ts dur=0.0s`n" +
       "#ENV ps=$($PSVersionTable.PSVersion) writer=powershell-fallback`n" +
       "#FAIL $why`n#DATA detail lines=$($lines.Count)`n$detail`n#END`n"
  New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
  [IO.File]::WriteAllText($OutFile, $t, $Utf8)
  Write-Host "FAIL S4.warmup ($why) -> $OutFile"
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Fallback 'node not found' ''; exit 1 }
$eng = Join-Path $Root 'tools\ui\engines.cjs'
if (-not (Test-Path $eng)) { Write-Fallback 'tools\ui\engines.cjs missing (run 30_server.ps1 first)' ''; exit 1 }

$js = @'
'use strict';
// s4_warmup.cjs (warmup-1.0) - S4-0 warmup sensitivity. Read-only on engines and data.
// Question: with fewer warmup bars than REF, does the frozen engine give the SAME trades on the target day?
// Method: stock-days with >= REF prior bars; cut warmup to W bars; rerun; compare with the REF run trade by trade.
// Note: REF is itself a truncation of history. This measures convergence to the REF run.
// Loaders copied verbatim from sz-lab-guard11.cjs (parity 48 passed).
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const VER = 'warmup-1.0', STEP = 'S4.warmup';
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

// ---- copied from sz-lab-guard11.cjs ----
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
// ---- end copy ----

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
function indDiff(a, b, start, N, off) {
  let safe = 0, stDir = 0, sig = 0, ema = 0;
  for (let j = start; j < N; j++) {
    const k = j - off;
    if (!!a.safe[j] !== !!b.safe[k]) safe++;
    if (a.stDir[j] !== b.stDir[k]) stDir++;
    if ((a.n[j] < a.sig[j]) !== (b.n[k] < b.sig[k])) sig++;
    if (a.ema[j] > 0 && b.ema[k] > 0) { const r = Math.abs(b.ema[k] / a.ema[j] - 1) * 100; if (r > ema) ema = r; }
  }
  return { safe, stDir, sig, ema };
}

function main() {
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  const REF = Number(A('ref') || 800);
  const GRID = list(A('grid') || '0,50,100,150,200,300,400,600').map(Number).filter(x => x >= 0 && x < REF).sort((a, b) => a - b);
  const E = require(path.join(ROOT, 'tools', 'ui', 'engines.cjs'));
  engVer = E.VERSION;
  const vr = E.verify(ROOT);
  if (!ok('engine hash gate (' + E.VERSION + ')', vr && vr.ok, 'missing=' + JSON.stringify(vr && vr.missing))) return 'FAIL';
  const V1 = E.load(ROOT).V1;
  if (!ok('V1 api prep/compute/simulate', V1 && ['prep', 'compute', 'simulate'].every(k => typeof V1[k] === 'function'), Object.keys(V1 || {}).join(','))) return 'FAIL';

  // strategies (same rule as lab: frozen hash-checked, then survivors, then candidates)
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

  // gate 2: reproduce 11/02 from data\ticks + data\daily
  const oldT = path.join(ROOT, 'data', 'ticks'), oldD = path.join(ROOT, 'data', 'daily');
  const oldItems = fs.readdirSync(oldT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort().map(f => loadItem(oldT, oldD, f));
  const EXP = { S000: { n: 33, sum: '5.94' }, C013: { n: 31, sum: '8.29' } };
  const rl = ['strategy items trades     sum    PF   MDD  expected'];
  let reproOk = true;
  for (const s of strats) {
    const st = stats([].concat(...oldItems.map(it => run(it, it.bars, it.start, s.params).r.trades))), e = EXP[s.id];
    rl.push(s.id.padEnd(8) + pad(oldItems.length, 6) + pad(st.n, 7) + pad(fx(st.sum), 8) + pad(st.pf.toFixed(2), 6) + pad(st.mdd.toFixed(2), 6) + '  ' + (e ? e.n + '/' + e.sum : '-'));
    if (e && !ok('repro 11/02 ' + s.id, st.n === e.n && st.sum.toFixed(2) === e.sum, 'n=' + st.n + ' sum=' + st.sum.toFixed(2) + ' expected n=' + e.n + ' sum=' + e.sum)) reproOk = false;
  }
  data('repro_1102', rl);
  if (!reproOk) return 'FAIL';

  // gate 3: data\rest pipeline = data\ticks pipeline on the S3 parity file
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

  // scan archive
  const files = fs.readdirSync(restT).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(Match)).sort();
  const cov = [], full = [], exL = []; let excl = 0, noDaily = 0;
  for (const f of files) {
    let it; try { it = loadItem(restT, restD, f); } catch (e) { excl++; if (exL.length < 20) exL.push(f + ': ' + e.message); continue; }
    if (!it.dly) noDaily++;
    cov.push({ code: it.code, date: it.date, warm: it.start });
    if (it.start >= REF) full.push(it);
  }
  if (!ok('full-warmup stock-days >= 1', full.length > 0, 'full=' + full.length)) return 'FAIL';

  // sensitivity
  const agg = {}, ex = {}, rows = ['code,date,warm,strategy,W,sameTrades,sameAll,refN,wN,refSum,wSum,safeMis,stDirMis,sigMis,emaRelMaxPct,msg'];
  for (const s of strats) for (const it of full) {
    const R0 = run(it, it.bars, it.start, s.params), refSum = R0.r.trades.reduce((a, t) => a + t.ret, 0);
    for (const W of GRID) {
      const off = it.start - W, R1 = run(it, it.bars.slice(off), W, s.params);
      const mt = sameTr(R0.r, R1.r, off), mc = mt || sameCnt(R0.r, R1.r);
      const id = indDiff(R0.ind, R1.ind, it.start, it.bars.length, off), wSum = R1.r.trades.reduce((a, t) => a + t.ret, 0);
      const k = s.id + '|' + W;
      const g = agg[k] || (agg[k] = { items: 0, sameT: 0, sameA: 0, act: 0, actSame: 0, refN: 0, wN: 0, refSum: 0, wSum: 0, safe: 0, stDir: 0, sig: 0, ema: 0 });
      g.items++; if (!mt) g.sameT++; if (!mc) g.sameA++;
      if (R0.r.trades.length || R1.r.trades.length) { g.act++; if (!mt) g.actSame++; }
      g.refN += R0.r.trades.length; g.wN += R1.r.trades.length; g.refSum += refSum; g.wSum += wSum;
      g.safe += id.safe; g.stDir += id.stDir; g.sig += id.sig; if (id.ema > g.ema) g.ema = id.ema;
      if (mt) { const e = ex[k] || (ex[k] = []); if (e.length < 3) e.push(it.code + ' ' + it.date + ': ' + mt); }
      rows.push([it.code, it.date, it.start, s.id, W, mt ? 0 : 1, mc ? 0 : 1, R0.r.trades.length, R1.r.trades.length, refSum.toFixed(3), wSum.toFixed(3),
        id.safe, id.stDir, id.sig, id.ema.toFixed(4), String(mc || '').replace(/,/g, ';')].join(','));
    }
  }
  fs.writeFileSync(path.join(RDIR, 'detail', 'items.csv'), rows.join('\r\n') + '\r\n');

  const tl = ['strategy    W items sameTr% sameAll% activeSame refN   wN  refSum    wSum safeMis stDirMis sigMis emaMax%'];
  for (const s of strats) for (const W of GRID) {
    const g = agg[s.id + '|' + W];
    tl.push(s.id.padEnd(8) + pad(W, 5) + pad(g.items, 6) + pad((g.sameT / g.items * 100).toFixed(1), 8) + pad((g.sameA / g.items * 100).toFixed(1), 9) +
      pad(g.actSame + '/' + g.act, 11) + pad(g.refN, 5) + pad(g.wN, 5) + pad(fx(g.refSum), 8) + pad(fx(g.wSum), 8) + pad(g.safe, 8) + pad(g.stDir, 9) + pad(g.sig, 7) + pad(g.ema.toFixed(3), 8));
  }
  data('sensitivity (W vs REF ' + REF + ', target-day trades)', tl);
  const xl = [];
  for (const s of strats) for (const W of GRID) for (const e of ex[s.id + '|' + W] || []) xl.push(s.id + ' W=' + W + ' ' + e);
  data('first_diffs (max 3 per row)', xl);

  const allAt = (W, thr) => strats.every(s => { const g = agg[s.id + '|' + W]; return g && g.sameT / g.items >= thr; });
  const rec100 = GRID.find(W => allAt(W, 1)), rec99 = GRID.find(W => allAt(W, 0.99));
  const cl = ['minWarm usable/total'];
  for (const W of GRID.concat([REF])) cl.push(pad(W, 7) + pad(cov.filter(c => c.warm >= W).length, 8) + '/' + cov.length);
  data('coverage (stock-days usable if MinWarmBars=W)', cl);
  const dates = [...new Set(cov.map(c => c.date))].sort(), wR = rec100 != null ? rec100 : (rec99 != null ? rec99 : REF);
  const dl = ['date     total  warm>=' + wR + '  warm>=' + REF];
  for (const d of dates) { const c = cov.filter(x => x.date === d); dl.push(d + pad(c.length, 6) + pad(c.filter(x => x.warm >= wR).length, 10) + pad(c.filter(x => x.warm >= REF).length, 9)); }
  data('coverage_by_date', dl);
  if (exL.length) data('excluded (max 20)', exL);

  sums.push('archive files=' + files.length + ' loaded=' + cov.length + ' excluded=' + excl + ' noDaily=' + noDaily + ' full(>=' + REF + ')=' + full.length + ' range=' + dates[0] + '~' + dates[dates.length - 1]);
  sums.push('grid=' + GRID.join(',') + ' ref=' + REF + ' strategies=' + strats.map(s => s.id).join(','));
  sums.push('recommend MinWarmBars: trades100%=' + (rec100 != null ? rec100 : 'none') + ' trades99%=' + (rec99 != null ? rec99 : 'none'));
  try {
    const pg = path.join(ROOT, 'docs', 'progress.md');
    if (fs.existsSync(pg)) fs.appendFileSync(pg, '\n- S4-0 warmup (' + VER + ') ' + LSTAMP + ': full=' + full.length + ' rec100=' + (rec100 != null ? rec100 : 'none') + ' rec99=' + (rec99 != null ? rec99 : 'none') + ' report=' + RDIR + '\n');
  } catch (e) { sums.push('progress.md append failed: ' + e.message); }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL';
try { verdict = main(); report(verdict); }
catch (e) { verdict = 'FAIL'; try { report('FAIL', e); } catch (e2) { console.log('report write failed: ' + e2.message); } }
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);
'@

$dst = Join-Path $Root 'tools\ui\s4_warmup.cjs'
if (Test-Path $dst) { Copy-Item $dst ($dst + '.bak33') -Force }
[IO.File]::WriteAllText($dst, $js, $Utf8)

$chkOut = & node --check $dst 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Fallback 'node --check failed: tools\ui\s4_warmup.cjs' $chkOut; exit 1 }

$runOut = & node $dst $Root --strategies $Strategies --grid $Grid --ref $Ref 2>&1 | Out-String
$code = $LASTEXITCODE
$fresh = (Test-Path $OutFile) -and ((Get-Item $OutFile).LastWriteTime -ge $StartTime)
if (-not $fresh) { Write-Fallback "node exited $code without writing report" $runOut; exit 1 }
Write-Host ($runOut.Trim())
exit $code
