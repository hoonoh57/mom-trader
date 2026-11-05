#requires -Version 5.1
# mom-trader S1: hash-verified loader + local server + 5-tab UI shell. ASCII only.
# Result file (always the same): <Root>\out\FOR_OPUS.txt
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [int]$Port = 3100,
  [switch]$Serve,
  [switch]$NoBrowser,
  [string]$EnvPath = 'E:\parent\security\.env'
)
$ErrorActionPreference = 'Stop'

$JsEngines = @'
'use strict';
// mom-trader S1 hash-verified loader (engines-1.0). ASCII only. Never writes files.
// Frozen modules are required ONLY when every registered hash matches.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const VERSION = 'engines-1.0';
const REQUIRED = ['v1', 'risk1', 'v3', 'guard-1.0', 'guard-1.1', 'S000', 'R000'];

function sha(b) { return crypto.createHash('sha256').update(b).digest('hex'); }
function readJson(f) { return JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, '')); }

function targets(root) {
  const SD = path.join(root, 'strategies');
  const list = [];
  const manFile = path.join(SD, 'manifest.json');
  let man;
  try { man = readJson(manFile); } catch (e) {
    list.push({ id: 'manifest', kind: 'manifest', file: manFile, want: '', mode: 'bytes', src: '', err: 'manifest read failed: ' + e.message });
    return list;
  }
  for (const id of ['v1', 'risk1', 'v3']) {
    const e = man.engines && man.engines[id];
    list.push({ id: id, kind: 'engine', file: e ? path.join(SD, 'engines', e.file) : '', want: e ? String(e.sha256 || '') : '',
      mode: 'bytes', src: e && e.from ? path.join(root, e.from) : '', err: e ? '' : 'not registered in strategies/manifest.json' });
  }
  const guards = [['guard-1.0', 'guard', 'tools/sz-guard.cjs'], ['guard-1.1', 'guard11', 'tools/sz-guard11.cjs']];
  for (const g of guards) {
    const mf = path.join(SD, g[1], 'manifest.json');
    let gm = null, err = '';
    try { gm = readJson(mf); } catch (e) { err = 'guard manifest read failed: ' + mf + ' :: ' + e.message; }
    list.push({ id: g[0], kind: 'guard', file: path.join(root, (gm && gm.file) || g[2]), want: gm ? String(gm.sha256 || '') : '',
      mode: 'bytes', src: '', err: err });
  }
  const fz = man.frozen || {};
  for (const id of Object.keys(fz)) {
    list.push({ id: id, kind: 'frozen', file: path.join(SD, 'frozen', id + '.json'), want: String(fz[id]), mode: 'params', src: '', err: '' });
  }
  return list;
}

function verify(root) {
  root = path.resolve(root);
  const rows = targets(root).map(function (t) {
    const r = { id: t.id, kind: t.kind, file: t.file, rel: t.file ? path.relative(root, t.file).split(path.sep).join('/') : '',
      want: t.want, got: '', ok: false, err: t.err, src: '' };
    if (!r.err) {
      try {
        if (!t.file || !fs.existsSync(t.file)) r.err = 'file missing';
        else if (t.mode === 'params') {
          const j = readJson(t.file);
          if (j.id !== t.id) r.err = 'id mismatch in file: ' + j.id;
          r.got = sha(JSON.stringify(j.params));
        } else r.got = sha(fs.readFileSync(t.file));
      } catch (e) { r.err = e.message; }
    }
    if (!r.err && !r.want) r.err = 'no registered hash';
    r.ok = !r.err && r.got === r.want;
    if (!r.err && !r.ok) r.err = 'hash mismatch';
    if (t.src) {
      try { r.src = fs.existsSync(t.src) ? (sha(fs.readFileSync(t.src)) === r.want ? 'same' : 'differs') : 'missing'; }
      catch (e) { r.src = 'error'; }
    }
    return r;
  });
  const ids = rows.map(function (r) { return r.id; });
  const missing = REQUIRED.filter(function (id) { return ids.indexOf(id) < 0; });
  const ok = missing.length === 0 && rows.every(function (r) { return r.ok; });
  return { version: VERSION, root: root, ok: ok, missing: missing, rows: rows };
}

function ver(m) { return m && m.VERSION ? String(m.VERSION) : '-'; }

