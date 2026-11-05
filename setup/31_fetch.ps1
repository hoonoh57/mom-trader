#requires -Version 5.1
# S2: Kiwoom REST collector fetch-1.0 (ASCII only). Writes tools\ui\kiwoom-fetch.cjs, tools\ui\s2.cjs and runs node.
# Result file: out\FOR_OPUS.txt  (attach this file only)
param(
  [ValidateSet('verify','selftest','fetch')][string]$Mode = 'verify',
  [string]$Codes = '',
  [string]$Date = '',
  [int]$WarmupBars = 800,
  [ValidateSet('AUTO','MOCK','REAL')][string]$Server = 'AUTO',
  [string]$EnvPath = 'E:\parent\security\.env',
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [int]$MaxPages = 80,
  [int]$DelayMs = 300,
  [switch]$NoDaily
)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object Text.UTF8Encoding($false)
$forOpus = Join-Path $Root 'out\FOR_OPUS.txt'
$uiDir = Join-Path $Root 'tools\ui'

function Write-Fallback([string]$stage, [string[]]$lines) {
  $t = New-Object System.Collections.Generic.List[string]
  $t.Add("#MT-REPORT v=report-1.0 step=S2.fetch ver=fetch-1.0 verdict=FAIL ts=$((Get-Date).ToUniversalTime().ToString('o')) dur=-")
  $t.Add("#ENV ps=$($PSVersionTable.PSVersion) writer=powershell-fallback")
  $t.Add("#FAIL $stage")
  $t.Add('#DATA output')
  foreach ($l in @($lines)) { $t.Add([string]$l) }
  $t.Add('#END')
  New-Item -ItemType Directory -Force -Path (Split-Path $forOpus) | Out-Null
  [IO.File]::WriteAllLines($forOpus, $t, $utf8)
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Fallback 'node not found' @('node not in PATH'); Write-Host "FAIL S2.fetch -> $forOpus" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force -Path $uiDir, (Join-Path $Root 'out\reports') | Out-Null

$files = [ordered]@{}
$files['kiwoom-fetch.cjs'] = @'
'use strict';
// fetch-1.0 : Kiwoom REST collector (ka10079 ticks, ka10081 daily).
// Byte-compatible port of setup\09_fetch_ticks.ps1 (sha12 18460ac7a97a) and setup\12_fetch_daily.ps1 (sha12 3c7638a31a09).
// Formatting emulates PowerShell 5.1 / .NET Framework: custom format = 15 significant digits, then half-away-from-zero.
const fs = require('fs');
const path = require('path');
const os = require('os');
const VERSION = 'fetch-1.0';
const TICK_HEADER = 'ts,date,time,open,high,low,close,volume,bar_amount,is_target';
const DAILY_HEADER = 'date,open,high,low,close,volume,chg_pct';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const asList = x => (Array.isArray(x) ? x : (x && typeof x === 'object' ? [x] : []));

function toNum(s) {
  if (s === null || s === undefined) return null;
  const t = String(s).trim().replace(/,/g, '');
  if (t === '') return null;
  if (!/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(t)) return null;
  const d = Number(t);
  return Number.isFinite(d) ? Math.abs(d) : null;
}

// keys are lower-cased (PowerShell hashtable is case-insensitive)
function readDotEnv(p) {
  const map = {};
  const txt = fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
  for (const line of txt.split(/\r\n|\n|\r/)) {
    const t = line.trim();
    if (t === '' || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i < 1) continue;
    const k = t.slice(0, i).trim();
    let v = t.slice(i + 1).trim();
    if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"))) v = v.slice(1, -1);
    map[k.toLowerCase()] = v;
  }
  return map;
}
const envGet = (m, name) => (m[String(name).toLowerCase()] === undefined ? '' : m[String(name).toLowerCase()]);

function plain15(x) {
  const s = x.toPrecision(15);
  const m = s.match(/^(\d)(?:\.(\d+))?e([+-]\d+)$/);
  if (!m) return s;
  const digits = m[1] + (m[2] || '');
  const point = Number(m[3]) + 1;
  if (point <= 0) return '0.' + '0'.repeat(-point) + digits;
  if (point >= digits.length) return digits + '0'.repeat(point - digits.length);
  return digits.slice(0, point) + '.' + digits.slice(point);
}

// .NET Framework custom format "0.####" (maxDec=4,minDec=0) / "0.00" (2,2)
function fmtNet(x, maxDec, minDec) {
  minDec = minDec || 0;
  if (!Number.isFinite(x)) return String(x);
  const neg = x < 0;
  const parts = plain15(Math.abs(x)).split('.');
  let ip = parts[0], fp = parts[1] || '';
  if (fp.length > maxDec) {
    const up = fp.charCodeAt(maxDec) >= 53;
    fp = fp.slice(0, maxDec);
    if (up) {
      const d = (ip + fp).split('');
      let k = d.length - 1;
      while (k >= 0) { if (d[k] === '9') { d[k] = '0'; k--; } else { d[k] = String(Number(d[k]) + 1); break; } }
      if (k < 0) d.unshift('1');
      const all = d.join('');
      ip = all.slice(0, all.length - fp.length);
      fp = all.slice(all.length - fp.length);
    }
  }
  fp = fp.replace(/0+$/, '');
  while (fp.length < minDec) fp += '0';
  ip = ip.replace(/^0+(?=\d)/, '');
  let out = fp.length ? ip + '.' + fp : ip;
  if (neg && /[1-9]/.test(out)) out = '-' + out;
  return out;
}

// PowerShell "-f {0}" with [double] (G, 15 digits); null -> ''
function fmtG(x) {
  if (x === null || x === undefined) return '';
  if (Number.isInteger(x) && Math.abs(x) < 1e15) return String(x);
  return String(Number(x.toPrecision(15)));
}

function tickRow(it) {
  const ts = String(it.cntr_tm === null || it.cntr_tm === undefined ? '' : it.cntr_tm).trim();
  if (ts.length < 14) return null;
  const o = toNum(it.open_pric), h = toNum(it.high_pric), l = toNum(it.low_pric), c = toNum(it.cur_prc), v = toNum(it.trde_qty);
  if (o === null || h === null || l === null || c === null || v === null) return null;
  return { ts: ts.slice(0, 14), date: ts.slice(0, 8), time: ts.slice(8, 14), o, h, l, c, v, amt: (o + h + l + c) / 4 * v };
}

function tickLine(b, target) {
  const F = x => fmtNet(x, 4, 0);
  return [b.ts, b.date, b.time, F(b.o), F(b.h), F(b.l), F(b.c), F(b.v), F(b.amt), b.date === target ? '1' : '0'].join(',');
}

function buildTick(rowsNewestFirst, target, warmup) {
  const arr = rowsNewestFirst.slice().reverse();
  const prev = arr.filter(b => b.date < target);
  const tgt = arr.filter(b => b.date === target);
  const keep = prev.length > warmup ? prev.slice(prev.length - warmup) : prev;
  const out = keep.concat(tgt);
  let nonMono = 0, ohlcBad = 0, sameTs = 0;
  for (let i = 0; i < out.length; i++) {
    const b = out[i];
    if (b.l > Math.min(b.o, b.c) || b.h < Math.max(b.o, b.c) || b.l <= 0) ohlcBad++;
    if (i > 0) { if (b.ts < out[i - 1].ts) nonMono++; else if (b.ts === out[i - 1].ts) sameTs++; }
  }
  const lines = [TICK_HEADER];
  for (const b of out) lines.push(tickLine(b, target));
  return {
    text: lines.join('\r\n') + '\r\n', prevN: prev.length, keepN: keep.length, tgtN: tgt.length,
    first: tgt.length ? tgt[0].time : '-', last: tgt.length ? tgt[tgt.length - 1].time : '-',
    nonMono, ohlcBad, sameTs, taamt: tgt.reduce((s, b) => s + b.amt, 0)
  };
}

function dailyRows(list) {
  const rows = [];
  for (const it of list) {
    const d = String(it.dt === null || it.dt === undefined ? '' : it.dt).trim();
    const o = toNum(it.open_pric), h = toNum(it.high_pric), l = toNum(it.low_pric), c = toNum(it.cur_prc), v = toNum(it.trde_qty);
    if (/^\d{8}$/.test(d) && o !== null && h !== null && l !== null && c !== null && c > 0) rows.push({ date: d, o, h, l, c, v });
  }
  rows.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
  return rows.filter((r, i) => i === 0 || r.date !== rows[i - 1].date);
}

function buildDaily(rows) {
  const lines = [DAILY_HEADER];
  for (let i = 0; i < rows.length; i++) {
    const b = rows[i];
    const chg = i > 0 ? (b.c / rows[i - 1].c - 1) * 100 : null;
    lines.push([b.date, fmtG(b.o), fmtG(b.h), fmtG(b.l), fmtG(b.c), fmtG(b.v), chg === null ? '' : fmtNet(chg, 2, 2)].join(','));
  }
  return lines.join('\r\n') + '\r\n';
}

function firstDiff(aText, bText) {
  const a = aText.split('\r\n'), b = bText.split('\r\n');
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) {
    if (a[i] !== b[i]) return { line: i + 1, a: a[i] === undefined ? '(none)' : a[i], b: b[i] === undefined ? '(none)' : b[i] };
  }
  return null;
}

