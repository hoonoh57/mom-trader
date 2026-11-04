'use strict';
// mom-trader report standard (report-1.0). ASCII only.
// Every run writes <root>/out/FOR_OPUS.txt (compact on PASS, full diagnostics on FAIL)
// plus an archive copy in <root>/out/reports/<step>_<stamp>/.
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const VERSION = 'report-1.0';
const MAX = 200 * 1024;
const SECRET_KEY_RE = /(KEY|SECRET|TOKEN|PASS|PWD|ACC|ACCOUNT)/i;

function pad(n) { return String(n).padStart(2, '0'); }
function stamp(d) {
  d = d || new Date();
  return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' +
    pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds());
}
function sha(buf) { return crypto.createHash('sha256').update(buf).digest('hex'); }

function loadSecrets(envPath) {
  const list = [];
  let txt = '';
  try { txt = fs.readFileSync(envPath, 'utf8'); } catch (e) { return { list: list, ok: false }; }
  for (const line of txt.split(/\r?\n/)) {
    const t = line.trim();
    if (!t || t[0] === '#') continue;
    const i = t.indexOf('=');
    if (i < 1) continue;
    const k = t.slice(0, i).trim();
    let v = t.slice(i + 1).trim();
    if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"))) v = v.slice(1, -1);
    if (SECRET_KEY_RE.test(k) && v.length >= 4) list.push(v);
  }
  list.sort(function (a, b) { return b.length - a.length; });
  return { list: list, ok: true };
}

