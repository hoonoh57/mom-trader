'use strict';
const fs = require('fs'), path = require('path');
const SZ = require('./sz-engine.cjs');
const ROOT = process.argv[2], PFILE = process.argv[3];
function die(m) { console.log('FAIL: ' + m); process.exit(1); }
if (!ROOT || !PFILE) die('usage: node sz-run.cjs <root> <params.json>');
let P;
try { P = SZ.prep(JSON.parse(fs.readFileSync(PFILE, 'utf8').replace(/^\uFEFF/, ''))); } catch (e) { die('params: ' + e.message); }
const tickDir = path.join(ROOT, 'data', 'ticks'), dailyDir = path.join(ROOT, 'data', 'daily'), outDir = path.join(ROOT, 'out', 'trade');
fs.mkdirSync(outDir, { recursive: true });
if (!fs.existsSync(tickDir)) die('no folder: ' + tickDir);
let files = fs.readdirSync(tickDir).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(P.Match));
if (P.Date) files = files.filter(f => f.includes(P.Date));
if (!files.length) die('no tick csv matching "' + P.Match + '" in ' + tickDir);
const RENDER = fs.readFileSync(path.join(__dirname, 'sz-render.js'), 'utf8');

function parseCsv(text) {
  text = text.replace(/^\uFEFF/, '');
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { row.push(f); f = ''; }
    else if (ch === '\n') { row.push(f); rows.push(row); row = []; f = ''; }
    else if (ch !== '\r') f += ch;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows.filter(r => r.length > 1 || r[0] !== '');
}
function num(s) { const t = String(s == null ? '' : s).replace(/[,\s+]/g, ''); return t === '' ? NaN : Number(t); }
function stamp(ts, ds) {
  let t = String(ts == null ? '' : ts).replace(/\D/g, ''); const d = ds != null ? String(ds).replace(/\D/g, '') : '';
  if (t.length >= 14) return t.slice(0, 14);
  if ((t.length === 6 || t.length === 5) && d.length >= 8) return d.slice(0, 8) + t.padStart(6, '0');
  if (t.length === 4 && d.length >= 8) return d.slice(0, 8) + t + '00';
  if (t.length === 10 || t.length === 13) {
    const ms = t.length === 13 ? Number(t) : Number(t) * 1000;
    return new Date(ms + 9 * 3600e3).toISOString().replace(/\D/g, '').slice(0, 14);
  }
  return null;
}
function loadTicks(file) {
  const rows = parseCsv(fs.readFileSync(file, 'utf8'));
  if (rows.length < 2) throw new Error('empty csv');
  const hdr = rows[0].map(x => x.trim().toLowerCase());
  const find = names => { for (const nm of names) { const k = hdr.indexOf(nm); if (k >= 0) return k; } return -1; };
  const iT = find(['cntr_tm', 'time', 'ts', 'datetime', 'timestamp', 'dt']);
  const iD = find(['date', 'trading_date', 'tradingdate', 'trade_date', 'day']);
  const iO = find(['open', 'open_pric', 'o']), iH = find(['high', 'high_pric', 'h']), iL = find(['low', 'low_pric', 'l']);
  const iC = find(['close', 'cur_prc', 'c', 'price']), iV = find(['volume', 'trde_qty', 'vol', 'v', 'qty']);
  if ([iT, iO, iH, iL, iC, iV].some(k => k < 0)) throw new Error('columns not found, header=' + hdr.join('|'));
  const bars = [];
  for (let r = 1; r < rows.length; r++) {
    const row = rows[r], st = stamp(row[iT], iD >= 0 ? row[iD] : null);
    if (!st) continue;
    let o = Math.abs(num(row[iO])), h = Math.abs(num(row[iH])), l = Math.abs(num(row[iL])), c = Math.abs(num(row[iC])), v = Math.abs(num(row[iV]));
    if (!(c > 0) || !isFinite(v)) continue;
    if (!(o > 0)) o = c;
    h = Math.max(h > 0 ? h : c, o, c); l = Math.min(l > 0 ? l : c, o, c);
    const y = +st.slice(0, 4), mo = +st.slice(4, 6), d = +st.slice(6, 8), hh = +st.slice(8, 10), mi = +st.slice(10, 12), ss = +st.slice(12, 14);
    bars.push({ d: st.slice(0, 8), hms: hh * 10000 + mi * 100 + ss, t: Date.UTC(y, mo - 1, d, hh, mi, ss) / 1000, o, h, l, c, v });
  }
  if (bars.length < 10) throw new Error('too few bars: ' + bars.length + ', header=' + hdr.join('|'));
  if (bars[0].t > bars[bars.length - 1].t) bars.reverse();
  for (let i = 1; i < bars.length; i++) if (bars[i].t < bars[i - 1].t) { bars.sort((a, b) => a.t - b.t); break; }
  return bars;
}
function loadDaily(code, date, warn) {
  const f = path.join(dailyDir, code + '.csv');
  if (!fs.existsSync(f)) { warn.push('일봉 파일 없음(' + f + '): 전일 상한가/급등 필터 미적용 → 12_fetch_daily.ps1 실행'); return null; }
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), h = rows[0].map(x => x.trim().toLowerCase());
  const iD = h.indexOf('date'), iC = h.indexOf('close'), iP = h.indexOf('chg_pct');
  if (iD < 0 || iC < 0) { warn.push('일봉 열 없음: ' + h.join('|')); return null; }
  const list = rows.slice(1).map(r => ({ d: String(r[iD]).replace(/\D/g, '').slice(0, 8), c: Math.abs(num(r[iC])), p: iP >= 0 ? num(r[iP]) : NaN }))
    .filter(x => x.d.length === 8 && x.c > 0).sort((a, b) => a.d < b.d ? -1 : a.d > b.d ? 1 : 0);
  let k = -1; for (let j = 0; j < list.length; j++) if (list[j].d < date) k = j;
  if (k < 0) { warn.push('일봉에 ' + date + ' 이전 데이터 없음'); return null; }
  let chg = list[k].p;
  if (!isFinite(chg) && k > 0) chg = (list[k].c / list[k - 1].c - 1) * 100;
  return { d: list[k].d, chg };
}
const fmtT = hms => { const s = String(hms).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };
const fmtPx = x => x == null || !isFinite(x) ? '-' : Math.round(x).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
const sgn = x => (x > 0 ? '+' : '') + x.toFixed(2);
const RULE_KO = { hold: '보유', immediate: '즉시', macd_zero: '강도0선↓', macd_sig: '시그널↓', supertrend: 'ST하락', trail: '트레일' };
const ST_KO = { 'S-': '안심·목표전', 'S+': '안심·목표후', 'U-': '이탈·목표전', 'U+': '이탈·목표후' };
function whyKo(w) {
  if (w === 'stop') return '손절'; if (w === 'time') return '시간청산'; if (w === 'eod') return '데이터끝';
  const p = w.split(':'); return (ST_KO[p[0]] || p[0]) + ' ' + (RULE_KO[p[1]] || p[1]);
}
function sumLine(S) { return '거래 ' + S.n + ', 승 ' + S.w + ', 합계 ' + sgn(S.sum) + '%, 평균 ' + sgn(S.avg) + '%, 평균MFE ' + sgn(S.avgMfe) + '%'; }
function tradeTable(title, tr, bars) {
  let h = '<h3>' + title + '</h3><table><tr><th>#</th><th>진입</th><th>진입가</th><th>청산</th><th>청산가</th><th>사유</th><th>순수익%</th><th>MFE%</th><th>MAE%</th><th>봉수</th><th>목표도달</th></tr>';
  tr.forEach((t, k) => {
    h += '<tr><td>' + (k + 1) + '</td><td>' + fmtT(bars[t.inI].hms) + '</td><td>' + fmtPx(t.inPx) + '</td><td>' + fmtT(bars[t.outI].hms) +
      '</td><td>' + fmtPx(t.outPx) + '</td><td>' + whyKo(t.why) + '</td><td class="' + (t.ret > 0 ? 'up' : 'dn') + '">' + sgn(t.ret) +
      '</td><td>' + sgn(t.mfe) + '</td><td>' + sgn(t.mae) + '</td><td>' + t.bars + '</td><td>' + (t.reached ? 'Y' : '') + '</td></tr>';
  });
  if (!tr.length) h += '<tr><td colspan="11">거래 없음</td></tr>';
  return h + '</table>';
}
const STYLE = '<style>body{background:#111;color:#ddd;font:13px "Malgun Gothic",sans-serif;margin:8px}a{color:#6cf}' +
  'table{border-collapse:collapse;margin:6px 0}td,th{border:1px solid #333;padding:3px 8px;text-align:right}th{background:#222}' +
  '.up{color:#ff6b6b}.dn{color:#5cc8ff}.warn{color:#ffcc33}#tip{position:absolute;display:none;pointer-events:none;background:rgba(0,0,0,.88);' +
  'border:1px solid #555;padding:6px 8px;font:12px "Malgun Gothic",sans-serif;line-height:1.45}</style>';

