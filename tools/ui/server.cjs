'use strict';
// mom-trader S1 local server (server-1.0). ASCII only. Node built-ins only, binds 127.0.0.1.
const http = require('http');
const fs = require('fs');
const path = require('path');
const ENG = require('./engines.cjs');
const VERSION = 'server-1.0';
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.txt': 'text/plain; charset=utf-8' };

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

function send(res, code, type, body) {
  res.writeHead(code, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(body);
}

function create(root) {
  root = path.resolve(root);
  const uiDir = path.join(root, 'ui');
  const srv = http.createServer(function (req, res) {
    let u;
    try { u = new URL(req.url, 'http://127.0.0.1'); } catch (e) { return send(res, 400, MIME['.txt'], 'bad url'); }
    if (u.pathname === '/api/status') {
      let s;
      try { s = status(root); } catch (e) { return send(res, 500, MIME['.json'], JSON.stringify({ ok: false, error: e.message })); }
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

module.exports = { VERSION: VERSION, create: create, status: status };

if (require.main === module) {
  const root = path.resolve(process.argv[2] || path.join(__dirname, '..', '..'));
  const port = +process.argv[3] || 3100;
  const s = create(root);
  s.srv.on('error', function (e) {
    console.error('SERVER ERROR ' + e.message + (e.code === 'EADDRINUSE' ? ' (port in use: close the other server or use -Port 3101)' : ''));
    process.exit(1);
  });
  s.srv.listen(port, '127.0.0.1', function () {
    const st = s.status();
    console.log('mom-trader UI  http://127.0.0.1:' + port + '/   engines ' + (st.ok ? 'OK ' + st.passed + '/' + st.total : 'BLOCKED'));
    console.log('Ctrl+C to stop');
  });
}