// offline: parse an existing 09 output, recompute bar_amount, re-emit, compare bytes
function roundTripTick(text) {
  const L = text.split('\r\n');
  if (L[L.length - 1] !== '') return { ok: false, line: L.length, a: 'no trailing CRLF', b: '' };
  if (L[0] !== TICK_HEADER) return { ok: false, line: 1, a: L[0], b: TICK_HEADER };
  const rows = L.slice(1, -1).map(s => s.split(','));
  const tr = rows.find(r => r[9] === '1');
  const target = tr ? tr[1] : '';
  const out = [TICK_HEADER];
  for (const r of rows) {
    const o = Number(r[3]), h = Number(r[4]), l = Number(r[5]), c = Number(r[6]), v = Number(r[7]);
    out.push(tickLine({ ts: r[0], date: r[1], time: r[2], o, h, l, c, v, amt: (o + h + l + c) / 4 * v }, target));
  }
  const rebuilt = out.join('\r\n') + '\r\n';
  const d = firstDiff(text, rebuilt);
  return d ? Object.assign({ ok: false }, d) : { ok: true, n: rows.length };
}

// offline: parse an existing 12 output, recompute chg_pct, re-emit, compare bytes
function roundTripDaily(text) {
  const L = text.split('\r\n');
  if (L[L.length - 1] !== '') return { ok: false, line: L.length, a: 'no trailing CRLF', b: '' };
  if (L[0] !== DAILY_HEADER) return { ok: false, line: 1, a: L[0], b: DAILY_HEADER };
  const rows = L.slice(1, -1).map(s => s.split(',')).map(r => ({ date: r[0], o: Number(r[1]), h: Number(r[2]), l: Number(r[3]), c: Number(r[4]), v: r[5] === '' ? null : Number(r[5]) }));
  const d = firstDiff(text, buildDaily(rows));
  return d ? Object.assign({ ok: false }, d) : { ok: true, n: rows.length };
}

