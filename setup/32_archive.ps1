#requires -Version 5.1
# S3: tick archive archive-1.0 (ASCII only). Writes tools\ui\archive.cjs, tools\ui\s3.cjs and runs node.
# Result file: out\FOR_OPUS.txt  (attach this file only)
param(
  [ValidateSet('plan','run')][string]$Mode = 'plan',
  [string]$ScreenCsv = '',
  [string]$Since = '',
  [string]$Until = '',
  [int]$MaxCodes = 0,
  [int]$MaxMinutes = 0,
  [int]$WarmupBars = 800,
  [ValidateSet('AUTO','MOCK','REAL')][string]$Server = 'AUTO',
  [string]$EnvPath = 'E:\parent\security\.env',
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [int]$MaxPages = 400,
  [int]$DelayMs = 300,
  [switch]$NoDaily,
  [switch]$NoParity
)
$ErrorActionPreference = 'Continue'
$utf8 = New-Object Text.UTF8Encoding($false)
$forOpus = Join-Path $Root 'out\FOR_OPUS.txt'
$uiDir = Join-Path $Root 'tools\ui'

function Write-Fallback([string]$stage, [string[]]$lines) {
  $t = New-Object System.Collections.Generic.List[string]
  $t.Add("#MT-REPORT v=report-1.0 step=S3.archive ver=archive-1.0 verdict=FAIL ts=$((Get-Date).ToUniversalTime().ToString('o')) dur=-")
  $t.Add("#ENV ps=$($PSVersionTable.PSVersion) writer=powershell-fallback")
  $t.Add("#FAIL $stage")
  $t.Add('#DATA output')
  foreach ($l in @($lines)) { $t.Add([string]$l) }
  $t.Add('#END')
  New-Item -ItemType Directory -Force -Path (Split-Path $forOpus) | Out-Null
  [IO.File]::WriteAllLines($forOpus, $t, $utf8)
}
function Stop-Fail([string]$stage, [string[]]$lines) { Write-Fallback $stage $lines; Write-Host "FAIL S3.archive ($stage) -> $forOpus" -ForegroundColor Red; exit 1 }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Stop-Fail 'node not found' @('node not in PATH') }
if (-not (Test-Path (Join-Path $uiDir 'kiwoom-fetch.cjs'))) { Stop-Fail 'kiwoom-fetch.cjs missing' @('run 31_fetch.ps1 first (S2)') }
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'out\reports'), (Join-Path $Root 'data\screen') | Out-Null

if ($ScreenCsv) {
  if (-not (Test-Path -LiteralPath $ScreenCsv)) { Stop-Fail 'screen csv not found' @($ScreenCsv) }
  Copy-Item -LiteralPath $ScreenCsv -Destination (Join-Path $Root 'data\screen') -Force
}

$files = [ordered]@{}
$files['archive.cjs'] = @'
'use strict';
// archive-1.0: screen CSV -> stock-day list -> one backward ka10079 fetch per code -> per-date files via kiwoom-fetch buildTick
const K = require('./kiwoom-fetch.cjs');
const VERSION = 'archive-1.0';
const ST_OK = '\uC815\uC0C1';
const asList = x => (Array.isArray(x) ? x : (x && typeof x === 'object' ? [x] : []));

function decode(buf) {
  if (buf.length >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) return { text: buf.slice(3).toString('utf8'), enc: 'utf8-bom' };
  try { return { text: new TextDecoder('utf-8', { fatal: true }).decode(buf), enc: 'utf8' }; } catch (e) { /* not utf8 */ }
  return { text: new TextDecoder('euc-kr').decode(buf), enc: 'cp949' };
}

