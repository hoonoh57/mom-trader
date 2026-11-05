#requires -Version 5.1
# mom-trader S0: report standard + probe. ASCII only (any file encoding is fine).
# Result file (always the same): <Root>\out\FOR_OPUS.txt
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [string]$Items = 'all',            # all | none | manifest,tree,chart,data
  [string]$Show = '',                # 'tools\a.cjs:100-160;setup\b.ps1'
  [string]$Find = '',                # regex, prefix (?i) for ignore-case
  [string]$FindIn = 'tools,setup,strategies',
  [int]$FindCtx = 0,
  [string]$EnvPath = 'E:\parent\security\.env',
  [switch]$SelfTestOnly
)
$ErrorActionPreference = 'Stop'

$JsReport = @'
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
'@

$JsProbe = @'
'use strict';
// mom-trader S0 probe (probe-1.0). ASCII only.
// Collects manifests, file trees, chart candidates, data listings, file excerpts and regex hits
// into <root>/out/FOR_OPUS.txt so that nothing has to be copied from the console.
const fs = require('fs');
const path = require('path');
const R = require('./report.cjs');
const VERSION = 'probe-1.0';

let A;
try { A = JSON.parse(fs.readFileSync(process.argv[2], 'utf8').replace(/^\uFEFF/, '')); }
catch (e) { console.error('ARGS READ FAILED ' + process.argv[2] + ' :: ' + e.message); process.exit(2); }

const ROOT = path.resolve(A.root);
const TEXT_EXT = /\.(cjs|mjs|js|ts|ps1|psm1|json|md|txt|csv|html|css|log|bat|cmd)$/i;
function pad(n) { return String(n).padStart(2, '0'); }
function ltime(ms) { const d = new Date(ms); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()); }
function rel(p) { return path.relative(ROOT, p).split(path.sep).join('/'); }
function isForbidden(p) { return /(^|[\\\/])\.env($|\.)/i.test(p) || /[\\\/]security([\\\/]|$)/i.test(p); }
function inRoot(p) { const a = path.resolve(p).toLowerCase(), b = ROOT.toLowerCase(); return a === b || a.indexOf(b + path.sep) === 0; }
function isBak(p) { return /\.bak/i.test(path.basename(p)); }

function walk(dir, depth, out, lim) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return; }
  ents.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
  for (const e of ents) {
    if (out.length >= lim) return;
    const p = path.join(dir, e.name);
    if (isForbidden(p)) continue;
    if (e.isDirectory()) {
      if (e.name === 'node_modules' || e.name === '.git') continue;
      if (depth > 0) walk(p, depth - 1, out, lim);
    } else if (e.isFile()) out.push(p);
  }
}
function fileLine(p, withHash) {
  const st = fs.statSync(p);
  let h = '-';
  if (withHash && st.size <= 50 * 1024 * 1024) h = R.sha(fs.readFileSync(p)).slice(0, 12);
  return rel(p) + '  ' + st.size + '  ' + ltime(st.mtimeMs) + '  ' + h;
}
function pairs(o, out) {
  if (!o || typeof o !== 'object') return out;
  if (typeof o.file === 'string' && typeof o.sha256 === 'string') out.push(o);
  for (const k of Object.keys(o)) pairs(o[k], out);
  return out;
}

function secManifest(rep) {
  const main = path.join(ROOT, 'strategies', 'manifest.json');
  rep.check('strategies/manifest.json exists', fs.existsSync(main), main);
  const files = [];
  walk(path.join(ROOT, 'strategies'), 3, files, 5000);
  const mans = files.filter(function (p) { return /manifest\.json$/i.test(path.basename(p)) && !isBak(p); });
  rep.note('manifests found: ' + mans.map(rel).join(', '));
  for (const m of mans) {
    const txt = fs.readFileSync(m, 'utf8');
    rep.data('manifest ' + rel(m), txt);
    let j = null;
    try { j = JSON.parse(txt.replace(/^\uFEFF/, '')); } catch (e) { rep.check('json parse ' + rel(m), false, e.message); continue; }
    const dir = path.dirname(m);
    const isMain = path.resolve(m).toLowerCase() === path.resolve(main).toLowerCase();
    for (const en of pairs(j, [])) {
      const cands = [path.join(dir, 'engines', en.file), path.join(dir, en.file)];
      const f = cands.filter(function (c) { return fs.existsSync(c); })[0];
      if (!f) {
        if (isMain) rep.check('engine file exists ' + en.file, false, cands.join(' | '));
        else rep.note('hash target not found for ' + rel(m) + ' file=' + en.file);
        continue;
      }
      const got = R.sha(fs.readFileSync(f));
      rep.check('hash ' + rel(f), got === en.sha256, 'got ' + got.slice(0, 12) + ' want ' + String(en.sha256).slice(0, 12));
    }
  }
}

