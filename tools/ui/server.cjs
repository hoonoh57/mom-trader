'use strict';
// mom-trader local server (server-1.1). ASCII only. Node built-ins only, binds 127.0.0.1.
// 1.1 (U1a): read-only research endpoints. GET/HEAD only, fixed file whitelist, no write path.
const http = require('http');
const fs = require('fs');
const path = require('path');
const ENG = require('./engines.cjs');
const VERSION = 'server-1.1';
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.txt': 'text/plain; charset=utf-8' };
const RESEARCH = ['HANDOFF.md', 'CHARTER.md', 'STAGES.md', 'LEDGER.md'];
const REPO = 'hoonoh57/mom-trader';

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

function handoff(root) {
  const R = research(root);
  const L = [];
  L.push('=== mom-trader HANDOFF PACK ' + R.time + ' ===');
  L.push('GOAL-1 / GOAL-2: see research/CHARTER.md below. Apply them to every judgment.');
  L.push('repo: https://github.com/' + REPO);
  L.push(R.head.ok ? 'HEAD=' + R.head.sha : 'HEAD=unknown (' + R.head.err + ')');
  if (R.head.ok) L.push('RAW=' + R.head.raw);
  L.push('note: HEAD is the last pushed mirror. Local edits after the last 41_pub -Push are not in it.');
  L.push('read order: HANDOFF -> CHARTER -> LEDGER -> STAGES -> PUB_INDEX.txt');
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

function create(root) {
  root = path.resolve(root);
  const uiDir = path.join(root, 'ui');
  const API = { '/api/status': status, '/api/research': research, '/api/result': result, '/api/handoff': handoff };
  const srv = http.createServer(function (req, res) {
    if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, MIME['.txt'], 'method not allowed');
    let u;
    try { u = new URL(req.url, 'http://127.0.0.1'); } catch (e) { return send(res, 400, MIME['.txt'], 'bad url'); }
    if (Object.prototype.hasOwnProperty.call(API, u.pathname)) {
      let s;
      try { s = API[u.pathname](root); } catch (e) { return send(res, 500, MIME['.json'], JSON.stringify({ ok: false, error: e.message })); }
      return send(res, 200, MIME['.json'], JSON.stringify(s));
    }
    let p;
    try { p = decodeURIComponent(u.pathname === '/' ? '/index.html' : u.pathname); } catch (e) { return send(res, 400, MIME['.txt'], 'bad path'); }
    const f = path.normalize(path.join(uiDir, p));
    if (f.indexOf(uiDir + path.sep) !== 0) return send(res, 403, MIME['.txt'], 'forbidden');
    fs.readFile(f, function (err, buf) {
      if (err) return send(res, 404, MIME['.txt'], 'not found');
      send(res, 200, MIME[path.extname(f).toLowerCase()] || 'application/octet-stream', buf);
    });
  });
  return { srv: srv, status: function () { return status(root); } };
}

module.exports = { VERSION: VERSION, create: create, status: status, research: research, result: result, handoff: handoff };

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