function splitCsvLine(s) {
  const out = []; let cur = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) { if (ch === '"') { if (s[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

// columns by position: 1 time, 2 date, 3 code, 4 name, 7 status
function parseScreen(text) {
  const lines = text.split(/\r\n|\n|\r/);
  const header = splitCsvLine(lines[0] || '').map(s => s.trim());
  const ok = header.length >= 8 && header[3] === 'code' && header[4] === 'name';
  const st = { total: 0, byStatus: {}, badCode: 0, badDate: 0, minDate: '', maxDate: '' };
  const rows = [];
  if (!ok) return { ok, header, rows, st };
  for (let i = 1; i < lines.length; i++) {
    const s = lines[i];
    if (!s.trim()) continue;
    const c = splitCsvLine(s);
    st.total++;
    const date = (c[2] || '').trim(), status = (c[7] || '').trim();
    let code = (c[3] || '').trim();
    if (code.length === 7 && code[0] === 'A') code = code.slice(1);
    st.byStatus[status] = (st.byStatus[status] || 0) + 1;
    if (!/^\d{8}$/.test(date)) { st.badDate++; continue; }
    if (!/^[0-9A-Z]{6}$/.test(code)) { st.badCode++; continue; }
    if (!st.minDate || date < st.minDate) st.minDate = date;
    if (date > st.maxDate) st.maxDate = date;
    rows.push({ date, code, ok: status === ST_OK, time: (c[1] || '').trim() });
  }
  return { ok, header, rows, st };
}

function planItems(rows, since, until) {
  const m = new Map();
  for (const r of rows) {
    if (!r.ok || r.date < since || r.date > until) continue;
    if (!m.has(r.code)) m.set(r.code, new Set());
    m.get(r.code).add(r.date);
  }
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  return [...m].map(([code, s]) => ({ code, dates: [...s].sort() }))
    .sort((a, b) => cmp(a.dates[0], b.dates[0]) || cmp(a.code, b.code));
}

// same stop rule as 09 (prev bars before 'oldest' >= warmup), market AL, scope 120
async function fetchBack(cl, q) {
  const rows = [];
  let next = '', end = '', bad = 0, pages = 0, prevN = 0;
  for (let page = 1; page <= q.maxPages; page++) {
    pages = page;
    const r = await cl.chart('ka10079', { stk_cd: q.code + '_AL', tic_scope: '120', upd_stkpc_tp: '1' }, page > 1 ? next : '');
    const rc = String(r.json.return_code);
    if (rc !== '0') throw new Error('ka10079 return_code=' + rc + ' msg=' + r.json.return_msg);
    const chunk = asList(r.json.stk_tic_chart_qry);
    if (!chunk.length) { end = 'empty'; break; }
    for (const it of chunk) { const row = K.tickRow(it); if (row) { rows.push(row); if (row.date < q.oldest) prevN++; } else bad++; }
    if (prevN >= q.warmup) { end = 'warmup'; break; }
    const cont = r.headers.get('cont-yn') || '', nk = r.headers.get('next-key') || '';
    if (cont.toUpperCase() !== 'Y' || !nk) { end = 'cont_end(' + cont + ')'; break; }
    next = nk;
    await K.sleep(q.delayMs);
  }
  if (!end) end = 'max_pages(' + q.maxPages + ')';
  let minD = '', maxD = '';
  for (const x of rows) { if (!minD || x.date < minD) minD = x.date; if (x.date > maxD) maxD = x.date; }
  return { rows, pages, end, bad, minD, maxD };
}

function selftest() {
  const R = [];
  const t = (name, fn) => {
    try { const v = fn(); R.push({ name, ok: v === true, info: v === true ? '' : String(v) }); }
    catch (e) { R.push({ name, ok: false, info: 'threw ' + e.message }); }
  };
  const eq = (a, b) => (JSON.stringify(a) === JSON.stringify(b) ? true : 'expected ' + JSON.stringify(b) + ' got ' + JSON.stringify(a));
  t('decode', () => eq([decode(Buffer.from([0xEF, 0xBB, 0xBF, 0xED, 0x95, 0x9C])).text, decode(Buffer.from([0xED, 0x95, 0x9C])).enc,
    decode(Buffer.from([0xC7, 0xD1])).text, decode(Buffer.from([0xC7, 0xD1])).enc], ['\uD55C', 'utf8', '\uD55C', 'cp949']));
  t('splitCsvLine', () => eq(splitCsvLine('a,"12,640","x""y",,-'), ['a', '12,640', 'x"y', '', '-']));
  t('parseScreen', () => {
    const txt = 'h0,h1,h2,code,name,h5,h6,h7\r\n5%,09:05,20260506,A001500,n,"12,640","1,254.1",' + ST_OK + ',+0.47%\r\n' +
      '5%,09:05,20260506,A0011A0,n,-,-,X,-\r\n5%,09:05,2026050,A001500,n,1,1,' + ST_OK + '\r\n';
    const p = parseScreen(txt);
    return eq([p.ok, p.rows.length, p.rows[0].code, p.rows[0].ok, p.rows[1].code, p.rows[1].ok, p.st.badDate], [true, 2, '001500', true, '0011A0', false, 1]);
  });
  t('planItems', () => {
    const rows = [{ date: '20261007', code: 'B00000', ok: true }, { date: '20261006', code: 'A00000', ok: true }, { date: '20261006', code: 'A00000', ok: true },
      { date: '20261008', code: 'A00000', ok: true }, { date: '20261001', code: 'C00000', ok: true }, { date: '20261006', code: 'D00000', ok: false }];
    return eq(planItems(rows, '20261002', '20261031'), [{ code: 'A00000', dates: ['20261006', '20261008'] }, { code: 'B00000', dates: ['20261007'] }]);
  });
  t('multi-day slice equals single-day fetch', () => {
    const mk = (ts, p) => ({ ts, date: ts.slice(0, 8), time: ts.slice(8), o: p, h: p, l: p, c: p, v: 1, amt: p });
    const all = [mk('20261008090000', 9), mk('20261007090100', 8), mk('20261007090000', 7), mk('20261006090200', 6),
      mk('20261006090100', 5), mk('20261006090000', 4), mk('20261002090000', 3)];
    const a = K.buildTick(all, '20261007', 2).text, b = K.buildTick(all.slice(0, 5), '20261007', 2).text;
    return a === b ? true : 'differs';
  });
  return R;
}

module.exports = { VERSION, ST_OK, decode, splitCsvLine, parseScreen, planItems, fetchBack, selftest };
'@

$files['s3.cjs'] = @'
'use strict';
// S3 runner: screen CSV -> plan / archive ticks into data\rest\ticks. Writes out\FOR_OPUS.txt
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const K = require('./kiwoom-fetch.cjs');
const A = require('./archive.cjs');
const ROOT = process.argv[2], OPT = process.argv[3];
const T0 = Date.now();
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const P = (...a) => path.join(ROOT, ...a);
const z = n => String(n).padStart(2, '0');
const stamp = d => '' + d.getFullYear() + z(d.getMonth() + 1) + z(d.getDate()) + '-' + z(d.getHours()) + z(d.getMinutes()) + z(d.getSeconds());
const kstDate = ms => new Date(ms + 9 * 3600e3).toISOString().slice(0, 10).replace(/-/g, '');
const cut = (s, n) => { s = String(s); n = n || 220; return s.length > n ? s.slice(0, n) + '...' : s; };
const checks = [], blocks = [], errs = [], summary = [];
const env = { envFile: '-', server: '-', base: '-', kName: '-', kLen: 0, expires: '-' };
const LCOLS = ['fetched_at', 'kind', 'api_id', 'code', 'market', 'scope', 'target', 'warmup_req', 'pages', 'bars_target', 'bars_warmup', 'end_reason', 'bad_rows', 'file', 'sha12', 'server'];
let secrets = [], opts = {}, finished = false;

function mask(s) { s = String(s); for (const x of secrets) if (x && x.length >= 6) s = s.split(x).join('***(len=' + x.length + ')'); return s; }
function chk(name, ok, info) { checks.push({ name, ok: !!ok, info: info ? mask(info) : '' }); return !!ok; }
function block(name, rows) { blocks.push({ name, rows: rows.map(mask) }); }
const outF = (c, d) => P('data', 'rest', 'ticks', c + '_AL_120t_' + d + '.csv');

function ledger(r) {
  const p = P('data', 'rest', 'ledger.csv');
  fs.mkdirSync(path.dirname(p), { recursive: true });
  if (!fs.existsSync(p)) fs.writeFileSync(p, LCOLS.join(',') + '\r\n', 'utf8');
  r.fetched_at = stamp(new Date()); r.server = env.server;
  fs.appendFileSync(p, LCOLS.map(c => String(r[c] === null || r[c] === undefined ? '' : r[c]).replace(/[,\r\n]/g, ' ')).join(',') + '\r\n', 'utf8');
}

function readSkip() {
  const s = new Set(), p = P('data', 'rest', 'ledger.csv');
  if (!fs.existsSync(p)) return s;
  for (const line of fs.readFileSync(p, 'utf8').split(/\r\n|\n/).slice(1)) {
    const c = line.split(',');
    if (c[1] === 'archive' && /^(expired|no_bars)/.test(c[11] || '')) s.add(c[3] + '|' + c[6]);
  }
  return s;
}

function loadScreen() {
  const dir = P('data', 'screen');
  const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter(f => /\.csv$/i.test(f)).sort() : [];
  if (!files.length) { chk('screen csv', false, 'no .csv in data\\screen (use -ScreenCsv <path>)'); return null; }
  const rows = [], lines = [];
  let maxDate = '';
  for (const f of files) {
    const dec = A.decode(fs.readFileSync(path.join(dir, f)));
    const p = A.parseScreen(dec.text);
    const stTxt = Object.entries(p.st.byStatus).map(([k, v]) => k + '=' + v).join(' ');
    lines.push(f + ' enc=' + dec.enc + ' header=' + (p.ok ? 'ok' : 'BAD') + ' rows=' + p.st.total + ' range=' + p.st.minDate + '~' + p.st.maxDate +
      ' badDate=' + p.st.badDate + ' badCode=' + p.st.badCode + ' status: ' + stTxt);
    if (!p.ok) { lines.push('   header: ' + cut(p.header.join('|'), 400)); chk('screen header ' + f, false, 'expected col4=code col5=name'); continue; }
    for (const r of p.rows) rows.push(r);
    if (p.st.maxDate > maxDate) maxDate = p.st.maxDate;
  }
  block('screen', lines);
  if (!chk('screen rows', rows.length > 0, 'no usable rows')) return null;
  return { rows, maxDate };
}

function dateTable(perDate) {
  const L = ['date      need have skip | saved warmShort expired noBars trunc err'];
  for (const d of Object.keys(perDate).sort()) {
    const e = perDate[d];
    L.push(d + ' ' + [e.need, e.have, e.skip].map(x => String(x).padStart(4)).join(' ') + ' | ' +
      [e.saved, e.short, e.expired, e.nobars, e.trunc, e.err].map(x => String(x).padStart(5)).join(' '));
  }
  return L;
}

async function parity(cl) {
  const f = P('data', 'ticks', '0011A0_AL_120t_20261102.csv');
  if (!fs.existsSync(f)) { chk('parity 0011A0', false, 'reference file missing: ' + f); return; }
  const r = await A.fetchBack(cl, { code: '0011A0', oldest: '20261102', warmup: 800, maxPages: opts.maxPages, delayMs: opts.delayMs });
  const b = K.buildTick(r.rows, '20261102', 800);
  const d = K.firstDiff(fs.readFileSync(f, 'utf8'), b.text);
  chk('parity multi-day path 0011A0 20261102', !d, d ? 'L' + d.line + ' old=' + cut(d.a) + ' new=' + cut(d.b) : '');
  summary.push('parity ' + (d ? 'DIFF' : 'MATCH') + ' (pages=' + r.pages + ' end=' + r.end + ' range=' + r.minD + '~' + r.maxD + ')');
}

async function archive(cl, items, perDate, skip, today) {
  const work = items.map(it => ({ code: it.code, pend: it.dates.filter(d => d < today && !fs.existsSync(outF(it.code, d)) && !skip.has(it.code + '|' + d)) }))
    .filter(w => w.pend.length)
    .sort((a, b) => (a.pend[0] < b.pend[0] ? -1 : a.pend[0] > b.pend[0] ? 1 : a.code < b.code ? -1 : 1));
  const limit = opts.maxCodes > 0 ? Math.min(opts.maxCodes, work.length) : work.length;
  const problems = [];
  const tot = { saved: 0, short: 0, exp: 0, nb: 0, tr: 0 };
  let done = 0, pagesSum = 0, errN = 0, stopped = '';
  const tStart = Date.now();
  for (let i = 0; i < limit; i++) {
    if (opts.maxMinutes > 0 && (Date.now() - tStart) / 60000 >= opts.maxMinutes) { stopped = 'maxMinutes'; break; }
    if (Date.now() - cl.authAt > 6 * 3600e3) { await cl.auth(); cl.authAt = Date.now(); }
    const w = work[i], t1 = Date.now();
    let r = null;
    for (let a = 1; a <= 2 && !r; a++) {
      try { r = await A.fetchBack(cl, { code: w.code, oldest: w.pend[0], warmup: opts.warmup, maxPages: opts.maxPages, delayMs: opts.delayMs }); }
      catch (e) {
        if (a === 2) { errN++; problems.push(w.code + ' ERROR ' + cut(e.message)); for (const d of w.pend) perDate[d].err++; }
        else await K.sleep(3000);
      }
    }
    const cnt = { saved: 0, short: 0, exp: 0, nb: 0, tr: 0 };
    if (r) {
      pagesSum += r.pages;
      const trunc = r.end.startsWith('max_pages'), edgeEnd = !trunc && r.end !== 'warmup';
      for (const d of w.pend) {
        const e = perDate[d];
        const base = { kind: 'archive', api_id: 'ka10079', code: w.code, market: 'AL', scope: '120', target: d, warmup_req: opts.warmup, pages: r.pages, bad_rows: r.bad };
        if (trunc && (!r.minD || d <= r.minD)) { e.trunc++; cnt.tr++; problems.push(w.code + ' ' + d + ' TRUNC end=' + r.end + ' minD=' + r.minD); continue; }
        const b = K.buildTick(r.rows, d, opts.warmup);
        if (!b.tgtN) {
          const status = edgeEnd && (!r.minD || d < r.minD) ? 'expired' : 'no_bars';
          if (status === 'expired') { e.expired++; cnt.exp++; } else { e.nobars++; cnt.nb++; }
          ledger(Object.assign(base, { bars_target: 0, bars_warmup: b.keepN, end_reason: status + ';' + r.end, file: '', sha12: '' }));
          continue;
        }
        const flags = [];
        if (b.keepN < opts.warmup) flags.push('warm' + b.keepN);
        if (edgeEnd && d === r.minD) flags.push('edge');
        if (b.nonMono) flags.push('nonMono' + b.nonMono);
        if (b.ohlcBad) flags.push('ohlcBad' + b.ohlcBad);
        if (r.bad) flags.push('badRows' + r.bad);
        const buf = Buffer.from(b.text, 'utf8'), f = outF(w.code, d), tmp = f + '.tmp';
        fs.mkdirSync(path.dirname(f), { recursive: true });
        fs.writeFileSync(tmp, buf);
        fs.renameSync(tmp, f);
        e.saved++; cnt.saved++;
        if (b.keepN < opts.warmup) { e.short++; cnt.short++; }
        if (flags.some(x => !x.startsWith('warm'))) problems.push(w.code + ' ' + d + ' ' + flags.join(' '));
        ledger(Object.assign(base, { bars_target: b.tgtN, bars_warmup: b.keepN, end_reason: 'saved' + (flags.length ? '[' + flags.join(' ') + ']' : '') + ';' + r.end,
          file: 'data/rest/ticks/' + path.basename(f), sha12: sha(buf).slice(0, 12) }));
      }
      for (const k of Object.keys(tot)) tot[k] += cnt[k];
    }
    if (!opts.noDaily && !fs.existsSync(P('data', 'rest', 'daily', w.code + '.csv'))) {
      try {
        const dr = await K.fetchDaily(cl, { code: w.code, baseDate: opts.untilUsed, rawDir: '' });
        const nb = Buffer.from(dr.text, 'utf8'), f = P('data', 'rest', 'daily', w.code + '.csv');
        fs.mkdirSync(path.dirname(f), { recursive: true });
        fs.writeFileSync(f + '.tmp', nb); fs.renameSync(f + '.tmp', f);
        ledger({ kind: 'daily', api_id: 'ka10081', code: w.code, market: 'KRX', target: opts.untilUsed, pages: 1, bars_target: dr.rows.length, end_reason: 'single', bad_rows: 0, file: 'data/rest/daily/' + w.code + '.csv', sha12: sha(nb).slice(0, 12) });
      } catch (e) { problems.push(w.code + ' DAILY ' + cut(e.message)); }
    }
    done++;
    console.log('[' + done + '/' + limit + '] ' + w.code + ' pend=' + w.pend.length + ' pages=' + (r ? r.pages : '-') + ' end=' + (r ? r.end : 'ERROR') +
      ' saved=' + cnt.saved + ' short=' + cnt.short + ' expired=' + cnt.exp + ' trunc=' + cnt.tr + ' ' + ((Date.now() - t1) / 1000).toFixed(1) + 's');
    await K.sleep(opts.delayMs);
  }
  const el = (Date.now() - tStart) / 1000, avg = done ? el / done : 0;
  summary.push('run codes=' + done + '/' + work.length + ' pages=' + pagesSum + ' saved=' + tot.saved + ' warmShort=' + tot.short + ' expired=' + tot.exp +
    ' noBars=' + tot.nb + ' trunc=' + tot.tr + ' err=' + errN + ' elapsed=' + (el / 60).toFixed(1) + 'm avg=' + avg.toFixed(1) + 's/code' +
    ' remainingCodes=' + (work.length - done) + ' estRemaining=' + ((work.length - done) * avg / 60).toFixed(0) + 'm' + (stopped ? ' stopped=' + stopped : ''));
  if (problems.length) block('problems', problems.slice(0, 120).concat(problems.length > 120 ? ['... +' + (problems.length - 120) + ' more (see detail)'] : []));
  chk('fetch errors', errN === 0, errN + ' codes failed (rerun resumes)');
  return problems;
}

function finish(verdict, extra) {
  if (finished) return;
  finished = true;
  const ts = new Date();
  const dir = P('out', 'reports', 'S3.archive_' + stamp(ts));
  fs.mkdirSync(path.join(dir, 'detail'), { recursive: true });
  const pass = checks.filter(c => c.ok).length;
  const L = [];
  L.push('#MT-REPORT v=report-1.0 step=S3.archive ver=' + A.VERSION + ' verdict=' + verdict + ' ts=' + ts.toISOString() + ' dur=' + ((Date.now() - T0) / 1000).toFixed(1) + 's');
  L.push('#DIR ' + dir);
  L.push('#ENV node=' + process.version + ' ps=' + (opts.ps || '-') + ' mode=' + (opts.mode || '-') + ' server=' + env.server + ' base=' + env.base + ' key=' + env.kName + ' len=' + env.kLen + ' tokenExp=' + env.expires + ' envFile=' + env.envFile);
  L.push('#CHK ' + pass + '/' + checks.length + ' ' + (pass === checks.length ? 'PASS' : 'FAIL'));
  for (const s of summary) L.push('#SUM ' + s);
  for (const c of checks) if (!c.ok) L.push('#FAIL ' + c.name + (c.info ? ' :: ' + c.info : ''));
  for (const b of blocks) { L.push('#DATA ' + b.name + ' lines=' + b.rows.length); for (const r of b.rows) L.push(r); L.push('#END'); }
  if (errs.length) { L.push('#ERR'); for (const e of errs) L.push(mask(e)); L.push('#END'); }
  let text = L.join('\r\n') + '\r\n';
  if (text.length > 200000) text = text.slice(0, 200000) + '\r\n#TRUNCATED\r\n';
  fs.writeFileSync(path.join(dir, 'report.txt'), text, 'utf8');
  fs.writeFileSync(path.join(dir, 'detail', 'results.json'), mask(JSON.stringify({ checks, blocks, errs, summary, problems: extra || [] }, null, 2)), 'utf8');
  fs.writeFileSync(P('out', 'FOR_OPUS.txt'), text, 'utf8');
  fs.writeFileSync(P('out', 'reports', 'LATEST.txt'), dir + '\r\n', 'utf8');
  if (verdict === 'PASS' && opts.mode === 'run' && fs.existsSync(P('docs', 'progress.md'))) {
    fs.appendFileSync(P('docs', 'progress.md'), '\r\n- ' + stamp(ts) + ' S3 ' + A.VERSION + ' run PASS: ' + summary.join(' | ') + '\r\n', 'utf8');
  }
  console.log(verdict + ' S3.archive -> ' + P('out', 'FOR_OPUS.txt'));
  process.exitCode = verdict === 'PASS' ? 0 : 1;
}

async function main() {
  opts = JSON.parse(fs.readFileSync(OPT, 'utf8').replace(/^\uFEFF/, ''));
  const today = kstDate(Date.now());
  for (const t of K.selftest()) chk('unit fetch ' + t.name, t.ok, t.info);
  for (const t of A.selftest()) chk('unit archive ' + t.name, t.ok, t.info);
  if (checks.some(c => !c.ok)) return finish('FAIL');
  const scr = loadScreen();
  if (!scr) return finish('FAIL');
  const since = opts.since || kstDate(Date.now() - 40 * 86400e3);
  const until = opts.until || scr.maxDate;
  opts.untilUsed = until;
  const items = A.planItems(scr.rows, since, until);
  const skip = readSkip();
  const perDate = {};
  let sd = 0, have = 0, known = 0;
  for (const it of items) for (const d of it.dates) {
    sd++;
    const e = perDate[d] || (perDate[d] = { need: 0, have: 0, skip: 0, saved: 0, short: 0, expired: 0, nobars: 0, trunc: 0, err: 0 });
    e.need++;
    if (fs.existsSync(outF(it.code, d))) { e.have++; have++; } else if (skip.has(it.code + '|' + d)) { e.skip++; known++; }
  }
  summary.push('window ' + since + '~' + until + ' today=' + today + ' stockDays=' + sd + ' codes=' + items.length + ' days=' + Object.keys(perDate).length + ' alreadySaved=' + have + ' knownSkip=' + known);
  if (!chk('window stock-days > 0', sd > 0, 'no status-OK rows in window (encoding? dates?)')) return finish('FAIL');
  if (opts.mode === 'plan') { block('window', dateTable(perDate)); return finish(checks.every(c => c.ok) ? 'PASS' : 'FAIL'); }

  env.envFile = fs.existsSync(opts.envPath) ? 'found' : 'missing';
  const cl = K.createClient({ envPath: opts.envPath, server: opts.server });
  secrets = cl.secrets;
  env.server = cl.mock ? 'mock' : 'real'; env.base = cl.base; env.kName = cl.kName; env.kLen = cl.kLen;
  await cl.auth();
  cl.authAt = Date.now();
  env.expires = cl.expires;
  chk('token', !!cl.token);
  if (opts.parity !== false) { await parity(cl); if (checks.some(c => !c.ok)) return finish('FAIL'); }
  const problems = await archive(cl, items, perDate, skip, today);
  block('window', dateTable(perDate));
  finish(checks.every(c => c.ok) ? 'PASS' : 'FAIL', problems);
}

main().catch(e => {
  for (const l of String((e && e.stack) || e).split('\n').slice(0, 12)) errs.push(l);
  chk('uncaught', false, e && e.message);
  try { finish('FAIL'); } catch (e2) { console.error('finish failed: ' + e2.message); process.exitCode = 1; }
});
'@

foreach ($name in @($files.Keys)) {
  $p = Join-Path $uiDir $name
  if (Test-Path $p) { Copy-Item $p "$p.bak32" -Force }
  [IO.File]::WriteAllText($p, $files[$name], $utf8)
  $syn = & node --check $p 2>&1 | ForEach-Object { "$_" }
  if ($LASTEXITCODE -ne 0) { Stop-Fail "syntax $name" $syn }
}

$opt = [ordered]@{
  mode = $Mode; envPath = $EnvPath; server = $Server; delayMs = $DelayMs; maxPages = $MaxPages
  since = $Since; until = $Until; maxCodes = $MaxCodes; maxMinutes = $MaxMinutes; warmup = $WarmupBars
  noDaily = $NoDaily.IsPresent; parity = (-not $NoParity.IsPresent); ps = "$($PSVersionTable.PSVersion)"
}
$optFile = Join-Path $Root 'out\reports\s3_opts.json'
[IO.File]::WriteAllText($optFile, ($opt | ConvertTo-Json -Compress), $utf8)

$t0 = Get-Date
$out = & node (Join-Path $uiDir 's3.cjs') $Root $optFile 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $s }
$code = $LASTEXITCODE
$fresh = (Test-Path $forOpus) -and ((Get-Item $forOpus).LastWriteTime -ge $t0)
if (-not $fresh) { Stop-Fail "runner crashed (exit $code)" $out }
exit $code