async function httpPost(url, headers, body) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const res = await fetch(url, {
      method: 'POST',
      headers: Object.assign({ 'Content-Type': 'application/json;charset=UTF-8' }, headers),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(20000)
    });
    const text = await res.text();
    if (res.status === 429 && attempt < 4) { await sleep(1000 * attempt); continue; }
    if (!res.ok) throw new Error('HTTP ' + res.status + ' : ' + text.slice(0, 300));
    let json;
    try { json = JSON.parse(text); } catch (e) { throw new Error('bad JSON from ' + url + ' : ' + text.slice(0, 200)); }
    return { headers: res.headers, text, json: json || {} };
  }
  throw new Error('HTTP 429 : retries exhausted');
}

function createClient(o) {
  if (!fs.existsSync(o.envPath)) throw new Error('.env not found: ' + o.envPath);
  const env = readDotEnv(o.envPath);
  const sv = String(o.server || 'AUTO').toUpperCase();
  const mock = sv === 'MOCK' ? true : sv === 'REAL' ? false : String(envGet(env, 'KIWOOM_USE_MOCK')).trim().toLowerCase() === 'true';
  const base = mock ? 'https://mockapi.kiwoom.com' : 'https://api.kiwoom.com';
  const kName = mock ? 'KIWOOM_MOCK_APP_KEY' : 'KIWOOM_REAL_APP_KEY';
  const sName = mock ? 'KIWOOM_MOCK_SECRET_KEY' : 'KIWOOM_REAL_SECRET_KEY';
  const appKey = String(envGet(env, kName)), secret = String(envGet(env, sName));
  if (!appKey) throw new Error(kName + ' empty in ' + o.envPath);
  if (!secret) throw new Error(sName + ' empty in ' + o.envPath);
  const cl = { mock, base, kName, kLen: appKey.length, secrets: [appKey, secret], token: '', expires: '' };
  cl.auth = async () => {
    const r = await httpPost(base + '/oauth2/token', {}, { grant_type: 'client_credentials', appkey: appKey, secretkey: secret });
    const tk = String(r.json.token || '');
    if (!tk) throw new Error('token failed return_code=' + r.json.return_code + ' msg=' + r.json.return_msg);
    cl.token = tk; cl.expires = String(r.json.expires_dt || ''); cl.secrets.push(tk);
  };
  cl.chart = (apiId, body, next) => {
    const h = { authorization: 'Bearer ' + cl.token, 'api-id': apiId };
    if (next) { h['cont-yn'] = 'Y'; h['next-key'] = next; }
    return httpPost(base + '/api/dostk/chart', h, body);
  };
  return cl;
}

async function fetchTicks(cl, q) {
  const scope = String(q.scope || '120'), mkt = q.market || 'AL', code = q.code;
  const stk = mkt === 'KRX' ? code : mkt === 'NXT' ? code + '_NX' : code + '_AL';
  const all = [];
  let target = q.date || '', next = '', end = '', bad = 0, pages = 0, raw = '';
  for (let page = 1; page <= q.maxPages; page++) {
    pages = page;
    const r = await cl.chart('ka10079', { stk_cd: stk, tic_scope: scope, upd_stkpc_tp: '1' }, page > 1 ? next : '');
    const rc = String(r.json.return_code);
    if (rc !== '0') throw new Error('ka10079 return_code=' + rc + ' msg=' + r.json.return_msg);
    const chunk = asList(r.json.stk_tic_chart_qry);
    if (page === 1 && q.rawDir) {
      fs.mkdirSync(q.rawDir, { recursive: true });
      raw = path.join(q.rawDir, 'raw-' + code + '-' + mkt + '-' + scope + '-' + (q.date || 'latest') + '-p1.json');
      fs.writeFileSync(raw, r.text, 'utf8');
    }
    if (!chunk.length) { end = 'empty'; break; }
    for (const it of chunk) { const row = tickRow(it); if (row) all.push(row); else bad++; }
    if (!target) target = all.reduce((m, x) => (x.date > m ? x.date : m), '');
    const prevN = all.filter(x => x.date < target).length;
    if (prevN >= q.warmup) { end = 'warmup'; break; }
    const cont = r.headers.get('cont-yn') || '', nk = r.headers.get('next-key') || '';
    if (cont.toUpperCase() !== 'Y' || !nk) { end = 'cont_end(' + cont + ')'; break; }
    next = nk;
    await sleep(q.delayMs);
  }
  if (!end) end = 'max_pages(' + q.maxPages + ')';
  return { rows: all, target, pages, end, bad, raw };
}