function secTree(rep) {
  const spec = [['tools', 2], ['setup', 1], ['strategies', 3]];
  for (const s of spec) {
    const base = path.join(ROOT, s[0]);
    if (!fs.existsSync(base)) { rep.check('dir exists ' + s[0], false, base); continue; }
    const list = [];
    walk(base, s[1], list, 3000);
    rep.data('tree ' + s[0] + ' files=' + list.length + (list.length >= 3000 ? ' (capped)' : '') + ' [path size mtime sha12]',
      list.map(function (p) { return fileLine(p, !isBak(p)); }).join('\n'));
  }
}

function secChart(rep) {
  const list = [];
  walk(path.join(ROOT, 'tools'), 2, list, 5000);
  walk(path.join(ROOT, 'setup'), 1, list, 5000);
  const c = list.filter(function (p) {
    const b = path.basename(p);
    return /(^|[^0-9])11_|chart/i.test(b) && TEXT_EXT.test(b) && !isBak(p);
  });
  rep.note('chart candidates: ' + c.length);
  for (const p of c.slice(0, 8)) {
    const L = fs.readFileSync(p, 'utf8').split(/\r?\n/);
    rep.data('head40 ' + rel(p) + ' (total ' + L.length + ' lines)',
      L.slice(0, 40).map(function (s, i) { return String(i + 1).padStart(4) + ': ' + s.slice(0, 300); }).join('\n'));
  }
  if (c.length > 8) rep.data('chart candidates (more)', c.slice(8).map(rel).join('\n'));
}

function secData(rep) {
  const groups = [['data/ticks', null], ['data/daily', null], ['data/screen', null], ['data/rest', null], ['logs', /^raw-.*\.json$/i]];
  for (const g of groups) {
    const base = path.join(ROOT, g[0]);
    if (!fs.existsSync(base)) { rep.data('dir ' + g[0], '(missing)'); continue; }
    const list = [];
    walk(base, 2, list, 20000);
    const sel = list.filter(function (p) { return !g[1] || g[1].test(path.basename(p)); });
    let total = 0;
    const lines = [];
    for (const p of sel) { const st = fs.statSync(p); total += st.size; lines.push(rel(p) + '  ' + st.size + '  ' + ltime(st.mtimeMs)); }
    rep.data('dir ' + g[0] + ' files=' + sel.length + ' bytes=' + total, lines.join('\n') || '(empty)');
  }
}

function secShow(rep) {
  const items = String(A.show).split(';').map(function (s) { return s.trim(); }).filter(Boolean);
  for (const it of items) {
    const m = /^(.*?)(?::(\d+)-(\d+))?$/.exec(it);
    const p = path.isAbsolute(m[1]) ? m[1] : path.join(ROOT, m[1]);
    if (!inRoot(p) || isForbidden(p)) { rep.check('show path allowed: ' + it, false, 'outside root or forbidden'); continue; }
    if (!fs.existsSync(p)) { rep.check('show file exists: ' + it, false, p); continue; }
    const L = fs.readFileSync(p, 'utf8').split(/\r?\n/);
    const a = m[2] ? Math.max(1, +m[2]) : 1;
    const b = Math.min(L.length, m[3] ? +m[3] : 400, a + 1499);
    const body = [];
    for (let n = a; n <= b; n++) body.push(String(n).padStart(5) + ': ' + String(L[n - 1]).slice(0, 400));
    rep.data('show ' + rel(p) + ':' + a + '-' + b + ' (total ' + L.length + ' lines, sha12 ' + R.sha(fs.readFileSync(p)).slice(0, 12) + ')', body.join('\n'));
  }
}

function secFind(rep) {
  let pat = String(A.find), flags = '';
  if (pat.indexOf('(?i)') === 0) { pat = pat.slice(4); flags = 'i'; }
  let re;
  try { re = new RegExp(pat, flags); } catch (e) { rep.check('find regex valid', false, e.message); return; }
  const ctxN = Math.max(0, Math.min(5, +A.findCtx || 0));
  const dirs = String(A.findIn || 'tools,setup,strategies').split(',').map(function (s) { return s.trim(); }).filter(Boolean);
  const out = [];
  let hits = 0, nfiles = 0;
  for (const d of dirs) {
    const base = path.isAbsolute(d) ? d : path.join(ROOT, d);
    if (!inRoot(base) || isForbidden(base)) { rep.check('find dir allowed: ' + d, false, base); continue; }
    const list = [];
    walk(base, 4, list, 20000);
    for (const f of list) {
      if (!TEXT_EXT.test(f) || isBak(f)) continue;
      if (fs.statSync(f).size > 5 * 1024 * 1024) continue;
      const L = fs.readFileSync(f, 'utf8').split(/\r?\n/);
      let any = false;
      for (let i = 0; i < L.length && hits < 400; i++) {
        if (!re.test(L[i])) continue;
        if (!any) { out.push('== ' + rel(f)); any = true; nfiles++; }
        hits++;
        for (let j = Math.max(0, i - ctxN); j <= Math.min(L.length - 1, i + ctxN); j++)
          out.push((j === i ? '>' : ' ') + String(j + 1).padStart(5) + ': ' + L[j].slice(0, 300));
        if (ctxN) out.push('  --');
      }
    }
  }
  rep.data('find /' + A.find + '/ in ' + dirs.join(',') + ' hits=' + hits + ' files=' + nfiles + (hits >= 400 ? ' (capped 400)' : ''),
    out.join('\n') || '(no match)');
}

