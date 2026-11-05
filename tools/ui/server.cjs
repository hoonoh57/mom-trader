'use strict';
// mom-trader local server (server-1.2). ASCII only. Node built-ins only, binds 127.0.0.1.
// 1.1 (U1a): read-only research endpoints.
// 1.2 (U2): human review. GET /api/review, GET /charts/* (out/charts, read-only).
//   POST /api/label is the ONLY write path: append one row to out/human/review_log.csv.
//   review.csv (generator output) is never modified. Latest label per trade wins.
const http = require('http');
const fs = require('fs');
const path = require('path');
const ENG = require('./engines.cjs');
const VERSION = 'server-1.2';
const MIME = { '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.txt': 'text/plain; charset=utf-8' };
const RESEARCH = ['HANDOFF.md', 'CHARTER.md', 'STAGES.md', 'LEDGER.md'];
const REPO = 'hoonoh57/mom-trader';
const HUMAN = ['avoid', 'ok', 'unsure'];
const LOG_HEAD = 'ts,code,date,inHms,human,reason,tags,by';
const CHART_EXT = /\.(html?|svg|png)$/i;

function status(root) {
  const v = ENG.verify(root);
  let versions = {}, loadErr = '';
  if (v.ok) { try { versions = ENG.load(root).versions; } catch (e) { loadErr = e.message; } }
  else {
    loadErr = 'loading blocked: ' + v.rows.filter(function (r) { return !r.ok; }).map(function (r) { return r.id + ' ' + r.err; })
      .concat(v.missing.map(function (m) { return m + ' missing'; })).join('; ');
  }
  const rows = v.rows.map(function (r) {
    return { id: r.id, kind: r.kind, file: r.rel, want: String(r.want).slice(0, 12), got: String(r.got).slice(0, 12), ok: r.ok, err: r.err, src: r.src || '' };
  });
  const passed = rows.filter(function (r) { return r.ok; }).length;
  const ok = v.ok && !loadErr;
  return { server: VERSION, engines: ENG.VERSION, node: process.version, root: root, time: new Date().toISOString(),
    ok: ok, blocked: !ok, passed: passed, total: rows.length, failed: rows.length - passed, missing: v.missing,
    rows: rows, versions: versions, loadErr: loadErr };
}

function readText(f) {
  try {
    const st = fs.statSync(f);
    return { ok: true, bytes: st.size, mtime: st.mtime.toISOString(), text: fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, '') };
  } catch (e) { return { ok: false, bytes: 0, mtime: '', text: '', err: e.code || e.message }; }
}

function pubHead(root) {
  const g = path.join(path.resolve(root, '..', '..', '..', 'mom-trader-pub'), '.git');
  try {
    let h = fs.readFileSync(path.join(g, 'HEAD'), 'utf8').trim();
    if (h.indexOf('ref: ') === 0) {
      const ref = h.slice(5).trim();
      const rf = path.join(g, ref);
      if (fs.existsSync(rf)) h = fs.readFileSync(rf, 'utf8').trim();
      else {
        h = '';
        fs.readFileSync(path.join(g, 'packed-refs'), 'utf8').split(/\r?\n/).forEach(function (ln) {
          const m = ln.match(/^([0-9a-f]{40}) (.+)$/); if (m && m[2] === ref) h = m[1];
        });
      }
    }
    if (!/^[0-9a-f]{40}$/.test(h)) return { ok: false, sha: '', err: 'bad head' };
    return { ok: true, sha: h, raw: 'https://raw.githubusercontent.com/' + REPO + '/' + h + '/' };
  } catch (e) { return { ok: false, sha: '', err: e.code || e.message }; }
}

function research(root) {
  const dir = path.join(root, 'research');
  const files = RESEARCH.map(function (n) { const r = readText(path.join(dir, n)); r.name = n; return r; });
  return { ok: files.every(function (f) { return f.ok; }), files: files, head: pubHead(root), time: new Date().toISOString() };
}

function result(root) { const r = readText(path.join(root, 'out', 'FOR_OPUS.txt')); r.name = 'out/FOR_OPUS.txt'; return r; }

