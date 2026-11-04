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