R.run('S0.probe', { root: ROOT, version: VERSION, envPath: A.envPath }, async function (rep) {
  const sec = R.loadSecrets(A.envPath);
  rep.env('node', process.version);
  rep.env('ps', A.psVersion || '-');
  rep.env('os', process.platform + '-' + process.arch);
  rep.env('report', R.VERSION);
  rep.env('envFile', sec.ok ? 'found' : 'missing');
  rep.env('secretsMasked', sec.list.length);
  for (const c of R.selftest()) rep.check('selftest: ' + c.name, c.ok, c.detail);
  if (A.selfTestOnly) return;
  const items = String(A.items || 'all').toLowerCase().split(',').map(function (s) { return s.trim(); });
  const has = function (n) { return items.indexOf('all') >= 0 || items.indexOf(n) >= 0; };
  if (has('manifest')) secManifest(rep);
  if (has('tree')) secTree(rep);
  if (has('chart')) secChart(rep);
  if (has('data')) secData(rep);
  if (A.show) secShow(rep);
  if (A.find) secFind(rep);
});
'@

$Out  = Join-Path $Root 'out'
$Opus = Join-Path $Out 'FOR_OPUS.txt'
$Tmp  = Join-Path $Out 'reports\_run'
$utf8 = New-Object Text.UTF8Encoding($false)
$t0   = Get-Date
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

function Write-Fallback([string]$Why, [string[]]$Files) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine("#MT-REPORT v=wrapper-1.0 step=S0.probe verdict=FAIL ts=$((Get-Date).ToString('s')) stage=wrapper")
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

  $Targets = [ordered]@{ 'tools\ui\report.cjs' = $JsReport; 'tools\ui\probe.cjs' = $JsProbe }
  foreach ($k in $Targets.Keys) {
    $p = Join-Path $Root $k
    $new = $Targets[$k]
    if ($new -match '[^\x00-\x7F]') { Write-Fallback "non-ASCII char inside embedded $k (copy/paste damage?)" @(); exit 1 }
    New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
    if (Test-Path -LiteralPath $p) {
      $old = [IO.File]::ReadAllText($p, $utf8)
      if ($old -ne $new) { Copy-Item -LiteralPath $p -Destination ($p + '.bak29') -Force }
    }
    [IO.File]::WriteAllText($p, $new, $utf8)
    if ([IO.File]::ReadAllText($p, $utf8) -ne $new) { Write-Fallback "write verify failed: $p" @(); exit 1 }
  }

  foreach ($k in $Targets.Keys) {
    $p = Join-Path $Root $k
    $r = Invoke-Node @('--check', $p) ('check_' + (Split-Path $p -Leaf))
    if ($r.Code -ne 0) { Write-Fallback "node --check failed: $p (exit $($r.Code))" @($r.Err, $r.Out); exit 1 }
  }

  $argObj = [ordered]@{
    root = $Root; items = $Items; show = $Show; find = $Find; findIn = $FindIn; findCtx = $FindCtx
    envPath = $EnvPath; selfTestOnly = [bool]$SelfTestOnly; psVersion = "$($PSVersionTable.PSVersion)"; wrapper = '29_probe.ps1'
  }
  $argFile = Join-Path $Tmp 'probe_args.json'
  [IO.File]::WriteAllText($argFile, ($argObj | ConvertTo-Json), $utf8)

  $r = Invoke-Node @((Join-Path $Root 'tools\ui\probe.cjs'), $argFile) 'probe'
  $fresh = (Test-Path -LiteralPath $Opus) -and ((Get-Item -LiteralPath $Opus).LastWriteTime -ge $t0)
  if (-not $fresh) { Write-Fallback "probe did not write report (exit $($r.Code))" @($r.Err, $r.Out); exit 1 }

  $line = ([IO.File]::ReadAllText($r.Out, $utf8)).Trim()
  if ($r.Code -eq 0) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }
  Write-Host "Attach this file: $Opus" -ForegroundColor Cyan
  exit $r.Code
} catch {
  $f = Join-Path $Tmp 'wrapper_err.txt'
  [IO.File]::WriteAllText($f, ($_ | Out-String) + "`r`n" + $_.ScriptStackTrace, $utf8)
  Write-Fallback "wrapper exception: $($_.Exception.Message)" @($f)
  exit 1
}