function csvParse(text) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(f); f = ''; }
    else if (ch === '\n') { row.push(f.replace(/\r$/, '')); rows.push(row); row = []; f = ''; }
    else f += ch;
  }
  if (f.length || row.length) { row.push(f.replace(/\r$/, '')); rows.push(row); }
  return rows;
}
function csvCell(s) { s = String(s == null ? '' : s); return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
function keyOf(code, date, inHms) { return String(code) + '|' + String(date) + '|' + String(+inHms); }

function chartMap(root) {
  const base = path.join(root, 'out', 'charts'), m = {};
  let dirs = [];
  try { dirs = fs.readdirSync(base, { withFileTypes: true }).filter(function (d) { return d.isDirectory(); }).map(function (d) { return d.name; }).sort(); }
  catch (e) { return m; }
  dirs.forEach(function (d) {
    let fl = [];
    try { fl = fs.readdirSync(path.join(base, d)); } catch (e) { return; }
    fl.forEach(function (f) { if (CHART_EXT.test(f)) m[f] = d + '/' + f; });
  });
  return m;
}

function loadLog(root) {
  const r = readText(path.join(root, 'out', 'human', 'review_log.csv')), last = {};
  let n = 0;
  if (!r.ok) return { last: last, n: 0 };
  const rows = csvParse(r.text);
  const ix = {}; (rows.shift() || []).forEach(function (c, i) { ix[c.trim()] = i; });
  rows.forEach(function (c) {
    if (c.length < 5) return;
    n++;
    last[keyOf(c[ix.code], c[ix.date], c[ix.inHms])] = { ts: c[ix.ts] || '', human: c[ix.human] || '', reason: c[ix.reason] || '', tags: c[ix.tags] || '' };
  });
  return { last: last, n: n };
}

function review(root) {
  const r = readText(path.join(root, 'out', 'human', 'review.csv'));
  if (!r.ok) return { ok: false, err: 'review.csv ' + r.err, rows: [], cnt: { total: 0, labeled: 0, avoid: 0, ok: 0, unsure: 0, chart: 0 } };
  const all = csvParse(r.text).filter(function (c) { return c.length > 1 || (c[0] && c[0].trim()); });
  const head = (all.shift() || []).map(function (s) { return s.trim(); });
  const cm = chartMap(root), lg = loadLog(root);
  const rows = all.map(function (c, i) {
    const o = { i: i + 1 };
    head.forEach(function (k, j) { o[k] = c[j] == null ? '' : c[j]; });
    const L = lg.last[keyOf(o.code, o.date, o.inHms)];
    o.h = L ? L.human : (o.human || '');
    o.hReason = L ? L.reason : (o.reason || '');
    o.hTags = L ? L.tags : '';
    o.hTs = L ? L.ts : '';
    o.chartUrl = o.chart && cm[o.chart] ? '/charts/' + cm[o.chart] : '';
    return o;
  });
  const cnt = { total: rows.length, labeled: 0, avoid: 0, ok: 0, unsure: 0, chart: 0 };
  rows.forEach(function (o) { if (o.h) cnt.labeled++; if (HUMAN.indexOf(o.h) >= 0) cnt[o.h]++; if (o.chartUrl) cnt.chart++; });
  return { ok: true, head: head, rows: rows, cnt: cnt, logRows: lg.n, mtime: r.mtime };
}

function clean(s, max) { return String(s == null ? '' : s).replace(/[\r\n\t]+/g, ' ').trim().slice(0, max); }
function addLabel(root, b) {
  const code = clean(b.code, 12), date = clean(b.date, 8), inHms = clean(b.inHms, 6);
  const human = clean(b.human, 10), reason = clean(b.reason, 300);
  const tags = clean(b.tags, 120).replace(/[^0-9A-Za-z_\-|\uAC00-\uD7A3]/g, '');
  if (!/^[0-9A-Z]{6}$/.test(code) || !/^\d{8}$/.test(date) || !/^\d{5,6}$/.test(inHms)) return { code: 400, err: 'bad key' };
  if (HUMAN.indexOf(human) < 0) return { code: 400, err: 'human must be ' + HUMAN.join('|') };
  const rv = review(root);
  if (!rv.ok) return { code: 500, err: rv.err };
  const k = keyOf(code, date, inHms);
  if (!rv.rows.some(function (o) { return keyOf(o.code, o.date, o.inHms) === k; })) return { code: 404, err: 'trade not in review.csv' };
  const f = path.join(root, 'out', 'human', 'review_log.csv');
  const ts = new Date().toISOString();
  const pre = fs.existsSync(f) ? '' : LOG_HEAD + '\r\n';
  fs.appendFileSync(f, pre + [ts, code, date, inHms, human, reason, tags, 'ui'].map(csvCell).join(',') + '\r\n', 'utf8');
  return { code: 200, ok: true, ts: ts, key: k };
}

function handoff(root) {
  const R = research(root);
  const L = [];
  L.push('=== mom-trader HANDOFF PACK ' + R.time + ' ===');
  L.push('GOAL-1 / GOAL-2: see research/CHARTER.md below. Apply them to every judgment.');
  L.push('repo: https://github.com/' + REPO);
  L.push(R.head.ok ? 'HEAD=' + R.head.sha : 'HEAD=unknown (' + R.head.err + ')');
  if (R.head.ok) { L.push('RAW=' + R.head.raw); L.push('TASK=' + R.head.raw + 'out/FOR_OPUS.txt'); }
  L.push('note: HEAD is the last pushed mirror. Local edits after the last 41_pub -Push are not in it.');
  L.push('read order: HANDOFF -> CHARTER -> LEDGER -> STAGES -> PUB_INDEX.txt');
  try {
    const c = review(root).cnt;
    L.push('human review: labeled ' + c.labeled + '/' + c.total + ' (avoid ' + c.avoid + ', ok ' + c.ok + ', unsure ' + c.unsure + '), log = out/human/review_log.csv');
  } catch (e) { L.push('human review: unreadable ' + e.message); }
  R.files.forEach(function (f) {
    L.push('');
    L.push('----- research/' + f.name + (f.ok ? ' bytes=' + f.bytes + ' mtime=' + f.mtime : ' MISSING ' + f.err) + ' -----');
    if (f.ok) L.push(f.text.replace(/\s+$/, ''));
  });
  L.push('');
  L.push('=== end of pack ===');
  const text = L.join('\n');
  return { ok: R.ok, head: R.head, chars: text.length, text: text };
}

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
}
function sendJson(res, code, o) { send(res, code, MIME['.json'], JSON.stringify(o)); }
function sameOrigin(req) {
  const host = String(req.headers.host || '');
  if (!/^(127\.0\.0\.1|localhost):\d+$/.test(host)) return false;
  const o = req.headers.origin;
  if (o && o !== 'http://' + host) return false;
  const sf = req.headers['sec-fetch-site'];
  if (sf && sf !== 'same-origin' && sf !== 'none') return false;
  return true;
}
function serveFile(res, f) {
  fs.readFile(f, function (err, buf) {
    if (err) return send(res, 404, MIME['.txt'], 'not found');
    send(res, 200, MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', buf);
  });
}

function create(root) {
  root = path.resolve(root);
  const uiDir = path.join(root, 'ui');
  const chartDir = path.join(root, 'out', 'charts');
  const API = { '/api/status': status, '/api/research': research, '/api/result': result, '/api/handoff': handoff, '/api/review': review };
  const srv = http.createServer(function (req, res) {
    let u;
    try { u = new URL(req.url, 'http://127.0.0.1'); } catch (e) { return send(res, 400, MIME['.txt'], 'bad url'); }
    if (req.method === 'POST' && u.pathname === '/api/label') {
      if (!sameOrigin(req)) return sendJson(res, 403, { ok: false, error: 'origin rejected' });
      if (!/^application\/json\b/i.test(String(req.headers['content-type'] || ''))) return sendJson(res, 415, { ok: false, error: 'json only' });
      const parts = []; let size = 0, dead = false;
      req.on('data', function (ch) {
        if (dead) return;
        size += ch.length;
        if (size > 4096) { dead = true; sendJson(res, 413, { ok: false, error: 'too large' }); req.destroy(); }
        else parts.push(ch);
      });
      req.on('end', function () {
        if (dead) return;
        let b;
        try { b = JSON.parse(Buffer.concat(parts).toString('utf8')); } catch (e) { return sendJson(res, 400, { ok: false, error: 'bad json' }); }
        let r;
        try { r = addLabel(root, b || {}); } catch (e) { r = { code: 500, err: e.message }; }
        sendJson(res, r.code, r.code === 200 ? r : { ok: false, error: r.err });
      });
      return;
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, MIME['.txt'], 'method not allowed');
    if (Object.prototype.hasOwnProperty.call(API, u.pathname)) {
      let s;
      try { s = API[u.pathname](root); } catch (e) { return sendJson(res, 500, { ok: false, error: e.message }); }
      return sendJson(res, 200, s);
    }
    let p;
    if (u.pathname.indexOf('/charts/') === 0) {
      try { p = decodeURIComponent(u.pathname.slice(8)); } catch (e) { return send(res, 400, MIME['.txt'], 'bad path'); }
      const cf = path.normalize(path.join(chartDir, p));
      if (cf.indexOf(chartDir + path.sep) !== 0 || !CHART_EXT.test(cf)) return send(res, 403, MIME['.txt'], 'forbidden');
      return serveFile(res, cf);
    }
    try { p = decodeURIComponent(u.pathname === '/' ? '/index.html' : u.pathname); } catch (e) { return send(res, 400, MIME['.txt'], 'bad path'); }
    const f = path.normalize(path.join(uiDir, p));
    if (f.indexOf(uiDir + path.sep) !== 0) return send(res, 403, MIME['.txt'], 'forbidden');
    serveFile(res, f);
  });
  return { srv: srv, status: function () { return status(root); } };
}

module.exports = { VERSION: VERSION, create: create, status: status, research: research, result: result, handoff: handoff, review: review, addLabel: addLabel };

if (require.main === module) {
  const root = path.resolve(process.argv[2] || path.join(__dirname, '..', '..'));
  const port = +process.argv[3] || 3100;
  const s = create(root);
  s.srv.on('error', function (e) {
    console.error('SERVER ERROR ' + e.message + (e.code === 'EADDRINUSE' ? ' (port in use: close the other server or use another port)' : ''));
    process.exit(1);
  });
  s.srv.listen(port, '127.0.0.1', function () {
    const st = s.status();
    console.log('mom-trader UI  http://127.0.0.1:' + port + '/   ' + VERSION + '   engines ' + (st.ok ? 'OK ' + st.passed + '/' + st.total : 'BLOCKED'));
    console.log('Ctrl+C to stop');
  });
}