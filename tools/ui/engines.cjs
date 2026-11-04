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