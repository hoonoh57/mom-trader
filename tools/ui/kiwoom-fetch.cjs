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