function load(root) {
  const v = verify(root);
  if (!v.ok) {
    const bad = v.rows.filter(function (r) { return !r.ok; }).map(function (r) { return r.id + '(' + r.err + ')'; })
      .concat(v.missing.map(function (m) { return m + '(missing)'; }));
    const e = new Error('hash verification failed, loading blocked: ' + bad.join(', '));
    e.verify = v;
    throw e;
  }
  const f = {};
  v.rows.forEach(function (r) { f[r.id] = r.file; });
  const V1 = require(f.v1), R = require(f.risk1), mk = require(f.v3);
  if (typeof mk !== 'function') throw new Error('v3 module is not a factory function');
  const E3 = mk(V1, R);
  const G10 = require(f['guard-1.0']), G11 = require(f['guard-1.1']);
  const frozen = {};
  v.rows.filter(function (r) { return r.kind === 'frozen'; }).forEach(function (r) { frozen[r.id] = readJson(r.file); });
  return { verify: v, V1: V1, R: R, E3: E3, G10: G10, G11: G11, frozen: frozen,
    versions: { v1: ver(V1), risk1: ver(R), v3: ver(E3), 'guard-1.0': ver(G10), 'guard-1.1': ver(G11) } };
}

module.exports = { VERSION: VERSION, REQUIRED: REQUIRED, verify: verify, load: load, sha: sha, readJson: readJson };
'@

$JsServer = @'
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
'@

$JsS1 = @'
'use strict';
// mom-trader S1 self-test runner (s1-1.0). ASCII only. Writes out/FOR_OPUS.txt via report.cjs.
const fs = require('fs');
const path = require('path');
const os = require('os');
const http = require('http');
const R = require('./report.cjs');
const ENG = require('./engines.cjs');
const SRV = require('./server.cjs');
const VERSION = 's1-1.0';

let A;
try { A = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '')); }
catch (e) { console.error('ARGS READ FAILED ' + process.argv[2] + ' :: ' + e.message); process.exit(2); }
const ROOT = path.resolve(A.root);

function row(v, id) { return v.rows.filter(function (r) { return r.id === id; })[0] || null; }
function badList(v) { return v.rows.filter(function (r) { return !r.ok; }).map(function (r) { return r.id + ':' + r.err; }).concat(v.missing).join(', '); }

function get(port, p) {
  return new Promise(function (resolve, reject) {
    const q = http.get({ host: '127.0.0.1', port: port, path: p, agent: false }, function (r) {
      let b = '';
      r.setEncoding('utf8');
      r.on('data', function (d) { b += d; });
      r.on('end', function () { resolve({ status: r.statusCode, body: b }); });
    });
    q.on('error', reject);
    q.setTimeout(5000, function () { q.destroy(new Error('timeout ' + p)); });
  });
}

function copyInto(src, dst) {
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
  try { fs.chmodSync(dst, 0o666); } catch (e) { }
}

function makeTmpRoot(v) {
  const t = fs.mkdtempSync(path.join(os.tmpdir(), 'mt-s1-'));
  const rels = ['strategies/manifest.json', 'strategies/guard/manifest.json', 'strategies/guard11/manifest.json'];
  v.rows.forEach(function (r) { if (r.rel) rels.push(r.rel); });
  rels.forEach(function (rl) {
    const s = path.join(ROOT, rl);
    if (fs.existsSync(s)) copyInto(s, path.join(t, rl));
  });
  return t;
}

function today() {
  const d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}

function updateProgress(nChecks) {
  const f = path.join(ROOT, 'docs', 'progress.md');
  fs.mkdirSync(path.dirname(f), { recursive: true });
  let t = fs.existsSync(f) ? fs.readFileSync(f, 'utf8') : '';
  if (!t) {
    t = '# mom-trader progress\n\nEach step: what was built, how it was verified, what remains. Result file: out/FOR_OPUS.txt\n\n' +
      '| step | date | built | verified | remaining |\n|---|---|---|---|---|\n';
  }
  if (t.indexOf('| S0 |') < 0) t += '| S0 | 2026-11-04 | tools/ui/report.cjs, tools/ui/probe.cjs, setup/29_probe.ps1 | selftest 5/5, engine hashes v1/risk1/v3 match | - |\n';
  if (t.indexOf('| S1 |') < 0) t += '| S1 | ' + today() + ' | tools/ui/engines.cjs, server.cjs, s1.cjs, ui/index.html, setup/30_server.ps1 | ' + nChecks +
    ' checks: 7 hashes, tamper reject (byte/params/missing), server status/static/traversal | browser screenshot via -Serve |\n';
  fs.writeFileSync(f, t, 'utf8');
}