const sum = [], idx = [], csv = ['\uFEFFcode,date,mode,no,in_time,in_px,out_time,out_px,why,ret_pct,mfe_pct,mae_pct,bars,reached'];
let failed = 0, totS = [], totB = [];
for (const f of files) {
  try {
    const code = f.split('_')[0];
    const m = f.match(/_(\d+)t_/);
    const Pf = Object.assign({}, P, { TickScope: m ? Number(m[1]) : P.TickScope });
    const bars = loadTicks(path.join(tickDir, f));
    const dm = f.match(/(\d{8})\.csv$/i);
    const date = P.Date || (dm ? dm[1] : bars[bars.length - 1].d);
    const start = bars.findIndex(b => b.d === date);
    if (start < 0) throw new Error('target date ' + date + ' not in file');
    const warn = [];
    const dayComplete = bars[start].hms <= Pf._sessMax;
    if (!dayComplete) warn.push('당일 첫 봉 ' + fmtT(bars[start].hms) + ' (장 시작 봉 아님): 누적대금 판정 불가 → 진입 없음');
    if (start < Pf.EmaLen * 3) warn.push('EMA' + Pf.EmaLen + ' 워밍업 ' + start + '봉(권장 ' + Pf.EmaLen * 3 + '+): 영웅문 값과 다를 수 있음');
    const dly = loadDaily(code, date, warn);
    let limKind = null;
    if (dly && isFinite(dly.chg)) { if (dly.chg >= Pf.LimPct) limKind = 'limit'; else if (dly.chg >= Pf.SurgePct) limKind = 'surge'; }
    const ind = SZ.compute(bars, Pf);
    const ctx = { start, date, dayComplete, limKind };
    const R = SZ.simulate(bars, ind, Pf, ctx);
    const PB = Object.assign({}, Pf, { SafeBelow: 'macd_sig', SafeAbove: 'macd_sig', UnsafeBelow: 'macd_sig', UnsafeAbove: 'macd_sig' });
    const RB = SZ.simulate(bars, ind, PB, ctx);
    const S1 = SZ.summarize(R.trades), S2 = SZ.summarize(RB.trades);
    totS = totS.concat(R.trades); totB = totB.concat(RB.trades);
    const addCsv = (mode, tr) => tr.forEach((t, k) => csv.push([code, date, mode, k + 1, fmtT(bars[t.inI].hms), t.inPx.toFixed(0),
      fmtT(bars[t.outI].hms), t.outPx.toFixed(0), whyKo(t.why), t.ret.toFixed(3), t.mfe.toFixed(3), t.mae.toFixed(3), t.bars, t.reached ? 1 : 0].join(',')));
    addCsv('safezone', R.trades); addCsv('baseline', RB.trades);
    // 차트는 대상일 + 앞쪽 300봉만 표시
    const v0 = Math.max(0, start - 300), sl = a => a.slice(v0);
    const rd = (a, k) => a.slice(v0).map(x => x == null || !isFinite(x) ? null : +Number(x).toFixed(k));
    const shiftT = t => Object.assign({}, t, { inI: t.inI - v0, outI: t.outI - v0 });
    const D = {
      o: sl(bars.map(b => b.o)), h: sl(bars.map(b => b.h)), l: sl(bars.map(b => b.l)), c: sl(bars.map(b => b.c)), hms: sl(bars.map(b => b.hms)),
      mom: rd(ind.mom, 3), n: rd(ind.n, 5), sig: rd(ind.sig, 5), ema: rd(ind.ema, 1), st: rd(ind.st, 1), stDir: sl(ind.stDir),
      amt: rd(ind.amt, 0), taamt: rd(ind.taamt, 0), big: sl(ind.big), cnt1: sl(ind.cnt1), thr: rd(ind.thr, 0), tickOk: sl(ind.tickOk),
      disp: rd(ind.disp, 2), safe: sl(ind.safe),
      trades: R.trades.map(shiftT), marks: R.marks.map(m => Object.assign({}, m, { i: m.i - v0 })),
      emaLen: Pf.EmaLen, momLen: Pf.MomLen, safeTh: Pf.SafeTh, bigMode: Pf.BigMode, tickK: Pf.TickK };
    const rejTxt = Object.keys(R.rej).map(k => k + '=' + R.rej[k]).join(' ');
    const head = '<h2>' + code + ' · ' + date + '</h2><div>전일 ' + (dly && isFinite(dly.chg) ? sgn(dly.chg) + '%' : '-') +
      ' / 구분 ' + (limKind || '일반') + ' (' + R.limMode + ') · ARM ' + R.arms + ' · 신호 ' + R.sigs + ' · 탈락 ' + rejTxt + '</div>' +
      '<div class="up">SafeZone: ' + sumLine(S1) + '</div><div class="dn">기본규칙(시그널↓): ' + sumLine(S2) + '</div>' +
      warn.map(w => '<div class="warn">⚠ ' + w + '</div>').join('');
    const html = '<!doctype html><html><head><meta charset="utf-8"><title>' + code + ' ' + date + '</title>' + STYLE + '</head><body>' +
      '<a href="index.html">← 목록</a>' + head + '<canvas id="cv" style="width:100%;height:78vh;display:block"></canvas><div id="tip"></div>' +
      tradeTable('SafeZone 거래', R.trades, bars) + tradeTable('기본규칙 거래', RB.trades, bars) +
      '<script>window.SZDATA=' + JSON.stringify(D) + ';</script><script>' + RENDER + '</script></body></html>';
    const outF = code + '_' + date + '.html';
    fs.writeFileSync(path.join(outDir, outF), html, 'utf8');
    idx.push('<tr><td><a href="' + outF + '">' + code + '</a></td><td>' + date + '</td><td>' + S1.n + '</td><td class="' + (S1.sum > 0 ? 'up' : 'dn') + '">' + sgn(S1.sum) +
      '</td><td>' + S2.n + '</td><td class="' + (S2.sum > 0 ? 'up' : 'dn') + '">' + sgn(S2.sum) + '</td></tr>');
    sum.push('[' + code + ' ' + date + '] 전일 ' + (dly && isFinite(dly.chg) ? sgn(dly.chg) + '%' : '-') + ' ' + (limKind || '일반') + ' | ARM ' + R.arms + ' 신호 ' + R.sigs + ' | 탈락 ' + rejTxt);
    sum.push('   SafeZone : ' + sumLine(S1));
    R.trades.forEach((t, k) => sum.push('     ' + (k + 1) + ') ' + fmtT(bars[t.inI].hms) + ' ' + fmtPx(t.inPx) + ' → ' + fmtT(bars[t.outI].hms) + ' ' + fmtPx(t.outPx) +
      ' ' + sgn(t.ret) + '% (MFE ' + sgn(t.mfe) + ', MAE ' + sgn(t.mae) + ') ' + whyKo(t.why)));
    sum.push('   기본규칙 : ' + sumLine(S2));
    warn.forEach(w => sum.push('   [주의] ' + w));
    console.log('OK ' + f + ' sz=' + S1.n + '/' + S1.sum.toFixed(2) + ' base=' + S2.n + '/' + S2.sum.toFixed(2));
  } catch (e) { failed++; sum.push('[실패] ' + f + ': ' + e.message); console.log('FAIL ' + f + ': ' + e.message); }
}
const TS = SZ.summarize(totS), TB = SZ.summarize(totB);
sum.push('=== 전체 SafeZone : ' + sumLine(TS));
sum.push('=== 전체 기본규칙 : ' + sumLine(TB));
fs.writeFileSync(path.join(outDir, 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><title>SafeZone</title>' + STYLE + '</head><body><h2>SafeZone 2단계</h2>' +
  '<div class="up">SafeZone: ' + sumLine(TS) + '</div><div class="dn">기본규칙: ' + sumLine(TB) + '</div>' +
  '<table><tr><th>종목</th><th>일자</th><th>SZ 거래</th><th>SZ 합계%</th><th>기본 거래</th><th>기본 합계%</th></tr>' + idx.join('') + '</table></body></html>', 'utf8');
fs.writeFileSync(path.join(outDir, 'trades.csv'), csv.join('\r\n'), 'utf8');
fs.writeFileSync(path.join(outDir, 'summary.txt'), sum.join('\r\n'), 'utf8');
console.log(failed ? 'DONE WITH ' + failed + ' FAIL' : 'DONE ' + files.length + ' files');
process.exit(failed ? 2 : 0);