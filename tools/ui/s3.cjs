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