R.run('S1.server', { root: ROOT, version: VERSION, envPath: A.envPath }, async function (rep) {
  rep.env('node', process.version);
  rep.env('engines', ENG.VERSION);
  rep.env('server', SRV.VERSION);
  rep.env('report', R.VERSION);

  // 1. real hashes
  const v = ENG.verify(ROOT);
  rep.check('required targets present (' + ENG.REQUIRED.length + ')', v.missing.length === 0, 'missing: ' + v.missing.join(','));
  for (const r of v.rows) {
    rep.check('hash ' + r.id + ' (' + r.rel + ')', r.ok, r.err + ' got ' + String(r.got).slice(0, 12) + ' want ' + String(r.want).slice(0, 12));
  }
  rep.data('hash table [id kind file want12 got12 result toolsCopy]', v.rows.map(function (r) {
    return [r.id, r.kind, r.rel, String(r.want).slice(0, 12), String(r.got).slice(0, 12), r.ok ? 'OK' : 'FAIL:' + r.err, r.src || '-'].join('  ');
  }).join('\n'));

  // 2. real load
  let L = null;
  try { L = ENG.load(ROOT); } catch (e) { rep.error(e, 'load real root'); }
  if (L) {
    rep.check('v1.simulate is function', typeof L.V1.simulate === 'function', typeof L.V1.simulate);
    rep.check('v3 assembled (simulate, runPortfolio)', typeof L.E3.simulate === 'function' && typeof L.E3.runPortfolio === 'function',
      'keys: ' + Object.keys(L.E3).join(','));
    rep.check('frozen S000/R000 loaded with params', !!(L.frozen.S000 && L.frozen.R000 && L.frozen.S000.params && L.frozen.R000.params), '');
    for (const k of Object.keys(L.versions)) rep.env('ver_' + k, L.versions[k]);
  }

  // 3. tamper tests on a temp copy (real files never touched)
  const tmp = makeTmpRoot(v);
  try {
    const v0 = ENG.verify(tmp);
    rep.check('temp copy verifies clean', v0.ok, badList(v0));
    const rv1 = row(v, 'v1');
    if (rv1 && rv1.rel) {
      const f1 = path.join(tmp, rv1.rel);
      const orig = fs.readFileSync(f1);
      const b = Buffer.from(orig);
      b[b.length - 1] = b[b.length - 1] ^ 1;
      fs.writeFileSync(f1, b);
      const vt = ENG.verify(tmp), rt = row(vt, 'v1');
      const nbad = vt.rows.filter(function (r) { return !r.ok; }).length;
      rep.check('1 byte changed in v1 -> rejected (only v1)', !vt.ok && rt && !rt.ok && nbad === 1, badList(vt));
      let msg = '';
      try { ENG.load(tmp); msg = 'load did not throw'; } catch (e) { msg = /blocked/.test(e.message) ? '' : 'unexpected: ' + e.message; }
      rep.check('load() refuses tampered root', msg === '', msg);
      fs.writeFileSync(f1, orig);
    } else rep.check('v1 row available for tamper test', false, 'no v1 row');

    const rs = row(v, 'S000');
    if (rs && rs.rel) {
      const fz = path.join(tmp, rs.rel);
      const ot = fs.readFileSync(fz, 'utf8');
      const j = JSON.parse(ot.replace(/^\uFEFF/, ''));
      fs.writeFileSync(fz, JSON.stringify(j, null, 4));
      const vf = ENG.verify(tmp);
      rep.check('S000 reformatted (same params) still accepted', vf.ok, badList(vf));
      const k = Object.keys(j.params || {}).filter(function (x) { return typeof j.params[x] === 'number'; })[0];
      if (k) {
        j.params[k] = j.params[k] + 1;
        fs.writeFileSync(fz, JSON.stringify(j, null, 2));
        const vp = ENG.verify(tmp), rp = row(vp, 'S000');
        rep.check('S000 param ' + k + ' changed -> rejected', !vp.ok && rp && !rp.ok, badList(vp));
      } else rep.check('S000 has a numeric param for tamper test', false, 'no numeric param');
      fs.writeFileSync(fz, ot);
    } else rep.check('S000 row available for tamper test', false, 'no S000 row');

    const rg = row(v, 'guard-1.1');
    if (rg && rg.rel) {
      fs.unlinkSync(path.join(tmp, rg.rel));
      const vg = ENG.verify(tmp), rr = row(vg, 'guard-1.1');
      rep.check('guard-1.1 file missing -> rejected', !vg.ok && rr && rr.err === 'file missing', badList(vg));
    } else rep.check('guard-1.1 row available for missing test', false, 'no guard-1.1 row');
  } finally {
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { rep.note('temp cleanup failed: ' + tmp); }
  }

  // 4. server on a random port
  const S = SRV.create(ROOT);
  await new Promise(function (res, rej) { S.srv.once('error', rej); S.srv.listen(0, '127.0.0.1', res); });
  const port = S.srv.address().port;
  try {
    const a = await get(port, '/api/status');
    let js = null;
    try { js = JSON.parse(a.body); } catch (e) { }
    rep.check('GET /api/status -> 200 ok', a.status === 200 && js && js.ok === true && js.total >= ENG.REQUIRED.length,
      'status ' + a.status + ' body ' + a.body.slice(0, 400));
    const h = await get(port, '/');
    const ids = ['tab-main', 'tab-logic', 'tab-data', 'tab-sim', 'tab-release'];
    const miss = ids.filter(function (i) { return h.body.indexOf('id="' + i + '"') < 0; });
    rep.check('GET / -> index.html with 5 tabs', h.status === 200 && miss.length === 0, 'status ' + h.status + ' missing ' + miss.join(','));
    const t = await get(port, '/..%2fstrategies%2fmanifest.json');
    rep.check('path traversal blocked', t.status === 403 || t.status === 404, 'status ' + t.status);
    const n = await get(port, '/nope.html');
    rep.check('unknown file -> 404', n.status === 404, 'status ' + n.status);
  } finally {
    try { S.srv.closeAllConnections(); } catch (e) { }
    await new Promise(function (res) { S.srv.close(function () { res(); }); });
  }

  const allOk = rep.r.errors.length === 0 && rep.r.checks.every(function (c) { return c.ok; });
  if (allOk) { updateProgress(rep.r.checks.length); rep.note('docs/progress.md updated'); }
});
'@

