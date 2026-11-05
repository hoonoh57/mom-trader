param([string]$Strategies = 'S000', [int]$MinWarm = 400, [string]$Csv = '', [string]$ExclDates = '20261021,20261028')
$ErrorActionPreference = 'Continue'
$Root = 'E:\parent\projects\rea\projects\mom-trader'
$Out = Join-Path $Root 'out\FOR_OPUS.txt'
$Src = Join-Path $Root 'tools\ui\s4_causal.cjs'
$Js = Join-Path $Root 'tools\ui\s4_chart.cjs'
$U8 = New-Object System.Text.UTF8Encoding($false)
function Fail([string]$m, [string]$d) {
  $t = "#MT-REPORT v=report-1.0 step=S4.chart ver=ps-wrapper verdict=FAIL ts=$((Get-Date).ToString('s'))`n#FAIL $m`n$d`n"
  [System.IO.File]::WriteAllText($Out, $t, $U8); Write-Host "FAIL S4.chart -> $Out"; exit 1
}
if (-not (Test-Path $Src)) { Fail 'source missing' $Src }
if (-not (Test-Path (Join-Path $Root 'tools\sz-render.js'))) { Fail 'sz-render.js missing' '' }
$t = [System.IO.File]::ReadAllText($Src, $U8) -replace "`r`n", "`n"
$anchor = "  for (const s of strats) {`n    const P0 = s.params, FEE = P0.FeePct;`n"
$i = $t.IndexOf($anchor); $j = $t.LastIndexOf($anchor)
if ($i -lt 0 -or $i -ne $j) { Fail "s4_causal anchor not unique (first=$i last=$j)" '' }
$ver = "const VER = 'causal-1.0', STEP = 'S4.causal';"
$head = $t.Substring(0, $i)
if ([regex]::Matches($head, [regex]::Escape($ver)).Count -ne 1) { Fail 'VER line not found exactly once' '' }
$head = $head.Replace($ver, "const VER = 'chart-1.0', STEP = 'S4.chart';")
$part = @'
  { // ================= S4-3c chart section (chart-1.0) =================
  // Re-runs S4-3b 'cap' with the same run/mkRow/agg, gates on 382 / -106.50, then draws case charts (sz-render.js + overlay).
  const SS = strats.find(x => x.id === B.id);
  if (!ok('baseline in strategies', !!SS, 'strats=' + strats.map(x => x.id).join(','))) return 'FAIL';
  const P0 = SS.params, FEE = P0.FeePct;
  const natES = V1.prep(Object.assign({}, P0, { Date: '', TickScope: 120 }))._entS / 100;
  const capV = VARS.find(v => v.id === 'cap');
  const adj = r => r.R[K0].adj;
  const natRows = [], rows = [];
  for (const it of items) {
    const nt = run(it, it.bars, it.start, P0).r.trades;
    if (nt.length) natRows.push(mkRow(it, nt[0], FEE));
    if (!it.cp) continue;
    const es = Math.max(natES, capV.es(it.cp.hms));
    const tr = run(it, it.bars, it.start, Object.assign({}, P0, { EntryStart: es, MaxTrades: 1 })).r.trades;
    if (!tr.length) continue;
    const r = mkRow(it, tr[0], FEE);
    r.es = es; r.late = !!(nt.length && it.bars[nt[0].inI].hms < es * 100);
    rows.push(r);
  }
  const nb = agg(natRows, K0), a0 = agg(rows, K0);
  ok('repro native first S000 (+87.90 / +96.53)', nb.sum.toFixed(2) === '87.90' && nb.sumA.toFixed(2) === '96.53', 'got ' + nb.sum.toFixed(2) + ' ' + nb.sumA.toFixed(2));
  if (!ok('repro S4-3b cap S000 (382 / -106.50)', rows.length === 382 && a0.sumA.toFixed(2) === '-106.50', 'got ' + rows.length + ' ' + a0.sumA.toFixed(2))) return 'FAIL';

  const stopPx = r => r.t.inPx * (1 - P0.StopPct / 100);
  const CATS = [
    ['1_Uminus', r => /^U-/.test(r.t.why)], ['2_chase_mfe<0.5', r => r.t.mfe < 0.5], ['3_delay>30', r => r.delay > 30],
    ['4_late_new', r => r.late], ['5_stop', r => r.t.why === 'stop'], ['5b_stop_gapfill', r => r.t.why === 'stop' && r.t.outPx < stopPx(r) - 1e-6],
    ['7_Uplus', r => /^U\+/.test(r.t.why)], ['all', r => true]];
  const totLoss = rows.reduce((s, r) => s + Math.min(0, adj(r)), 0);
  const cl = ['category              n   win%   sumAdj   avgAdj  avgMfe  avgMae  lossSum  lossShare'];
  for (const [nm, fn] of CATS) {
    const sel = rows.filter(fn); if (!sel.length) { cl.push(nm.padEnd(20) + pad(0, 4)); continue; }
    const w = sel.filter(r => adj(r) > 0).length, sA = sel.reduce((s, r) => s + adj(r), 0), ls = sel.reduce((s, r) => s + Math.min(0, adj(r)), 0);
    cl.push(nm.padEnd(20) + pad(sel.length, 4) + pad((w / sel.length * 100).toFixed(1), 7) + pad(fx(sA), 9) + pad(fx(sA / sel.length), 9) +
      pad(f2(avg(sel.map(r => r.t.mfe))), 8) + pad(f2(avg(sel.map(r => r.t.mae))), 8) + pad(fx(ls), 9) + pad((totLoss ? ls / totLoss * 100 : 0).toFixed(0) + '%', 10));
  }
  data('S000 cap loss categories (overlapping) totalLoss=' + fx(totLoss), cl);
  const wm = {}; for (const r of rows) (wm[r.t.why] = wm[r.t.why] || []).push(r);
  const wl = ['why                  n   win%   sumAdj   avgAdj  avgMfe  avgMae'];
  for (const k of Object.keys(wm).sort((a, b) => wm[b].length - wm[a].length)) {
    const sel = wm[k], w = sel.filter(r => adj(r) > 0).length, sA = sel.reduce((s, r) => s + adj(r), 0);
    wl.push(k.padEnd(18) + pad(sel.length, 5) + pad((w / sel.length * 100).toFixed(1), 7) + pad(fx(sA), 9) + pad(fx(sA / sel.length), 9) + pad(f2(avg(sel.map(r => r.t.mfe))), 8) + pad(f2(avg(sel.map(r => r.t.mae))), 8));
  }
  data('S000 cap exit reasons', wl);

  const used = new Set(), cases = [], kk = r => r.code + '_' + r.date;
  const take = (cat, list, n) => { let c = 0; for (const r of list) { if (c >= n) break; if (used.has(kk(r))) continue; used.add(kk(r)); cases.push({ cat, r }); c++; } };
  const byLoss = a => a.slice().sort((x, y) => adj(x) - adj(y));
  take('1_Uminus', byLoss(rows.filter(r => /^U-/.test(r.t.why) && adj(r) < 0)), 5);
  take('2_chase', byLoss(rows.filter(r => r.t.mfe < 0.5 && adj(r) < 0)), 5);
  take('3_delay>30', byLoss(rows.filter(r => r.delay > 30 && adj(r) < 0)), 5);
  take('4_late_new', byLoss(rows.filter(r => r.late && adj(r) < 0)), 5);
  const stops = rows.filter(r => r.t.why === 'stop');
  take('5_stop_gap', byLoss(stops.filter(r => r.t.outPx < stopPx(r) - 1e-6)), 2);
  take('5_stop', byLoss(stops), 5 - cases.filter(c => c.cat === '5_stop_gap').length);
  take('6_0011A0', rows.filter(r => r.code === '0011A0' && r.date === '20261102'), 1);
  const d21 = rows.filter(r => r.date === '20261021');
  take('6_1021_worst', byLoss(d21), 1); take('6_1021_best', byLoss(d21).reverse(), 1);
  take('7_ctrl_Uplus', rows.filter(r => /^U\+/.test(r.t.why)).sort((x, y) => adj(y) - adj(x)), 3);

  const ANCH = "        else if (m.k === 'rej') cross(x, y(D.h[m.i]) - 8, 4, REJ[m.why] || '#fff');\n      });\n";
  const rbuf = fs.readFileSync(path.join(ROOT, 'tools', 'sz-render.js')), rsrc = rbuf.toString('utf8').replace(/\r\n/g, '\n');
  const nA = rsrc.split(ANCH).length - 1;
  if (!ok('sz-render.js overlay anchor unique', nA === 1, 'count=' + nA + ' sha12=' + sha(rbuf).slice(0, 12))) return 'FAIL';
  const OVL = [
    "      if (D.ov) {",
    "        var O = D.ov, vl = function (ii, col, txt, dy) { if (ii == null || ii < v0 || ii >= v1) return; g.strokeStyle = col; g.setLineDash([3, 3]); g.beginPath(); g.moveTo(X(ii), p.y); g.lineTo(X(ii), p.y + p.h); g.stroke(); g.setLineDash([]); g.fillStyle = col; g.font = '11px sans-serif'; g.textAlign = 'left'; g.fillText(txt, X(ii) + 3, p.y + dy); };",
    "        vl(O.capI, '#ffffff', 'CAP ' + O.capTxt, 28); vl(O.esI, '#ffdd00', 'ES ' + O.esTxt, 42);",
    "        (O.stops || []).forEach(function (q) { var a = Math.max(q.a, v0), b = Math.min(q.b, v1 - 1); if (a > b) return; g.strokeStyle = '#ff3333'; g.setLineDash([6, 3]); g.beginPath(); g.moveTo(X(a), y(q.px)); g.lineTo(X(b), y(q.px)); g.stroke(); g.setLineDash([]); g.fillStyle = '#ff6666'; g.font = '10px sans-serif'; g.textAlign = 'left'; g.fillText('stop ' + q.px.toFixed(0), X(a) + 2, y(q.px) + 11); });",
    "        g.font = '10px sans-serif'; g.textAlign = 'center';",
    "        D.marks.forEach(function (m) { if (m.i < v0 || m.i >= v1) return; if (m.k === 'rej' && m.why !== 'time') { g.fillStyle = REJ[m.why] || '#fff'; g.fillText(m.why, X(m.i), y(D.h[m.i]) - 15); } else if (m.k === 'exit') { g.fillStyle = '#ffcc66'; g.fillText(m.why, X(m.i), y(D.h[m.i]) - 36); } });",
    "      }"].join('\n') + '\n';
  const RENDER = rsrc.replace(ANCH, ANCH + OVL);

  const outDir = path.join(ROOT, 'out', 'charts', 'S4-3c'); fs.mkdirSync(outDir, { recursive: true });
  const tm = h => { const s = String(h).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };
  const g2 = (x, d) => x == null || !isFinite(x) ? '-' : Number(x).toFixed(d);
  const firstIdx = (it, hms) => { for (let j = it.start; j < it.bars.length; j++) if (it.bars[j].d === it.date && it.bars[j].hms >= hms) return j; return null; };
  const STY = '<style>body{background:#111;color:#ddd;font:13px sans-serif;margin:8px}a{color:#6cf}table{border-collapse:collapse;margin:6px 0}td,th{border:1px solid #333;padding:2px 6px;text-align:right}th{background:#222}.up{color:#ff6b6b}.dn{color:#5cc8ff}pre{font:12px monospace}#tip{position:absolute;display:none;pointer-events:none;background:rgba(0,0,0,.88);border:1px solid #555;padding:6px 8px;font:12px sans-serif;line-height:1.45}</style>';
  const HH = 'case cat              code   date     bar   time           O        H        L        C      mom         n       sig      hist        st stDir       ema safe amt_e8 big';
  const hts = [HH], idxR = [], cc = ['no,cat,code,date,capHms,capPx,es,inHms,inPx,outHms,outPx,why,ret,adj,mfe,mae,delay,chase,capRise,late,file'];
  let srcInd = '', mis = 0, mis1 = '';
  cases.forEach((cs, k) => {
    const r = cs.r, it = r.it, bars = it.bars, Pc = Object.assign({}, P0, { EntryStart: r.es, MaxTrades: 1 });
    const rr = run(it, bars, it.start, Pc), Pp = V1.prep(Object.assign({}, Pc, { Date: '', TickScope: 120 }));
    let ind = rr.ind, R1 = rr.r;
    if (ind) srcInd = 'run().ind';
    else {
      srcInd = 'recomputed V1.compute+simulate';
      ind = V1.compute(bars, Pp);
      const dayComplete = bars[it.start].hms <= Pp._sessMax;
      let limKind = null; if (it.dly && isFinite(it.dly.chg)) { if (it.dly.chg >= Pp.LimPct) limKind = 'limit'; else if (it.dly.chg >= Pp.SurgePct) limKind = 'surge'; }
      R1 = V1.simulate(bars, ind, Pp, { start: it.start, date: it.date, dayComplete, limKind });
      const m = sameTr(rr.r, R1, 0) || sameCnt(rr.r, R1);
      if (m) { mis++; if (!mis1) mis1 = it.code + ' ' + it.date + ': ' + m; }
    }
    const t = R1.trades[0] || r.t, v0 = Math.max(0, it.start - 300);
    const A_ = a => Array.from(a).slice(v0);
    const rd = (a, d) => Array.from(a).slice(v0).map(x => x == null || !isFinite(x) ? null : +Number(x).toFixed(d));
    const capI = firstIdx(it, it.cp.hms), esI = firstIdx(it, r.es * 100), sp = stopPx(r);
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
      if (j == null || j < 0 || j >= bars.length) return;
      const b = bars[j], hi = (ind.n[j] != null && ind.sig[j] != null) ? ind.n[j] - ind.sig[j] : NaN;
      const L = pad(k + 1, 4) + ' ' + cs.cat.padEnd(16) + ' ' + it.code.padEnd(6) + ' ' + it.date + ' ' + lab.padEnd(5) + ' ' + tm(b.hms) +
        pad(b.o, 9) + pad(b.h, 9) + pad(b.l, 9) + pad(b.c, 9) + pad(g2(ind.mom[j], 2), 9) + pad(g2(ind.n[j], 5), 10) + pad(g2(ind.sig[j], 5), 10) +
        pad(g2(hi, 5), 10) + pad(g2(ind.st[j], 1), 10) + pad(ind.stDir[j] == null ? '-' : ind.stDir[j], 6) + pad(g2(ind.ema[j], 1), 10) +
        pad(ind.safe[j] ? 1 : 0, 5) + pad(g2(ind.amt[j] / 1e8, 2), 7) + pad(ind.big[j] ? 1 : 0, 4);
      hts.push(L); pg.push(L);
    };
    hl('cap', capI); hl('in-1', t.inI - 1); hl('in', t.inI); hl('out', t.outI);
    const fn = 'case' + String(k + 1).padStart(2, '0') + '_' + it.code + '_' + it.date + '.html';
    const info = [['category', cs.cat], ['code date', it.code + ' ' + it.date], ['capture', tm(it.cp.hms) + ' / ' + it.cp.px + ' / ' + f2(r.capAmt) + 'M'], ['EntryStart', r.es],
      ['entry', tm(bars[t.inI].hms) + ' ' + t.inPx], ['exit', tm(bars[t.outI].hms) + ' ' + g2(t.outPx, 1) + ' ' + t.why], ['ret/adj', fx(t.ret) + ' / ' + fx(adj(r))],
      ['mfe/mae', fx(t.mfe) + ' / ' + fx(t.mae)], ['stop', sp.toFixed(1)], ['delay', f2(r.delay)], ['chase', fx(r.chase)], ['capRise', fx(r.capRise)],
      ['rise', fx(r.rise)], ['openGap', fx(r.openGap)], ['prevChg', fx(r.prevChg)], ['late', r.late ? 'Y' : '']];
    const html = '<!doctype html><html><head><meta charset="utf-8"><title>' + (k + 1) + ' ' + cs.cat + ' ' + it.code + ' ' + it.date + '</title>' + STY + '</head><body>' +
      '<a href="index.html">index</a> &nbsp; <b>#' + (k + 1) + ' ' + cs.cat + '</b>' +
      '<table><tr>' + info.slice(0, 8).map(x => '<th>' + x[0] + '</th>').join('') + '</tr><tr>' + info.slice(0, 8).map(x => '<td>' + x[1] + '</td>').join('') + '</tr>' +
      '<tr>' + info.slice(8).map(x => '<th>' + x[0] + '</th>').join('') + '</tr><tr>' + info.slice(8).map(x => '<td>' + x[1] + '</td>').join('') + '</tr></table>' +
      '<canvas id="cv" style="width:100%;height:80vh;display:block"></canvas><div id="tip"></div><pre>' + pg.join('\n') + '</pre>' +
      '<script>window.SZDATA=' + JSON.stringify(D) + ';</script><script>' + RENDER + '</script></body></html>';
    fs.writeFileSync(path.join(outDir, fn), html, 'utf8');
    idxR.push('<tr><td>' + (k + 1) + '</td><td>' + cs.cat + '</td><td><a href="' + fn + '">' + it.code + '</a></td><td>' + it.date + '</td><td>' + tm(it.cp.hms) + '</td><td>' +
      tm(bars[t.inI].hms) + '</td><td>' + tm(bars[t.outI].hms) + '</td><td>' + t.why + '</td><td class="' + (adj(r) > 0 ? 'up' : 'dn') + '">' + fx(adj(r)) + '</td><td>' +
      fx(t.mfe) + '</td><td>' + fx(t.mae) + '</td><td>' + f2(r.delay) + '</td></tr>');
    cc.push([k + 1, cs.cat, it.code, it.date, it.cp.hms, it.cp.px, r.es, bars[t.inI].hms, t.inPx, bars[t.outI].hms, f4(t.outPx), t.why, f4(t.ret), f4(adj(r)), f4(t.mfe), f4(t.mae), f4(r.delay), f4(r.chase), f4(r.capRise), r.late ? 1 : 0, fn].join(','));
  });
  if (srcInd.indexOf('recomputed') === 0) ok('chart recompute = engine run (all cases)', mis === 0, 'mismatch=' + mis + ' ' + mis1);
  fs.writeFileSync(path.join(outDir, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><title>S4-3c cases</title>' + STY + '</head><body><h3>S4-3c S000 cap (EntryStart=capture, MaxTrades=1) n=' +
    rows.length + ' adj=' + fx(a0.sumA) + '</h3><pre>' + cl.join('\n') + '\n\n' + wl.join('\n') + '</pre><table><tr><th>#</th><th>cat</th><th>code</th><th>date</th><th>cap</th><th>in</th><th>out</th><th>why</th><th>adj</th><th>mfe</th><th>mae</th><th>delay</th></tr>' +
    idxR.join('') + '</table></body></html>', 'utf8');
  fs.mkdirSync(path.join(RDIR, 'detail'), { recursive: true });
  fs.writeFileSync(path.join(RDIR, 'detail', 'chart_cases.csv'), cc.join('\n') + '\n');
  sums.push('charts=' + path.join(outDir, 'index.html') + ' cases=' + cases.length + ' ind=' + srcInd + ' render.sha12=' + sha(rbuf).slice(0, 12));
  data('HTS check bars (cap=capture bar, in-1=bar before entry, in=entry/signal bar, out=exit bar; amt in 1e8 KRW)', hts);
  }
  return chk.every(c => c.c) ? 'PASS' : 'FAIL';
}

let verdict = 'FAIL', err = null;
try { verdict = main(); } catch (e) { err = e; verdict = 'FAIL'; }
report(verdict, err);
console.log(verdict + ' ' + STEP + ' -> ' + OUTF);
process.exit(verdict === 'PASS' ? 0 : 1);
'@
$code = $head + ($part -replace "`r`n", "`n")
if (Test-Path $Js) { Copy-Item $Js "$Js.bak38" -Force }
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