async function fetchDaily(cl, q) {
  const r = await cl.chart('ka10081', { stk_cd: q.code, base_dt: q.baseDate, upd_stkpc_tp: '1' }, '');
  if (String(r.json.return_code) !== '0') throw new Error('ka10081 return_code=' + r.json.return_code + ' msg=' + r.json.return_msg);
  if (q.rawDir) {
    fs.mkdirSync(q.rawDir, { recursive: true });
    fs.writeFileSync(path.join(q.rawDir, 'raw-daily-' + q.code + '-' + q.baseDate + '.json'), r.text, 'utf8');
  }
  const list = asList(r.json.stk_dt_pole_chart_qry);
  if (!list.length) throw new Error('stk_dt_pole_chart_qry empty');
  const rows = dailyRows(list);
  if (rows.length < 3) throw new Error('valid daily rows ' + rows.length);
  return { rows, text: buildDaily(rows) };
}

function selftest() {
  const R = [];
  const t = (name, fn) => {
    try { const v = fn(); R.push({ name, ok: v === true, info: v === true ? '' : String(v) }); }
    catch (e) { R.push({ name, ok: false, info: 'threw ' + e.message }); }
  };
  const eq = (a, b) => (JSON.stringify(a) === JSON.stringify(b) ? true : 'expected ' + JSON.stringify(b) + ' got ' + JSON.stringify(a));
  t('toNum', () => eq([toNum('-71200'), toNum('+1,234'), toNum(''), toNum('abc'), toNum(' 12.5 '), toNum(null)], [71200, 1234, null, null, 12.5, null]));
  t('readDotEnv', () => {
    const f = path.join(os.tmpdir(), 'mt_s2_' + process.pid + '.env');
    fs.writeFileSync(f, '\uFEFF# c\nA=1\nB="x y"\nC=\nkiwoom_use_mock=true\n', 'utf8');
    const e = readDotEnv(f); fs.unlinkSync(f);
    return eq([envGet(e, 'A'), envGet(e, 'B'), envGet(e, 'C'), '# c' in e, envGet(e, 'KIWOOM_USE_MOCK')], ['1', 'x y', '', false, 'true']);
  });
  t('tickRow', () => {
    const r = tickRow({ cntr_tm: '20261102090001', open_pric: '-100', high_pric: '110', low_pric: '90', cur_prc: '+100', trde_qty: '10' });
    const n = tickRow({ cntr_tm: '2026110209', open_pric: '1', high_pric: '1', low_pric: '1', cur_prc: '1', trde_qty: '1' });
    return eq([r && r.amt, r && r.date, r && r.time, n], [1000, '20261102', '090001', null]);
  });
  t('fmtNet 0.####', () => {
    const cases = [[435359615, '435359615'], [60334312.5, '60334312.5'], [0.123456, '0.1235'], [1.00005, '1.0001'],
      [-0.00001, '0'], [2757.25, '2757.25'], [1e-7, '0'], [123456789012.25, '123456789012.25'], [9.99996, '10'], [0, '0']];
    const bad = cases.filter(c => fmtNet(c[0], 4, 0) !== c[1]).map(c => c[0] + '->' + fmtNet(c[0], 4, 0));
    return bad.length ? bad.join(' ') : true;
  });
  t('fmtNet 0.00', () => {
    const cases = [[1.005, '1.01'], [-4.109589, '-4.11'], [6.3241, '6.32'], [0, '0.00'], [25, '25.00'], [-4.105, '-4.11']];
    const bad = cases.filter(c => fmtNet(c[0], 2, 2) !== c[1]).map(c => c[0] + '->' + fmtNet(c[0], 2, 2));
    return bad.length ? bad.join(' ') : true;
  });
  t('fmtG', () => eq([fmtG(11000), fmtG(null), fmtG(0)], ['11000', '', '0']));
  t('buildTick order/warmup/flags', () => {
    const mk = (ts, p) => ({ ts, date: ts.slice(0, 8), time: ts.slice(8), o: p, h: p, l: p, c: p, v: 1, amt: p });
    const resp = [mk('20261103090000', 9), mk('20261102090002', 5), mk('20261102090001', 4), mk('20261102090001', 3),
      mk('20261030153000', 2), mk('20261030152000', 1), mk('20261030151000', 0.5)];
    const b = buildTick(resp, '20261102', 2);
    const L = b.text.split('\r\n');
    const closes = L.slice(1, -1).map(s => s.split(',')[6]);
    const flags = L.slice(1, -1).map(s => s.split(',')[9]);
    return eq([L[0], L[L.length - 1], closes, flags, b.keepN, b.tgtN, b.sameTs, b.prevN], [TICK_HEADER, '', ['1', '2', '3', '4', '5'], ['0', '0', '1', '1', '1'], 2, 3, 1, 3]);
  });
  t('buildDaily sort/unique/chg', () => {
    const rows = dailyRows([
      { dt: '20261030', open_pric: '+10', high_pric: '11', low_pric: '9', cur_prc: '10', trde_qty: '5' },
      { dt: '20261029', open_pric: '8', high_pric: '8', low_pric: '8', cur_prc: '-8', trde_qty: '' },
      { dt: '20261030', open_pric: '99', high_pric: '99', low_pric: '99', cur_prc: '99', trde_qty: '9' },
      { dt: 'x', open_pric: '1', high_pric: '1', low_pric: '1', cur_prc: '1', trde_qty: '1' }]);
    return eq(buildDaily(rows), DAILY_HEADER + '\r\n20261029,8,8,8,8,,\r\n20261030,10,11,9,10,5,25.00\r\n');
  });
  return R;
}