$Html = @'
<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>mom-trader</title>
<style>
body{margin:0;background:#141414;color:#ddd;font:13px 'Malgun Gothic',Consolas,sans-serif}
#top{display:flex;align-items:center;gap:12px;padding:6px 12px;background:#1d1d1d;border-bottom:1px solid #333}
#top b{font-size:15px}
#top button{background:#333;color:#ddd;border:1px solid #555;padding:2px 10px;cursor:pointer}
.badge{padding:2px 10px;border-radius:10px;font-weight:bold;cursor:pointer}
.ok{background:#1f5f2a;color:#cfc}.bad{background:#7a1d1d;color:#fcc}.wait{background:#444;color:#ccc}
#meta{color:#888}
nav{display:flex;gap:2px;padding:6px 12px 0;background:#1a1a1a;border-bottom:1px solid #333}
nav button{background:#222;color:#aaa;border:1px solid #333;border-bottom:none;padding:7px 16px;cursor:pointer;font:inherit}
nav button.on{background:#2c2c2c;color:#fff}
section{display:none;padding:14px}section.on{display:block}
table{border-collapse:collapse}td,th{border:1px solid #333;padding:3px 8px;font-family:Consolas,monospace}
th{background:#222}.y{color:#7f7}.n{color:#f77}.ph{color:#777}
pre{color:#f99;white-space:pre-wrap}
</style></head><body>
<div id="top"><b>mom-trader</b><span id="badge" class="badge wait">checking...</span><span id="meta"></span><button id="recheck">recheck</button></div>
<nav id="tabs">
<button data-t="tab-main">&#xB9E4;&#xB9E4; &#xAC80;&#xC99D;</button>
<button data-t="tab-logic">&#xC804;&#xB7B5; &#xB85C;&#xC9C1;</button>
<button data-t="tab-data">&#xB370;&#xC774;&#xD130;&#x00B7;&#xAC80;&#xC99D;</button>
<button data-t="tab-sim">&#xC2DC;&#xBBAC;&#xB808;&#xC774;&#xC158;</button>
<button data-t="tab-release">&#xACB0;&#xACFC;&#xBB3C; &#xCD9C;&#xB825;</button>
</nav>
<section id="tab-main"><p class="ph">Main: date/time query, capture list, A/B trade chart (S6-S7)</p></section>
<section id="tab-logic"><p class="ph">Strategy logic document (S8)</p></section>
<section id="tab-data">
<h3>Frozen module hash check</h3>
<table id="hash"><thead><tr><th>id</th><th>kind</th><th>file</th><th>registered</th><th>actual</th><th>result</th><th>tools copy</th></tr></thead><tbody></tbody></table>
<pre id="err"></pre>
<p class="ph">Data coverage table (S3-S4), reproduction gate (S5)</p>
</section>
<section id="tab-sim"><p class="ph">Causal bar replay (S10)</p></section>
<section id="tab-release"><p class="ph">Release package: SPEC, PARAMS, golden tests, LLM brief (S11)</p></section>
<script>
(function () {
  var tabs = document.querySelectorAll('#tabs button');
  function show(id) {
    if (!document.getElementById(id)) id = 'tab-main';
    for (var i = 0; i < tabs.length; i++) {
      var t = tabs[i].getAttribute('data-t'), on = (t === id);
      tabs[i].className = on ? 'on' : '';
      document.getElementById(t).className = on ? 'on' : '';
    }
    try { localStorage.setItem('mt.tab', id); } catch (e) { }
  }
  for (var i = 0; i < tabs.length; i++) tabs[i].onclick = function () { show(this.getAttribute('data-t')); };
  var saved = null;
  try { saved = localStorage.getItem('mt.tab'); } catch (e) { }
  show(saved || 'tab-main');

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }); }
  function load() {
    var b = document.getElementById('badge');
    b.className = 'badge wait'; b.textContent = 'checking...';
    fetch('/api/status', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (s) {
      b.className = 'badge ' + (s.ok ? 'ok' : 'bad');
      b.textContent = s.ok ? ('ENGINES OK ' + s.passed + '/' + s.total) : ('BLOCKED ' + s.failed + ' failed');
      var v = s.versions || {}, vs = [];
      for (var k in v) vs.push(k + '=' + v[k]);
      document.getElementById('meta').textContent = 'node ' + s.node + ' | ' + s.server + ' | ' + vs.join(' ') + ' | ' + s.time;
      var h = '';
      (s.rows || []).forEach(function (r) {
        h += '<tr><td>' + esc(r.id) + '</td><td>' + esc(r.kind) + '</td><td>' + esc(r.file) + '</td><td>' + esc(r.want) + '</td><td>' + esc(r.got) +
          '</td><td class="' + (r.ok ? 'y' : 'n') + '">' + (r.ok ? 'OK' : 'FAIL ' + esc(r.err)) + '</td><td>' + esc(r.src || '-') + '</td></tr>';
      });
      document.querySelector('#hash tbody').innerHTML = h;
      document.getElementById('err').textContent = s.loadErr || ((s.missing && s.missing.length) ? 'missing: ' + s.missing.join(', ') : '');
    }).catch(function (e) { b.className = 'badge bad'; b.textContent = 'server unreachable'; });
  }
  document.getElementById('badge').onclick = function () { show('tab-data'); };
  document.getElementById('recheck').onclick = load;
  load();
})();
</script>
</body></html>
'@

$Out  = Join-Path $Root 'out'
$Opus = Join-Path $Out 'FOR_OPUS.txt'
$Tmp  = Join-Path $Out 'reports\_run'
$utf8 = New-Object Text.UTF8Encoding($false)
$t0   = Get-Date
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

function Write-Fallback([string]$Why, [string[]]$Files) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine("#MT-REPORT v=wrapper-1.0 step=S1.server verdict=FAIL ts=$((Get-Date).ToString('s')) stage=wrapper")
  [void]$sb.AppendLine("#ENV ps=$($PSVersionTable.PSVersion) root=$Root")
  [void]$sb.AppendLine("#ERR $Why")
  foreach ($f in $Files) {
    if ($f -and (Test-Path -LiteralPath $f)) {
      [void]$sb.AppendLine("#DATA $(Split-Path $f -Leaf)")
      [void]$sb.AppendLine([IO.File]::ReadAllText($f, $utf8))
      [void]$sb.AppendLine('#END')
    }
  }
  [IO.File]::WriteAllText($Opus, $sb.ToString(), $utf8)
  Write-Host "FAIL (wrapper) -> $Opus" -ForegroundColor Red
}

function Invoke-Node([string[]]$NodeArgs, [string]$Tag) {
  $o = Join-Path $Tmp "$Tag.out"; $e = Join-Path $Tmp "$Tag.err"
  Remove-Item -LiteralPath $o, $e -ErrorAction SilentlyContinue
  $q = @($NodeArgs | ForEach-Object { '"' + $_ + '"' })
  $p = Start-Process -FilePath $script:NodeExe -ArgumentList $q -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  $null = $p.Handle
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $o; Err = $e }
}

try {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $cmd) { Write-Fallback 'node not found in PATH' @(); exit 1 }
  $script:NodeExe = $cmd.Source

  $rpt = Join-Path $Root 'tools\ui\report.cjs'
  if (-not (Test-Path -LiteralPath $rpt) -or -not ([IO.File]::ReadAllText($rpt, $utf8)).Contains("'report-1.0'")) {
    Write-Fallback 'tools\ui\report.cjs (report-1.0) missing: run 29_probe.ps1 first' @(); exit 1
  }

  $Targets = [ordered]@{
    'tools\ui\engines.cjs' = $JsEngines
    'tools\ui\server.cjs'  = $JsServer
    'tools\ui\s1.cjs'      = $JsS1
    'ui\index.html'        = $Html
  }
  foreach ($k in $Targets.Keys) {
    $p = Join-Path $Root $k
    $new = $Targets[$k]
    if ($new -match '[^\x00-\x7F]') { Write-Fallback "non-ASCII char inside embedded $k (copy/paste damage?)" @(); exit 1 }
    New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
    if (Test-Path -LiteralPath $p) {
      $old = [IO.File]::ReadAllText($p, $utf8)
      if ($old -ne $new) { Copy-Item -LiteralPath $p -Destination ($p + '.bak30') -Force }
    }
    [IO.File]::WriteAllText($p, $new, $utf8)
    if ([IO.File]::ReadAllText($p, $utf8) -ne $new) { Write-Fallback "write verify failed: $p" @(); exit 1 }
  }

  foreach ($k in @('tools\ui\engines.cjs', 'tools\ui\server.cjs', 'tools\ui\s1.cjs')) {
    $p = Join-Path $Root $k
    $r = Invoke-Node @('--check', $p) ('check_' + (Split-Path $p -Leaf))
    if ($r.Code -ne 0) { Write-Fallback "node --check failed: $p (exit $($r.Code))" @($r.Err, $r.Out); exit 1 }
  }

  $argObj = [ordered]@{ root = $Root; envPath = $EnvPath; psVersion = "$($PSVersionTable.PSVersion)"; wrapper = '30_server.ps1' }
  $argFile = Join-Path $Tmp 's1_args.json'
  [IO.File]::WriteAllText($argFile, ($argObj | ConvertTo-Json), $utf8)

  $r = Invoke-Node @((Join-Path $Root 'tools\ui\s1.cjs'), $argFile) 's1'
  $fresh = (Test-Path -LiteralPath $Opus) -and ((Get-Item -LiteralPath $Opus).LastWriteTime -ge $t0)
  if (-not $fresh) { Write-Fallback "s1 runner did not write report (exit $($r.Code))" @($r.Err, $r.Out); exit 1 }

  $line = ([IO.File]::ReadAllText($r.Out, $utf8)).Trim()
  if ($r.Code -eq 0) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }
  Write-Host "Attach this file: $Opus" -ForegroundColor Cyan
  if (-not $Serve) { exit $r.Code }
  if ($r.Code -ne 0) { Write-Host 'Serve skipped: S1 checks failed' -ForegroundColor Red; exit $r.Code }
} catch {
  $f = Join-Path $Tmp 'wrapper_err.txt'
  [IO.File]::WriteAllText($f, ($_ | Out-String) + "`r`n" + $_.ScriptStackTrace, $utf8)
  Write-Fallback "wrapper exception: $($_.Exception.Message)" @($f)
  exit 1
}

$url = "http://127.0.0.1:$Port/"
if (-not $NoBrowser) {
  Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "Start-Sleep -Seconds 1; Start-Process '$url'"
}
& $script:NodeExe (Join-Path $Root 'tools\ui\server.cjs') $Root $Port
