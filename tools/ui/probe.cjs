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