module.exports = {
  VERSION, TICK_HEADER, DAILY_HEADER, toNum, readDotEnv, envGet, fmtNet, fmtG, tickRow, tickLine, buildTick,
  dailyRows, buildDaily, firstDiff, roundTripTick, roundTripDaily, createClient, fetchTicks, fetchDaily, selftest, sleep
};
'@

$files['s2.cjs'] = @'
'use strict';
// S2 runner: offline selftest + verify (byte parity with 09/12 outputs) + fetch. Writes out\FOR_OPUS.txt
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const K = require('./kiwoom-fetch.cjs');
const ROOT = process.argv[2], OPT = process.argv[3];
const T0 = Date.now();
const PRIMARY_TICK = '0011A0_AL_120t_20261102.csv', PRIMARY_DAILY = '0011A0.csv';
const TICK_RE = /^([0-9A-Z]{6})_(AL|KRX|NXT)_(\d+)t_(\d{8})\.csv$/;
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const P = (...a) => path.join(ROOT, ...a);
const z = n => String(n).padStart(2, '0');
const stamp = d => '' + d.getFullYear() + z(d.getMonth() + 1) + z(d.getDate()) + '-' + z(d.getHours()) + z(d.getMinutes()) + z(d.getSeconds());
const cut = (s, n) => { s = String(s); n = n || 220; return s.length > n ? s.slice(0, n) + '...' : s; };
const checks = [], blocks = [], errs = [], summary = [];
const env = { envFile: '-', server: '-', base: '-', kName: '-', kLen: 0, expires: '-' };
let secrets = [], opts = {}, finished = false;

function mask(s) { s = String(s); for (const x of secrets) if (x && x.length >= 6) s = s.split(x).join('***(len=' + x.length + ')'); return s; }
function chk(name, ok, info) { checks.push({ name, ok: !!ok, info: info ? mask(info) : '' }); return !!ok; }
function block(name, rows) { blocks.push({ name, rows: rows.map(mask) }); }

function ledger(r) {
  const p = P('data', 'rest', 'ledger.csv');
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const cols = ['fetched_at', 'kind', 'api_id', 'code', 'market', 'scope', 'target', 'warmup_req', 'pages', 'bars_target', 'bars_warmup', 'end_reason', 'bad_rows', 'file', 'sha12', 'server'];
  if (!fs.existsSync(p)) fs.writeFileSync(p, cols.join(',') + '\r\n', 'utf8');
  r.fetched_at = stamp(new Date()); r.server = env.server;
  fs.appendFileSync(p, cols.map(c => String(r[c] === null || r[c] === undefined ? '' : r[c]).replace(/[,\r\n]/g, ' ')).join(',') + '\r\n', 'utf8');
}

function offlineRoundtrip() {
  const rows = [];
  let okT = 0, nT = 0, okD = 0, nD = 0, primT = null, primD = null;
  for (const sub of ['ticks', 'daily']) {
    const dir = P('data', sub);
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir).filter(x => /\.csv$/i.test(x)).sort()) {
      const text = fs.readFileSync(path.join(dir, f), 'utf8');
      const r = sub === 'ticks' ? K.roundTripTick(text) : K.roundTripDaily(text);
      if (sub === 'ticks') { nT++; if (r.ok) okT++; if (f === PRIMARY_TICK) primT = r; }
      else { nD++; if (r.ok) okD++; if (f === PRIMARY_DAILY) primD = r; }
      if (!r.ok) rows.push(sub + '/' + f + ' L' + r.line, '   old: ' + cut(r.a), '   new: ' + cut(r.b));
    }
  }
  summary.push('roundtrip ticks ' + okT + '/' + nT + ', daily ' + okD + '/' + nD);
  chk('roundtrip tick ' + PRIMARY_TICK, primT && primT.ok, primT ? (primT.ok ? '' : 'L' + primT.line) : 'file missing');
  chk('roundtrip daily ' + PRIMARY_DAILY, primD && primD.ok, primD ? (primD.ok ? '' : 'L' + primD.line) : 'file missing');
  if (rows.length) block('roundtrip_diff', rows);
}