function mask(s, secrets) {
  let t = String(s);
  for (const v of (secrets || [])) { if (v) t = t.split(v).join('***(len=' + v.length + ')'); }
  t = t.replace(/(Bearer\s+)[A-Za-z0-9._\-+\/=]{8,}/g, '$1***');
  t = t.replace(/("(?:token|appkey|secretkey|access_token)"\s*:\s*")[^"]*(")/gi, '$1***$2');
  t = t.replace(/\b\d{8}-\d{2}\b/g, '********-**');
  return t;
}

function context(file, line, r) {
  const L = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const a = Math.max(1, line - r), b = Math.min(L.length, line + r);
  const out = [];
  for (let n = a; n <= b; n++) out.push((n === line ? '>>' : '  ') + String(n).padStart(5) + ': ' + String(L[n - 1]).slice(0, 300));
  return out;
}

function frames(stack) {
  const out = [], seen = new Set();
  const re = /([A-Za-z]:\\[^\s():]+|\/[^\s():]+):(\d+)(?::(\d+))?/g;
  let m;
  while ((m = re.exec(String(stack || ''))) && out.length < 4) {
    const f = m[1], line = +m[2];
    if (/node:internal|[\\\/]node_modules[\\\/]/.test(f)) continue;
    const key = f + ':' + line;
    if (seen.has(key)) continue;
    seen.add(key);
    let ok = false;
    try { ok = fs.statSync(f).isFile(); } catch (e) { ok = false; }
    if (!ok) continue;
    out.push({ file: f, line: line });
  }
  return out;
}

function errInfo(e, where) {
  const o = {
    where: where || '',
    name: (e && e.name) || 'Error',
    message: String((e && e.message) || e),
    stack: String((e && e.stack) || ''),
    ctx: []
  };
  for (const f of frames(o.stack)) {
    try { o.ctx.push({ at: f.file + ':' + f.line, lines: context(f.file, f.line, 4) }); } catch (x) { }
  }
  if (e && e.extra) o.extra = String(e.extra);
  return o;
}

function create(step, opt) {
  opt = opt || {};
  const t0 = Date.now();
  const r = { step: step, version: opt.version || '', started: new Date(t0).toISOString(),
    env: {}, checks: [], data: [], errors: [], notes: [] };
  return {
    r: r,
    env: function (k, v) { r.env[k] = String(v).replace(/\s+/g, '_'); },
    check: function (name, ok, detail) {
      r.checks.push({ name: String(name), ok: !!ok, detail: detail == null ? '' : String(detail) });
      return !!ok;
    },
    data: function (title, body) { r.data.push({ title: String(title), body: String(body == null ? '' : body) }); },
    note: function (s) { r.notes.push(String(s)); },
    error: function (e, where) { r.errors.push(errInfo(e, where)); },
    finish: function () {
      const pass = r.errors.length === 0 && r.checks.every(function (c) { return c.ok; });
      r.verdict = pass ? 'PASS' : 'FAIL';
      r.ended = new Date().toISOString();
      const secrets = loadSecrets(opt.envPath || '').list;
      const outDir = path.join(opt.root, 'out');
      const dir = path.join(outDir, 'reports', String(step).replace(/[^A-Za-z0-9._-]+/g, '_') + '_' + stamp(new Date(t0)));
      const ddir = path.join(dir, 'detail');
      fs.mkdirSync(ddir, { recursive: true });
      const H = [];
      H.push('#MT-REPORT v=' + VERSION + ' step=' + step + ' ver=' + (opt.version || '-') +
        ' verdict=' + r.verdict + ' ts=' + r.started + ' dur=' + ((Date.now() - t0) / 1000).toFixed(1) + 's');
      H.push('#DIR ' + dir);
      H.push('#ENV ' + Object.keys(r.env).map(function (k) { return k + '=' + r.env[k]; }).join(' '));
      const failed = r.checks.filter(function (c) { return !c.ok; });
      if (pass) {
        H.push('#CHK ' + r.checks.length + '/' + r.checks.length + ' PASS');
      } else {
        H.push('#CHK ' + (r.checks.length - failed.length) + '/' + r.checks.length + ' PASS, FAIL=' + failed.length + ', ERR=' + r.errors.length);
        for (const c of failed) H.push('#FAIL ' + c.name + ' :: ' + c.detail);
        const okn = r.checks.filter(function (c) { return c.ok; }).map(function (c) { return c.name; });
        if (okn.length) H.push('#OKLIST ' + okn.join(' | '));
        for (const e of r.errors) {
          H.push('#ERR ' + (e.where ? '[' + e.where + '] ' : '') + e.name + ': ' + e.message);
          H.push('#STACK ' + e.stack.split(/\r?\n/).slice(0, 12).map(function (s) { return s.trim(); }).join(' <- '));
          if (e.extra) { H.push('#EXTRA'); H.push(e.extra.slice(0, 8000)); H.push('#END'); }
          for (const c of e.ctx) { H.push('#CTX ' + c.at); for (const l of c.lines) H.push(l); }
        }
      }
      for (const n of r.notes) H.push('#NOTE ' + n);
      let text = mask(H.join('\n') + '\n', secrets);
      r.data.forEach(function (d, i) {
        const fname = String(i + 1).padStart(2, '0') + '_' + d.title.replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 40) + '.txt';
        const body = mask(d.body, secrets);
        fs.writeFileSync(path.join(ddir, fname), body, 'utf8');
        const lines = body.split('\n').length;
        const block = '#DATA ' + d.title + ' lines=' + lines + '\n' + body + (body.endsWith('\n') ? '' : '\n') + '#END\n';
        if (Buffer.byteLength(text + block, 'utf8') <= MAX) text += block;
        else text += '#CUT ' + d.title + ' lines=' + lines + ' -> ' + path.join(ddir, fname) + '\n';
      });
      fs.writeFileSync(path.join(dir, 'report.txt'), text, 'utf8');
      fs.writeFileSync(path.join(dir, 'report.json'), mask(JSON.stringify(r, null, 1), secrets), 'utf8');
      const file = path.join(outDir, opt.outName || 'FOR_OPUS.txt');
      fs.writeFileSync(file, text, 'utf8');
      return { pass: pass, verdict: r.verdict, dir: dir, file: file, bytes: Buffer.byteLength(text, 'utf8') };
    }
  };
}

async function run(step, opt, fn) {
  const rep = create(step, opt);
  const onFatal = function (e) { rep.error(e, 'uncaught'); };
  process.on('uncaughtException', onFatal);
  try { await fn(rep); } catch (e) { rep.error(e, 'main'); }
  process.removeListener('uncaughtException', onFatal);
  let res;
  try { res = rep.finish(); } catch (e) {
    console.error('REPORT WRITE FAILED: ' + (e && e.stack));
    process.exitCode = 3;
    return null;
  }
  console.log(res.verdict + ' ' + step + ' -> ' + res.file + ' (' + res.bytes + ' bytes)');
  process.exitCode = res.pass ? 0 : 1;
  return res;
}

function selftest() {
  const out = [];
  const t = function (name, f) {
    try { const d = f(); out.push({ name: name, ok: d === true, detail: d === true ? '' : String(d) }); }
    catch (e) { out.push({ name: name, ok: false, detail: String(e && e.stack) }); }
  };
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mt-s0-'));
  t('mask secrets/bearer/account, keep prices', function () {
    const s = mask('k=ABCDEFGH12345678 Bearer abc.def-ghi_jkl012 acct 12345678-90 px 3100 {"token":"zzzzzzzz"}', ['ABCDEFGH12345678']);
    if (s.indexOf('ABCDEFGH12345678') >= 0) return 'secret leaked';
    if (s.indexOf('abc.def-ghi_jkl012') >= 0) return 'bearer leaked';
    if (s.indexOf('12345678-90') >= 0) return 'account leaked';
    if (s.indexOf('zzzzzzzz') >= 0) return 'json token leaked';
    if (s.indexOf('3100') < 0) return 'price wrongly masked: ' + s;
    if (s.indexOf('***(len=16)') < 0) return 'len tag missing: ' + s;
    return true;
  });
  t('env loader picks only secret-like keys', function () {
    const f = path.join(tmp, 'e.env');
    fs.writeFileSync(f, '# c\nKIWOOM_MOCK_APP_KEY="abcd1234xyz"\nKIWOOM_USE_MOCK=true\nPORT=3100\nMY_ACCOUNT=1234567890\n');
    const L = loadSecrets(f).list;
    if (L.indexOf('abcd1234xyz') < 0) return 'app key not loaded';
    if (L.indexOf('3100') >= 0) return 'PORT loaded as secret';
    if (L.indexOf('true') >= 0) return 'USE_MOCK loaded as secret';
    if (L.indexOf('1234567890') < 0) return 'account not loaded';
    return true;
  });
  t('utf8 hangul roundtrip without BOM', function () {
    const s = '\uD55C\uAE00 \uD14C\uC2A4\uD2B8';
    const f = path.join(tmp, 'k.txt');
    fs.writeFileSync(f, s, 'utf8');
    const b = fs.readFileSync(f);
    if (b[0] === 0xEF && b[1] === 0xBB) return 'unexpected BOM';
    const back = b.toString('utf8');
    return (back === s && back.length === s.length) ? true : 'mismatch len=' + back.length;
  });
  t('size cap and FAIL report with code context', function () {
    const root = path.join(tmp, 'root');
    fs.mkdirSync(path.join(root, 'out'), { recursive: true });
    const bad = path.join(root, 'bad.cjs');
    fs.writeFileSync(bad, "'use strict';\nfunction f() {\n  const a = 1;\n  throw new Error('boom-777');\n}\nmodule.exports = f;\n");
    const rep = create('selftest', { root: root, version: 't', envPath: path.join(tmp, 'none.env') });
    rep.check('dummy ok', true);
    rep.data('big', 'x'.repeat(300 * 1024));
    rep.data('small', 'hello');
    try { require(bad)(); } catch (e) { rep.error(e, 'forced'); }
    const res = rep.finish();
    const txt = fs.readFileSync(res.file, 'utf8');
    if (res.pass) return 'forced error still PASS';
    if (!/^#MT-REPORT .*verdict=FAIL/.test(txt)) return 'header wrong: ' + txt.slice(0, 120);
    if (txt.indexOf('boom-777') < 0) return 'error message missing';
    if (!/>>\s*4: /.test(txt)) return 'code context line 4 missing';
    if (Buffer.byteLength(txt) > MAX + 4096) return 'cap exceeded ' + Buffer.byteLength(txt);
    if (txt.indexOf('#CUT big') < 0) return 'big section not cut';
    if (txt.indexOf('#DATA small') < 0) return 'small section missing';
    const det = fs.readdirSync(path.join(res.dir, 'detail'));
    const bigf = det.filter(function (n) { return n.indexOf('big') >= 0; })[0];
    if (!bigf || fs.statSync(path.join(res.dir, 'detail', bigf)).size < 300 * 1024) return 'detail full copy missing';
    return true;
  });
  t('PASS report is compact', function () {
    const root = path.join(tmp, 'root2');
    fs.mkdirSync(path.join(root, 'out'), { recursive: true });
    const rep = create('selftest2', { root: root, version: 't', envPath: path.join(tmp, 'none.env') });
    rep.check('a', true); rep.check('b', true);
    const res = rep.finish();
    const txt = fs.readFileSync(res.file, 'utf8');
    const n = txt.trim().split('\n').length;
    if (!res.pass) return 'expected PASS';
    if (n > 5) return 'PASS report too long: ' + n + ' lines';
    if (txt.indexOf('#OKLIST') >= 0) return 'OKLIST should be omitted on PASS';
    return true;
  });
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { }
  return out;
}

module.exports = { VERSION: VERSION, MAX: MAX, create: create, run: run, mask: mask,
  loadSecrets: loadSecrets, errInfo: errInfo, selftest: selftest, sha: sha, stamp: stamp };