param([string]$Strategies = 'S000', [int]$MinWarm = 400, [string]$Csv = '', [string]$ExclDates = '20261021,20261028')
$ErrorActionPreference = 'Continue'
$Root = 'E:\parent\projects\rea\projects\mom-trader'
$Out = Join-Path $Root 'out\FOR_OPUS.txt'
$Src = Join-Path $Root 'tools\ui\s4_causal.cjs'
$ChartSrc = Join-Path $Root 'tools\ui\s4_chart.cjs'
$Js = Join-Path $Root 'tools\ui\s4_human.cjs'
$U8 = New-Object System.Text.UTF8Encoding($false)
function Fail([string]$m, [string]$d) {
  $t = "#MT-REPORT v=report-1.0 step=S4.human ver=ps-wrapper verdict=FAIL ts=$((Get-Date).ToString('s'))`n#FAIL $m`n$d`n"
  [System.IO.File]::WriteAllText($Out, $t, $U8); Write-Host "FAIL S4.human -> $Out"; exit 1
}
foreach ($f in @($Src, $ChartSrc, (Join-Path $Root 'tools\sz-render.js'))) { if (-not (Test-Path $f)) { Fail 'file missing' $f } }
$t = [System.IO.File]::ReadAllText($Src, $U8) -replace "`r`n", "`n"
$anchor = "  for (const s of strats) {`n    const P0 = s.params, FEE = P0.FeePct;`n"
$i = $t.IndexOf($anchor); $j = $t.LastIndexOf($anchor)
if ($i -lt 0 -or $i -ne $j) { Fail "s4_causal anchor not unique (first=$i last=$j)" '' }
$ver = "const VER = 'causal-1.0', STEP = 'S4.causal';"
$head = $t.Substring(0, $i)
if ([regex]::Matches($head, [regex]::Escape($ver)).Count -ne 1) { Fail 'VER line not found exactly once' '' }
$head = $head.Replace($ver, "const VER = 'human-1.0', STEP = 'S4.human';")
$cs = [System.IO.File]::ReadAllText($ChartSrc, $U8) -replace "`r`n", "`n"
$k1 = $cs.IndexOf("  const ANCH = "); $k2 = $cs.IndexOf("  const outDir = ")
if ($k1 -lt 0 -or $k2 -le $k1 -or $k1 -ne $cs.LastIndexOf("  const ANCH = ") -or $k2 -ne $cs.LastIndexOf("  const outDir = ")) { Fail "s4_chart render block not unique ($k1,$k2)" '' }
$render = $cs.Substring($k1, $k2 - $k1)
$sm = [regex]::Matches($cs, '(?m)^  const STY = [^\n]*\n')
if ($sm.Count -ne 1) { Fail "s4_chart STY line count=$($sm.Count)" '' }
$part = @'
  { // ================= S4-3d human pattern section (human-1.0) =================
  // Pre-registered human "do-not-enter" patterns on S4-3b 'cap' trades. Tags only; frozen engine untouched.
  const SS = strats.find(x => x.id === B.id);
  if (!ok('baseline in strategies', !!SS, 'strats=' + strats.map(x => x.id).join(','))) return 'FAIL';
  const P0 = SS.params, FEE = P0.FeePct, GAP = 3;
  const natES = V1.prep(Object.assign({}, P0, { Date: '', TickScope: 120 }))._entS / 100;
  const capV = VARS.find(v => v.id === 'cap');
  const adj = r => r.R[K0].adj, sumA = a => a.reduce((s, r) => s + adj(r), 0);
  const med = a => { const v = a.filter(x => isFinite(x)).sort((x, y) => x - y); return v.length ? (v.length % 2 ? v[(v.length - 1) / 2] : (v[v.length / 2 - 1] + v[v.length / 2]) / 2) : NaN; };
  const rows = [];
  for (const it of items) {
    if (!it.cp) continue;
    const es = Math.max(natES, capV.es(it.cp.hms));
    const rr = run(it, it.bars, it.start, Object.assign({}, P0, { EntryStart: es, MaxTrades: 1 }));
    if (!rr.r.trades.length) continue;
    const r = mkRow(it, rr.r.trades[0], FEE); r.es = es; r.rr = rr.r; r.ind = rr.ind; rows.push(r);
  }
  const a0 = agg(rows, K0);
  if (!ok('repro S4-3b cap S000 (382 / -106.50)', rows.length === 382 && a0.sumA.toFixed(2) === '-106.50', 'got ' + rows.length + ' ' + a0.sumA.toFixed(2))) return 'FAIL';
  if (!ok('indicator arrays from run()', rows.every(r => r.ind && r.ind.mom && r.rr.marks), '')) return 'FAIL';

  const dC = {};
  const dailyRows = code => {
    if (dC[code]) return dC[code]; let out = [];
    try {
      const L = fs.readFileSync(path.join(restD, code + '.csv'), 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/).filter(x => x.trim());
      const h = L[0].split(','), id = h.indexOf('date'), ic = h.indexOf('close');
      if (id >= 0 && ic >= 0) out = L.slice(1).map(x => x.split(',')).map(c => ({ d: c[id], c: Math.abs(Number(c[ic])) })).filter(x => /^\d{8}$/.test(x.d) && x.c > 0).sort((a, b) => a.d < b.d ? -1 : 1);
    } catch (e) { }
    return (dC[code] = out);
  };
  const closeNBack = (code, date, n) => { const p = dailyRows(code).filter(x => x.d < date); return p.length >= n ? p[p.length - n].c : NaN; };
  const m80 = (b, i) => i >= 80 && b[i - 80].c > 0 ? b[i].c / b[i - 80].c * 100 : NaN;

  for (const r of rows) {
    const it = r.it, b = it.bars, s = it.start, iI = r.t.inI, px = r.t.inPx;
    const sg = r.rr.marks.filter(m => (m.k === 'rej' || m.k === 'entry') && m.i >= s && m.i <= iI).map(m => m.i).sort((x, y) => x - y);
    let cl = 0, last = -1e9; for (const i of sg) { if (i - last > GAP) cl++; last = i; }
    r.sigN = sg.length; r.clN = cl; r.fsI = sg.length ? sg[0] : -1;
    r.drift = r.fsI >= 0 ? (px / b[r.fsI].c - 1) * 100 : NaN;
    r.momS = r.ind.mom[iI] == null ? NaN : r.ind.mom[iI]; r.mom80 = m80(b, iI);
    let hi = b[s].h, pb = 0; for (let j = s + 1; j <= iI; j++) { pb = Math.max(pb, (hi - b[j].l) / hi * 100); if (b[j].h > hi) hi = b[j].h; }
    r.runUp = (px / b[s].o - 1) * 100; r.maxPb = pb;
    let ph = -Infinity, phI = -1; for (let j = s; j < iI; j++) if (b[j].h >= ph) { ph = b[j].h; phI = j; }
    r.phI = phI; r.offHigh = phI >= 0 ? (1 - px / ph) * 100 : NaN; r.minHigh = phI >= 0 ? (b[iI].t - b[phI].t) / 60 : NaN;
    let k2 = 0; for (let j = s; j <= iI; j++) if (b[j].o > 0 && (b[j].c / b[j].o - 1) * 100 >= 2) k2++; r.big2 = k2;
    const c3 = closeNBack(it.code, it.date, 3); r.rise3 = c3 > 0 ? (px / c3 - 1) * 100 : NaN;
    r.nxt = b[s].hms < 90000;
    let kI = s; while (kI < b.length && b[kI].d === it.date && b[kI].hms < 90000) kI++;
    r.gapK = it.dly && kI < b.length && b[kI].d === it.date ? (b[kI].o / it.dly.c - 1) * 100 : NaN;
    r.gapF = it.dly ? (b[s].o / it.dly.c - 1) * 100 : NaN;
  }

  const RULES = [
    ['X1', 'run-up from first bar open >= th% with no 2% pullback', (r, v) => r.runUp >= v && r.maxPb < 2, 5, [3, 7]],
    ['X2', 'entry signal cluster no. > th (gap<=' + GAP + ' bars)', (r, v) => r.clN > v, 1, [2]],
    ['X2b', 'entry > th% above first signal close', (r, v) => r.drift > v, 2, [1, 3]],
    ['X3s', 'Mom(' + P0.MomLen + ') at entry >= th', (r, v) => r.momS >= v, 110, [105, 115]],
    ['X3m80', 'Mom(80) at entry >= th', (r, v) => r.mom80 >= v, 110, [105, 115]],
    ['X4', 'today bars with body >= +2% count >= th', (r, v) => r.big2 >= v, 3, [2, 4]],
    ['X5', 'entry vs close 3 trading days ago >= th%', (r, v) => r.rise3 >= v, 20, [15, 25]],
    ['H1', 'entry >= th% below prior day high, high >= 5 min old', (r, v) => r.offHigh >= v && r.minHigh >= 5, 1, [0.5, 1.5]],
    ['H3', 'chase vs capture px >= th%', (r, v) => r.chase >= v, 3, [2, 5]],
    ['H4k', 'gap at KRX open >= th%', (r, v) => r.gapK >= v, 5, [3, 10]],
    ['H4f', 'gap at first bar open (NXT 08:00) >= th%', (r, v) => r.gapF >= v, 5, [3, 10]]];
  const dayWorst = sel => { const m = {}; for (const r of sel) m[r.date] = (m[r.date] || 0) + adj(r); const v = Object.values(m); return v.length ? Math.min(...v) : 0; };
  const ev = (fn, v) => {
    const blk = rows.filter(r => fn(r, v)), sel = rows.filter(r => !fn(r, v)), a = agg(sel, K0), bl = blk.filter(r => adj(r) < 0), bw = blk.filter(r => adj(r) >= 0);
    return { v, blk, nB: blk.length, nL: bl.length, sL: sumA(bl), nW: bw.length, sW: sumA(bw), net: a.sumA - a0.sumA, dA: a.A - a0.A, dB: a.B - a0.B, a, wd: dayWorst(sel) };
  };
  const good = e => e.dA > 0 && e.dB > 0;
  const line = (id, e, tag) => id.padEnd(6) + pad(e.v, 5) + pad(e.nB, 6) + pad(e.nL, 6) + pad(fx(e.sL), 9) + pad(e.nW, 5) + pad(fx(e.sW), 9) + pad(fx(e.net), 9) + pad(fx(e.dA), 8) + pad(fx(e.dB), 8) +
    pad(e.a.n, 5) + pad(fx(e.a.sumA), 9) + pad(isFinite(e.a.pf) ? e.a.pf.toFixed(2) : '-', 6) + pad(e.a.n ? (e.a.lossD / e.a.n * 100).toFixed(1) : '-', 7) + pad(fx(e.wd), 9) + '  ' + tag;
  const RH = 'rule     th   blk lossN  lossSum winN   winSum      net      dA      dB    n   sumAdj    PF  loss%  worstD  verdict';
  const rl = [RH], RES = [];
  for (const [id, desc, fn, base, nbs] of RULES) {
    const eb = ev(fn, base), en = nbs.map(v => ev(fn, v));
    const pass = good(eb) && eb.nB >= 10 && en.every(good);
    const vd = pass ? 'PASS' : (eb.nB < 10 ? 'FEW' : (!good(eb) ? 'BASE' : 'NEIGHBOR'));
    RES.push({ id, desc, fn, base, eb, pass, vd });
    rl.push(line(id, eb, vd + '  ' + desc)); for (const e of en) rl.push(line('', e, 'nb'));
  }
  for (const r of rows) r.tags = RES.filter(z => z.fn(r, z.base)).map(z => z.id);
  const PSET = new Set(RES.filter(z => z.pass).map(z => z.id));
  rl.push(line('ANY', ev(r => r.tags.length > 0, '-'), 'info: union of all rules (not a verdict)'));
  rl.push(line('PASSU', ev(r => r.tags.some(x => PSET.has(x)), '-'), 'info: union of PASS rules=' + ([...PSET].join('|') || 'none')));
  data('S000 cap human rules (base n=' + a0.n + ' adj=' + fx(a0.sumA) + ' A=' + fx(a0.A) + ' B=' + fx(a0.B) + ' worstDay=' + fx(dayWorst(rows)) + '; pass = dA>0,dB>0 at base & neighbors, blk>=10)', rl);

  const losses = rows.filter(r => adj(r) < 0), wins = rows.filter(r => adj(r) >= 0), unexp = losses.filter(r => !r.tags.length);
  const FK = ['clN', 'sigN', 'drift', 'momS', 'mom80', 'runUp', 'maxPb', 'offHigh', 'minHigh', 'big2', 'rise3', 'chase', 'gapK', 'gapF', 'delay'];
  const fl = ['feature   med_loss  med_win   (n loss=' + losses.length + ' win=' + wins.length + ')'];
  for (const f of FK) fl.push(f.padEnd(9) + pad(f2(med(losses.map(r => r[f]))), 10) + pad(f2(med(wins.map(r => r[f]))), 10));
  data('feature medians loss vs win (entry-time values)', fl);
  const tl = ['tags  lossN  lossSum  winN   winSum'];
  for (let n = 0; n <= 6; n++) { const L = losses.filter(r => Math.min(r.tags.length, 6) === n), W = wins.filter(r => Math.min(r.tags.length, 6) === n); if (L.length || W.length) tl.push(pad(n === 6 ? '6+' : n, 4) + pad(L.length, 7) + pad(fx(sumA(L)), 9) + pad(W.length, 6) + pad(fx(sumA(W)), 9)); }
  data('tag count distribution (unexplained losses = tags 0: n=' + unexp.length + ' sum=' + fx(sumA(unexp)) + ')', tl);

  const z9 = rows.find(r => r.code === '0009K0' && r.date === '20261021');
  if (z9) {
    const it = z9.it, b = it.bars, nat = run(it, b, it.start, P0);
    const L = ['src  time        close  kind   why     momS   mom80          n  big'];
    for (const [src, R, ind] of [['cap', z9.rr, z9.ind], ['nat', nat.r, nat.ind]]) for (const m of R.marks) {
      if (m.i < it.start || m.k === 'exit') continue; const q = b[m.i];
      L.push(src + '  ' + String(q.hms).padStart(6, '0') + pad(q.c, 10) + '  ' + m.k.padEnd(6) + ' ' + String(m.why || '').padEnd(6) + pad(f2(ind.mom[m.i]), 8) + pad(f2(m80(b, m.i)), 8) + pad(f2(ind.n[m.i]), 11) + pad(ind.big[m.i] ? 1 : 0, 4));
    }
    data('HTS check 0009K0 20261021 engine marks (arm/rej/entry) from day start; compare with HTS arrows 08:00:03, 08:06:03, 09:00', L);
  } else sums.push('0009K0 20261021 not in cap rows');
  const ul = ['code   date     in        adj    mfe  why            clN drift  momS mom80 runUp offHi  big2 rise3 chase'];
  for (const r of unexp.slice().sort((x, y) => adj(x) - adj(y)).slice(0, 60))
    ul.push(r.code.padEnd(6) + ' ' + r.date + ' ' + String(r.inHms).padStart(6, '0') + pad(fx(adj(r)), 8) + pad(f2(r.t.mfe), 6) + '  ' + String(r.t.why).padEnd(14) + pad(r.clN, 3) +
      pad(f2(r.drift), 6) + pad(f2(r.momS), 6) + pad(f2(r.mom80), 6) + pad(f2(r.runUp), 6) + pad(f2(r.offHigh), 6) + pad(r.big2, 5) + pad(f2(r.rise3), 6) + pad(f2(r.chase), 6));
  data('unexplained losses (no tag), worst 60', ul);

  const used = new Set(), cases = [], kk = r => r.code + '_' + r.date;
  const take = (cat, list, n) => { let c = 0; for (const r of list) { if (c >= n) break; if (used.has(kk(r))) continue; used.add(kk(r)); cases.push({ cat, r }); c++; } };
  const byAdj = a => a.slice().sort((x, y) => adj(x) - adj(y));
  take('U_unexplained', byAdj(unexp), 60);
  for (const z of RES) { take(z.id + '_blkLoss', byAdj(z.eb.blk.filter(r => adj(r) < 0)), 3); take(z.id + '_blkWin', byAdj(z.eb.blk.filter(r => adj(r) >= 0)).reverse(), 3); }

  /*@@STY@@*/
  /*@@RENDER@@*/
  const outDir = path.join(ROOT, 'out', 'charts', 'S4-3d'); fs.mkdirSync(outDir, { recursive: true });
  const tm = h => { const s = String(h).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };
  const g2 = (x, d) => x == null || !isFinite(x) ? '-' : Number(x).toFixed(d);
  const firstIdx = (it, hms) => { for (let j = it.start; j < it.bars.length; j++) if (it.bars[j].d === it.date && it.bars[j].hms >= hms) return j; return null; };
  const HH = 'case cat              code   date     bar   time           O        H        L        C     momS    mom80          n        sig safe big';
  const idxR = [], fmap = {};
  cases.forEach((cs, k) => {
    const r = cs.r, it = r.it, bars = it.bars, R1 = r.rr, ind = r.ind, t = r.t, v0 = Math.max(0, it.start - 300);
    const Pp = V1.prep(Object.assign({}, P0, { EntryStart: r.es, MaxTrades: 1, Date: '', TickScope: 120 }));
    const A_ = a => Array.from(a).slice(v0);
    const rd = (a, d) => Array.from(a).slice(v0).map(x => x == null || !isFinite(x) ? null : +Number(x).toFixed(d));
    const capI = firstIdx(it, it.cp.hms), esI = firstIdx(it, r.es * 100);
    const D = {
      o: A_(bars.map(b => b.o)), h: A_(bars.map(b => b.h)), l: A_(bars.map(b => b.l)), c: A_(bars.map(b => b.c)), hms: A_(bars.map(b => b.hms)),
      mom: rd(ind.mom, 3), n: rd(ind.n, 5), sig: rd(ind.sig, 5), ema: rd(ind.ema, 1), st: rd(ind.st, 1), stDir: A_(ind.stDir),
      amt: rd(ind.amt, 0), taamt: rd(ind.taamt, 0), big: A_(ind.big), cnt1: A_(ind.cnt1), thr: rd(ind.thr, 0), tickOk: A_(ind.tickOk),
      disp: rd(ind.disp, 2), safe: A_(ind.safe),
      trades: R1.trades.map(x => Object.assign({}, x, { inI: x.inI - v0, outI: x.outI - v0 })),
      marks: R1.marks.filter(m => m.i >= v0).map(m => Object.assign({}, m, { i: m.i - v0 })),
      emaLen: Pp.EmaLen, momLen: Pp.MomLen, safeTh: Pp.SafeTh, bigMode: Pp.BigMode, tickK: Pp.TickK,
      ov: { capI: capI == null ? null : capI - v0, capTxt: tm(it.cp.hms) + ' ' + it.cp.px, esI: esI == null ? null : esI - v0, esTxt: String(r.es),
        stops: R1.trades.map(x => ({ a: x.inI - v0, b: x.outI - v0, px: x.inPx * (1 - P0.StopPct / 100) })) } };
    const pg = [HH];
    const hl = (lab, j) => {
      if (j == null || j < 0 || j >= bars.length) return; const b = bars[j];
      pg.push(pad(k + 1, 4) + ' ' + cs.cat.padEnd(16) + ' ' + it.code.padEnd(6) + ' ' + it.date + ' ' + lab.padEnd(5) + ' ' + tm(b.hms) + pad(b.o, 9) + pad(b.h, 9) + pad(b.l, 9) + pad(b.c, 9) +
        pad(g2(ind.mom[j], 2), 9) + pad(g2(m80(bars, j), 2), 9) + pad(g2(ind.n[j], 5), 11) + pad(g2(ind.sig[j], 5), 11) + pad(ind.safe[j] ? 1 : 0, 5) + pad(ind.big[j] ? 1 : 0, 4));
    };
    hl('sig1', r.fsI); hl('cap', capI); hl('high', r.phI); hl('in-1', t.inI - 1); hl('in', t.inI); hl('out', t.outI);
    const fn = 'h' + String(k + 1).padStart(3, '0') + '_' + it.code + '_' + it.date + '.html'; fmap[kk(r)] = fn;
    const info = [['category', cs.cat], ['code date', it.code + ' ' + it.date], ['tags', r.tags.join(' ') || '-'], ['capture', tm(it.cp.hms) + ' ' + it.cp.px], ['ES', r.es],
      ['entry', tm(bars[t.inI].hms) + ' ' + t.inPx], ['exit', tm(bars[t.outI].hms) + ' ' + g2(t.outPx, 1) + ' ' + t.why], ['adj', fx(adj(r))], ['mfe/mae', fx(t.mfe) + ' / ' + fx(t.mae)],
      ['sig/cluster', r.sigN + ' / ' + r.clN], ['sig1', r.fsI >= 0 ? tm(bars[r.fsI].hms) + ' ' + bars[r.fsI].c : '-'], ['drift', fx(r.drift)], ['momS/m80', g2(r.momS, 1) + ' / ' + g2(r.mom80, 1)],
      ['runUp/maxPb', fx(r.runUp) + ' / ' + g2(r.maxPb, 2)], ['offHigh/min', g2(r.offHigh, 2) + ' / ' + g2(r.minHigh, 1)], ['big2', r.big2], ['rise3', fx(r.rise3)], ['chase', fx(r.chase)],
      ['gapK/gapF', fx(r.gapK) + ' / ' + fx(r.gapF)], ['NXT', r.nxt ? 'Y' : 'N']];
    let tb = '<table>'; for (let q = 0; q < info.length; q += 10) { const s = info.slice(q, q + 10); tb += '<tr>' + s.map(x => '<th>' + x[0] + '</th>').join('') + '</tr><tr>' + s.map(x => '<td>' + x[1] + '</td>').join('') + '</tr>'; } tb += '</table>';
    const html = '<!doctype html><html><head><meta charset="utf-8"><title>' + (k + 1) + ' ' + cs.cat + ' ' + it.code + ' ' + it.date + '</title>' + STY + '</head><body>' +
      '<a href="index.html">index</a> &nbsp; <b>#' + (k + 1) + ' ' + cs.cat + '</b>' + tb +
      '<canvas id="cv" style="width:100%;height:80vh;display:block"></canvas><div id="tip"></div><pre>' + pg.join('\n') + '</pre>' +
      '<script>window.SZDATA=' + JSON.stringify(D) + ';</script><script>' + RENDER + '</script></body></html>';
    fs.writeFileSync(path.join(outDir, fn), html, 'utf8');
    idxR.push('<tr><td>' + (k + 1) + '</td><td>' + cs.cat + '</td><td><a href="' + fn + '">' + it.code + '</a></td><td>' + it.date + '</td><td>' + tm(bars[t.inI].hms) + '</td><td>' + t.why +
      '</td><td class="' + (adj(r) > 0 ? 'up' : 'dn') + '">' + fx(adj(r)) + '</td><td>' + fx(t.mfe) + '</td><td>' + (r.tags.join(' ') || '-') + '</td></tr>');
  });
  fs.writeFileSync(path.join(outDir, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><title>S4-3d human patterns</title>' + STY + '</head><body><h3>S4-3d S000 cap n=' + rows.length + ' adj=' + fx(a0.sumA) +
    '</h3><pre>' + rl.join('\n') + '\n\n' + fl.join('\n') + '\n\n' + tl.join('\n') + '</pre><table><tr><th>#</th><th>cat</th><th>code</th><th>date</th><th>in</th><th>why</th><th>adj</th><th>mfe</th><th>tags</th></tr>' + idxR.join('') + '</table></body></html>', 'utf8');

  const hdir = path.join(ROOT, 'out', 'human'); fs.mkdirSync(hdir, { recursive: true });
  const rf = path.join(hdir, 'review.csv'), prev = {}; let kept = 0;
  if (fs.existsSync(rf)) {
    for (const ln of fs.readFileSync(rf, 'utf8').replace(/^\uFEFF/, '').split(/\r?\n/).slice(1)) {
      if (!ln.trim()) continue; const c = ln.split(','); prev[c[0] + '|' + c[1]] = { h: c[8] || '', why: c.slice(9).join(',') };
    }
    fs.copyFileSync(rf, rf + '.bak39');
  }
  const rv = ['code,date,inHms,adj,mfe,exit,tags,chart,human,reason'];
  const ord = rows.slice().sort((x, y) => ((adj(x) < 0 && !x.tags.length) ? 0 : adj(x) < 0 ? 1 : 2) - ((adj(y) < 0 && !y.tags.length) ? 0 : adj(y) < 0 ? 1 : 2) || adj(x) - adj(y));
  for (const r of ord) { const p = prev[r.code + '|' + r.date]; if (p && (p.h || p.why)) kept++;
    rv.push([r.code, r.date, r.inHms, f4(adj(r)), f4(r.t.mfe), r.t.why, r.tags.join('|'), fmap[kk(r)] || '', p ? p.h : '', p ? p.why : ''].join(',')); }
  fs.writeFileSync(rf, '\uFEFF' + rv.join('\r\n') + '\r\n', 'utf8');
  const fc = ['code,date,half,inHms,adj,mfe,why,tags,sigN,clN,drift,momS,mom80,runUp,maxPb,offHigh,minHigh,big2,rise3,chase,gapK,gapF,nxt'];
  for (const r of rows) fc.push([r.code, r.date, r.half, r.inHms, f4(adj(r)), f4(r.t.mfe), r.t.why, r.tags.join('|'), r.sigN, r.clN, f4(r.drift), f4(r.momS), f4(r.mom80), f4(r.runUp), f4(r.maxPb), f4(r.offHigh), f4(r.minHigh), r.big2, f4(r.rise3), f4(r.chase), f4(r.gapK), f4(r.gapF), r.nxt ? 1 : 0].join(','));
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  fs.writeFileSync(path.join(RDIR, 'detail', 'human_rows.csv'), fc.join('\n') + '\n');
  sums.push('charts=' + path.join(outDir, 'index.html') + ' cases=' + cases.length + ' review=' + rf + ' rows=' + rows.length + ' keptLabels=' + kept + ' unexplainedLoss=' + unexp.length + ' momLen=' + P0.MomLen + ' render.sha12=' + sha(rbuf).slice(0, 12));
  }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL', err = null;
try { verdict = main(); } catch (e) { err = e; verdict = 'FAIL'; }
report(verdict, err);
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);
'@
$part = $part -replace "`r`n", "`n"
$p1 = "  /*@@STY@@*/`n"; $p2 = "  /*@@RENDER@@*/`n"
if ($part.IndexOf($p1) -lt 0 -or $part.IndexOf($p2) -lt 0) { Fail 'placeholders missing' '' }
$part = $part.Replace($p1, $sm[0].Value).Replace($p2, $render)
$code = $head + $part
if (Test-Path $Js) { Copy-Item $Js "$Js.bak39" -Force }
[System.IO.File]::WriteAllText($Js, $code, $U8)
$c = & node --check $Js 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Fail 'node --check failed' $c }
$a = @($Js, $Root, '--strategies', $Strategies, '--Strategies', $Strategies, '--minWarm', "$MinWarm", '--MinWarm', "$MinWarm", '--minwarm', "$MinWarm",
  '--excl', $ExclDates, '--exclDates', $ExclDates, '--ExclDates', $ExclDates)
if ($Csv) { $a += @('--csv', $Csv) }
$t0 = Get-Date
$o = & node @a 2>&1 | Out-String
$ec = $LASTEXITCODE
if (-not (Test-Path $Out) -or (Get-Item $Out).LastWriteTime -lt $t0) { Fail "node exit $ec, report not written" $o }
Write-Host ($o.Trim().Split("`n")[-1])