async function verifyTicks(cl) {
  const dir = P('data', 'ticks');
  const rows = [];
  let ok = 0, n = 0, prim = null;
  for (const f of fs.readdirSync(dir).filter(x => TICK_RE.test(x)).sort()) {
    const m = f.match(TICK_RE), code = m[1], mkt = m[2], scope = m[3], date = m[4];
    n++;
    const oldBuf = fs.readFileSync(path.join(dir, f)), oldText = oldBuf.toString('utf8');
    const ol = oldText.split('\r\n').slice(1).filter(s => s);
    const warmOld = ol.filter(s => s.endsWith(',0')).length, tgtOld = ol.length - warmOld;
    const warmReq = Math.max(1, warmOld);
    const rec = { res: 'ERROR', warmOld, tgtOld, warmNew: 0, tgtNew: 0, pages: 0, end: '-' };
    try {
      const r = await K.fetchTicks(cl, { code, date, scope, market: mkt, warmup: warmReq, maxPages: opts.maxPages, delayMs: opts.delayMs, rawDir: P('data', 'rest', 'raw') });
      const b = K.buildTick(r.rows, r.target, warmReq);
      const nb = Buffer.from(b.text, 'utf8'), out = P('data', 'rest', 'ticks', f);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.writeFileSync(out, nb);
      Object.assign(rec, { warmNew: b.keepN, tgtNew: b.tgtN, pages: r.pages, end: r.end, bad: r.bad, shaOld: sha(oldBuf).slice(0, 12), shaNew: sha(nb).slice(0, 12) });
      const d = K.firstDiff(oldText, b.text);
      rec.res = d ? 'DIFF' : 'MATCH';
      if (d) Object.assign(rec, d);
      ledger({ kind: 'tick', api_id: 'ka10079', code, market: mkt, scope, target: r.target, warmup_req: warmReq, pages: r.pages, bars_target: b.tgtN, bars_warmup: b.keepN, end_reason: r.end, bad_rows: r.bad, file: 'data/rest/ticks/' + f, sha12: rec.shaNew });
    } catch (e) { rec.err = e.message; }
    if (rec.res === 'MATCH') ok++;
    rows.push('tick ' + f + ' ' + rec.res + ' warm=' + rec.warmOld + '/' + rec.warmNew + ' tgt=' + rec.tgtOld + '/' + rec.tgtNew +
      ' pages=' + rec.pages + ' end=' + rec.end + ' sha=' + (rec.shaOld || '-') + '/' + (rec.shaNew || '-') +
      (rec.bad ? ' badRows=' + rec.bad : '') + (rec.line ? ' firstDiff=L' + rec.line : '') + (rec.err ? ' err=' + cut(rec.err) : ''));
    if (rec.res === 'DIFF') rows.push('   old: ' + cut(rec.a), '   new: ' + cut(rec.b));
    if (f === PRIMARY_TICK) prim = rec;
    await K.sleep(opts.delayMs);
  }
  rows.push('tick match ' + ok + '/' + n + ' (primary=' + PRIMARY_TICK + ', others are reference only)');
  summary.push('tick parity ' + ok + '/' + n);
  block('verify_ticks', rows);
  chk('tick parity ' + PRIMARY_TICK, prim && prim.res === 'MATCH', prim ? prim.res + (prim.line ? ' L' + prim.line : '') + (prim.err ? ' ' + prim.err : '') : 'primary file missing');
}

async function verifyDaily(cl) {
  const dir = P('data', 'daily');
  const rows = [];
  let ok = 0, n = 0, prim = null;
  for (const f of fs.readdirSync(dir).filter(x => /^[0-9A-Z]{6}\.csv$/.test(x)).sort()) {
    const code = f.slice(0, 6);
    n++;
    const oldBuf = fs.readFileSync(path.join(dir, f)), oldText = oldBuf.toString('utf8');
    const ol = oldText.split('\r\n').filter(s => s);
    const base = (ol[ol.length - 1] || '').split(',')[0];
    const rec = { res: 'ERROR', rowsOld: ol.length - 1, rowsNew: 0 };
    try {
      if (!/^\d{8}$/.test(base)) throw new Error('cannot read last date from old file');
      const r = await K.fetchDaily(cl, { code, baseDate: base, rawDir: P('data', 'rest', 'raw') });
      const nb = Buffer.from(r.text, 'utf8'), out = P('data', 'rest', 'daily', f);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.writeFileSync(out, nb);
      Object.assign(rec, { rowsNew: r.rows.length, shaOld: sha(oldBuf).slice(0, 12), shaNew: sha(nb).slice(0, 12) });
      const d = K.firstDiff(oldText, r.text);
      rec.res = d ? 'DIFF' : 'MATCH';
      if (d) Object.assign(rec, d);
      ledger({ kind: 'daily', api_id: 'ka10081', code, market: 'KRX', target: base, pages: 1, bars_target: r.rows.length, end_reason: 'single', bad_rows: 0, file: 'data/rest/daily/' + f, sha12: rec.shaNew });
    } catch (e) { rec.err = e.message; }
    if (rec.res === 'MATCH') ok++;
    rows.push('daily ' + f + ' ' + rec.res + ' base=' + base + ' rows=' + rec.rowsOld + '/' + rec.rowsNew + ' sha=' + (rec.shaOld || '-') + '/' + (rec.shaNew || '-') +
      (rec.line ? ' firstDiff=L' + rec.line : '') + (rec.err ? ' err=' + cut(rec.err) : ''));
    if (rec.res === 'DIFF') rows.push('   old: ' + cut(rec.a), '   new: ' + cut(rec.b));
    if (f === PRIMARY_DAILY) prim = rec;
    await K.sleep(opts.delayMs);
  }
  rows.push('daily match ' + ok + '/' + n + ' (primary=' + PRIMARY_DAILY + ')');
  summary.push('daily parity ' + ok + '/' + n);
  block('verify_daily', rows);
  chk('daily parity ' + PRIMARY_DAILY, prim && prim.res === 'MATCH', prim ? prim.res + (prim.line ? ' L' + prim.line : '') + (prim.err ? ' ' + prim.err : '') : 'primary file missing');
}

