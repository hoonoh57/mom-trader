'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const root = process.argv[2];
const outDir = path.join(root, 'out', 'probe'); fs.mkdirSync(outDir, { recursive: true });
const L = [], add = s => L.push(s);
const targets = ['strategies/engines/v1.cjs', 'tools/sz-lab.cjs', 'tools/sz-engine.cjs', 'strategies/manifest.json'];
const p1 = /^\s*(async\s+)?function\s+\w+|^\s*(const|let|var)\s+\w+\s*=\s*(async\s*)?(function|\([^)]*\)\s*=>)|module\.exports|^\s*exports\./;
const p2 = /simulate|trades?\.push|\bwhy\b|StopPct|SafeNoLoss|ExitTime|EntryStart|TargetPct|fee|ctx\.|\bret\b|mfe/i;
for (const rel of targets) {
  const p = path.join(root, rel); add('=== ' + rel);
  if (!fs.existsSync(p)) { add('MISSING'); continue; }
  const buf = fs.readFileSync(p);
  add('bytes=' + buf.length + ' sha256=' + crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16));
  if (!rel.endsWith('.cjs')) { add(buf.toString('utf8').slice(0, 2000)); continue; }
  const lines = buf.toString('utf8').split(/\r?\n/); add('lines=' + lines.length);
  if (rel.endsWith('v1.cjs')) {
    try { const m = require(p); add('exports: ' + Object.keys(m).map(k => k + ':' + typeof m[k] + (typeof m[k] === 'function' ? '(' + m[k].length + ')' : '')).join(', ')); }
    catch (e) { add('require error: ' + e.message); }
  }
  let n = 0;
  lines.forEach((s, i) => { if (n < 180 && (p1.test(s) || p2.test(s))) { add(String(i + 1).padStart(5) + ': ' + s.slice(0, 170)); n++; } });
}
const out = path.join(outDir, 'v1_probe.txt');
fs.writeFileSync(out, L.join('\n'), 'utf8');
console.log('PROBE written: ' + out + ' lines=' + L.length);