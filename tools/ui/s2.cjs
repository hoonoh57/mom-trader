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