async function fetchMode(cl) {
  const all = String(opts.codes || '').split(/[,\s;]+/).filter(Boolean);
  const good = all.filter(c => /^[0-9A-Z]{6}$/.test(c)), bad = all.filter(c => !/^[0-9A-Z]{6}$/.test(c));
  if (bad.length) chk('codes format', false, 'excluded: ' + bad.join(' '));
  if (!good.length) { chk('codes', false, 'no valid 6-char code (-Codes "0011A0,232680")'); return; }
  if (!/^\d{8}$/.test(String(opts.date || ''))) { chk('date', false, 'need -Date yyyyMMdd'); return; }
  const mkt = opts.market || 'AL', scope = String(opts.scope || '120'), rows = [];
  for (const code of good) {
    const f = code + '_' + mkt + '_' + scope + 't_' + opts.date + '.csv';
    try {
      const r = await K.fetchTicks(cl, { code, date: opts.date, scope, market: mkt, warmup: opts.warmup, maxPages: opts.maxPages, delayMs: opts.delayMs, rawDir: P('data', 'rest', 'raw') });
      const b = K.buildTick(r.rows, r.target, opts.warmup);
      const nb = Buffer.from(b.text, 'utf8'), out = P('data', 'rest', 'ticks', f);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.writeFileSync(out, nb);
      const probs = [];
      if (!b.tgtN) probs.push('no target bars (retention?)');
      if (r.bad) probs.push('badRows ' + r.bad);
      if (b.nonMono) probs.push('nonMono ' + b.nonMono);
      if (b.ohlcBad) probs.push('ohlcBad ' + b.ohlcBad);
      chk('tick ' + code, probs.length === 0, probs.join('; '));
      rows.push('tick ' + f + ' tgt=' + b.tgtN + ' (' + b.first + '~' + b.last + ') warm=' + b.keepN + '/' + opts.warmup + ' pages=' + r.pages + ' end=' + r.end + ' sameTs=' + b.sameTs + ' sha=' + sha(nb).slice(0, 12) + (b.keepN < opts.warmup ? ' WARN warmup short' : ''));
      ledger({ kind: 'tick', api_id: 'ka10079', code, market: mkt, scope, target: r.target, warmup_req: opts.warmup, pages: r.pages, bars_target: b.tgtN, bars_warmup: b.keepN, end_reason: r.end, bad_rows: r.bad, file: 'data/rest/ticks/' + f, sha12: sha(nb).slice(0, 12) });
    } catch (e) { chk('tick ' + code, false, e.message); }
    if (opts.daily !== false) {
      try {
        const r = await K.fetchDaily(cl, { code, baseDate: opts.date, rawDir: P('data', 'rest', 'raw') });
        const nb = Buffer.from(r.text, 'utf8'), out = P('data', 'rest', 'daily', code + '.csv');
        fs.mkdirSync(path.dirname(out), { recursive: true });
        fs.writeFileSync(out, nb);
        rows.push('daily ' + code + '.csv rows=' + r.rows.length + ' (' + r.rows[0].date + '~' + r.rows[r.rows.length - 1].date + ') sha=' + sha(nb).slice(0, 12));
        ledger({ kind: 'daily', api_id: 'ka10081', code, market: 'KRX', target: opts.date, pages: 1, bars_target: r.rows.length, end_reason: 'single', bad_rows: 0, file: 'data/rest/daily/' + code + '.csv', sha12: sha(nb).slice(0, 12) });
      } catch (e) { chk('daily ' + code, false, e.message); }
    }
    await K.sleep(opts.delayMs);
  }
  block('fetch', rows);
}

function finish(verdict) {
  if (finished) return;
  finished = true;
  const ts = new Date();
  const dir = P('out', 'reports', 'S2.fetch_' + stamp(ts));
  fs.mkdirSync(path.join(dir, 'detail'), { recursive: true });
  const pass = checks.filter(c => c.ok).length;
  const L = [];
  L.push('#MT-REPORT v=report-1.0 step=S2.fetch ver=' + K.VERSION + ' verdict=' + verdict + ' ts=' + ts.toISOString() + ' dur=' + ((Date.now() - T0) / 1000).toFixed(1) + 's');
  L.push('#DIR ' + dir);
  L.push('#ENV node=' + process.version + ' ps=' + (opts.ps || '-') + ' mode=' + (opts.mode || '-') + ' server=' + env.server + ' base=' + env.base + ' key=' + env.kName + ' len=' + env.kLen + ' tokenExp=' + env.expires + ' envFile=' + env.envFile);
  L.push('#CHK ' + pass + '/' + checks.length + ' ' + (pass === checks.length ? 'PASS' : 'FAIL'));
  if (summary.length) L.push('#SUM ' + summary.join(' | '));
  for (const c of checks) if (!c.ok) L.push('#FAIL ' + c.name + (c.info ? ' :: ' + c.info : ''));
  for (const b of blocks) { L.push('#DATA ' + b.name + ' lines=' + b.rows.length); for (const r of b.rows) L.push(r); L.push('#END'); }
  if (errs.length) { L.push('#ERR'); for (const e of errs) L.push(mask(e)); L.push('#END'); }
  let text = L.join('\r\n') + '\r\n';
  if (text.length > 200000) text = text.slice(0, 200000) + '\r\n#TRUNCATED\r\n';
  fs.writeFileSync(path.join(dir, 'report.txt'), text, 'utf8');
  fs.writeFileSync(path.join(dir, 'detail', 'results.json'), mask(JSON.stringify({ checks, blocks, errs, summary }, null, 2)), 'utf8');
  fs.mkdirSync(P('out'), { recursive: true });
  fs.writeFileSync(P('out', 'FOR_OPUS.txt'), text, 'utf8');
  fs.writeFileSync(P('out', 'reports', 'LATEST.txt'), dir + '\r\n', 'utf8');
  if (verdict === 'PASS' && opts.mode === 'verify' && fs.existsSync(P('docs', 'progress.md'))) {
    fs.appendFileSync(P('docs', 'progress.md'), '\r\n- ' + stamp(ts) + ' S2 ' + K.VERSION + ' PASS: ' + summary.join(' | ') + '\r\n', 'utf8');
  }
  console.log(verdict + ' S2.fetch -> ' + P('out', 'FOR_OPUS.txt'));
  process.exitCode = verdict === 'PASS' ? 0 : 1;
}

async function main() {
  opts = JSON.parse(fs.readFileSync(OPT, 'utf8').replace(/^\uFEFF/, ''));
  opts.maxPages = opts.maxPages || 80;
  opts.delayMs = opts.delayMs === undefined || opts.delayMs === null ? 300 : opts.delayMs;
  opts.warmup = opts.warmup || 800;
  for (const t of K.selftest()) chk('unit ' + t.name, t.ok, t.info);
  offlineRoundtrip();
  if (checks.some(c => !c.ok)) return finish('FAIL');
  if (opts.mode === 'selftest') return finish('PASS');
  env.envFile = fs.existsSync(opts.envPath) ? 'found' : 'missing';
  const cl = K.createClient({ envPath: opts.envPath, server: opts.server });
  secrets = cl.secrets;
  env.server = cl.mock ? 'mock' : 'real'; env.base = cl.base; env.kName = cl.kName; env.kLen = cl.kLen;
  await cl.auth();
  env.expires = cl.expires;
  chk('token', !!cl.token);
  if (opts.mode === 'verify') { await verifyTicks(cl); if (opts.daily !== false) await verifyDaily(cl); }
  else if (opts.mode === 'fetch') await fetchMode(cl);
  finish(checks.every(c => c.ok) ? 'PASS' : 'FAIL');
}

main().catch(e => {
  for (const l of String((e && e.stack) || e).split('\n').slice(0, 12)) errs.push(l);
  chk('uncaught', false, e && e.message);
  try { finish('FAIL'); } catch (e2) { console.error('finish failed: ' + e2.message); process.exitCode = 1; }
});
'@

foreach ($name in @($files.Keys)) {
  $p = Join-Path $uiDir $name
  if (Test-Path $p) { Copy-Item $p "$p.bak31" -Force }
  [IO.File]::WriteAllText($p, $files[$name], $utf8)
  $syn = & node --check $p 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { Write-Fallback "syntax $name" $syn; Write-Host "FAIL S2.fetch (syntax $name) -> $forOpus" -ForegroundColor Red; exit 1 }
}

$opt = [ordered]@{
  mode = $Mode; envPath = $EnvPath; server = $Server; delayMs = $DelayMs; maxPages = $MaxPages
  codes = $Codes; date = $Date; warmup = $WarmupBars; scope = '120'; market = 'AL'
  daily = (-not $NoDaily.IsPresent); ps = "$($PSVersionTable.PSVersion)"
}
$optFile = Join-Path $Root 'out\reports\s2_opts.json'
[IO.File]::WriteAllText($optFile, ($opt | ConvertTo-Json -Compress), $utf8)

$t0 = Get-Date
$out = & node (Join-Path $uiDir 's2.cjs') $Root $optFile 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
$fresh = (Test-Path $forOpus) -and ((Get-Item $forOpus).LastWriteTime -ge $t0)
if (-not $fresh) { Write-Fallback "runner crashed (exit $code)" $out; Write-Host "FAIL S2.fetch (runner crashed) -> $forOpus" -ForegroundColor Red; exit 1 }
$last = @($out | Where-Object { $_ -match '^(PASS|FAIL) S2' } | Select-Object -Last 1)
if ($last.Count -gt 0) { Write-Host $last[0] -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Red' }) } else { Write-Host "exit=$code -> $forOpus" }
exit $code
