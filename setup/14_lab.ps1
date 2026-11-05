#requires -Version 5.1
# 14_lab.ps1 : 기준선 박제(-Freeze) + 버전 전략 비교/생존 저장
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [switch]$Freeze,
  [int]$SearchTime = 900,
  [int]$MinStockDays = 2, [int]$ConfirmStockDays = 20, [int]$MinTrades = 3,
  [double]$MarginPct = 0, [double]$WinShare = 0.5, [double]$MddTol = 1.0,
  [string]$Only = '',
  [switch]$NoOpen
)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "[성공] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[실패] $m" -ForegroundColor Red }
function Info($m) { Write-Host "  $m" }
function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $dir = Split-Path $Path -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
  if ([System.IO.File]::ReadAllText($Path, $enc) -ne $Text) { throw "write verify failed: $Path" }
}
Write-Host '=== mom-trader 전략 연구소 (기준선 박제 / 생존 판정) ==='
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'node 없음'; exit 1 }
$tools = Join-Path $Root 'tools'
$out   = Join-Path $Root 'out\lab'

$lab = @'
'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const ROOT = process.argv[2], MODE = process.argv[3], OFILE = process.argv[4];
function die(m) { console.log('FAIL: ' + m); process.exit(1); }
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const readJson = f => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const writeJson = (f, o) => fs.writeFileSync(f, JSON.stringify(o, null, 2), 'utf8');

function stats(tr) {
  let n = tr.length, w = 0, sum = 0, gw = 0, gl = 0, eq = 0, pk = 0, mdd = 0, mfe = 0;
  for (const t of tr) {
    if (t.ret > 0) { w++; gw += t.ret; } else gl -= t.ret;
    sum += t.ret; mfe += t.mfe; eq += t.ret; if (eq > pk) pk = eq; if (pk - eq > mdd) mdd = pk - eq;
  }
  return { n, w, sum, avg: n ? sum / n : 0, pf: gl > 0 ? gw / gl : (gw > 0 ? 99 : 0), mdd, avgMfe: n ? mfe / n : 0 };
}
function judge(c, cper, b, bper, nItems, O) {
  const r = [];
  if (nItems < O.MinStockDays) r.push('데이터부족(' + nItems + '<' + O.MinStockDays + ')');
  if (c.n < O.MinTrades) r.push('거래부족(' + c.n + ')');
  if (!(c.sum > b.sum + O.MarginPct)) r.push('합계미달');
  let beat = 0; for (let k = 0; k < cper.length; k++) if (cper[k].sum >= bper[k].sum) beat++;
  const share = cper.length ? beat / cper.length : 0;
  if (share < O.WinShare) r.push('우위' + Math.round(share * 100) + '%');
  if (c.mdd > b.mdd + O.MddTol) r.push('MDD악화');
  return { ok: !r.length, reasons: r, share };
}

if (MODE === 'selftest') {
  let pass = 0, fail = 0;
  const ok = (n, c, i) => { if (c) pass++; else { fail++; console.log('FAIL ' + n + (i !== undefined ? ' :: ' + i : '')); } };
  const s = stats([{ ret: 2, mfe: 3 }, { ret: -1, mfe: 1 }, { ret: -2, mfe: 0.5 }, { ret: 4, mfe: 5 }]);
  ok('stats-sum', Math.abs(s.sum - 3) < 1e-9, s.sum); ok('stats-win', s.w === 2);
  ok('stats-pf', Math.abs(s.pf - 2) < 1e-9, s.pf); ok('stats-mdd', Math.abs(s.mdd - 3) < 1e-9, s.mdd);
  ok('stats-empty', stats([]).n === 0 && stats([]).pf === 0);
  const O = { MinStockDays: 2, MinTrades: 3, MarginPct: 0, WinShare: 0.5, MddTol: 1 };
  const b = { n: 5, sum: 5, mdd: 2 }, bp = [{ sum: 3 }, { sum: 2 }];
  ok('judge-pass', judge({ n: 4, sum: 6, mdd: 2.5 }, [{ sum: 4 }, { sum: 2 }], b, bp, 2, O).ok);
  ok('judge-sum', !judge({ n: 4, sum: 5, mdd: 1 }, [{ sum: 3 }, { sum: 2 }], b, bp, 2, O).ok);
  ok('judge-mdd', !judge({ n: 4, sum: 9, mdd: 3.5 }, [{ sum: 5 }, { sum: 4 }], b, bp, 2, O).ok);
  ok('judge-share', !judge({ n: 4, sum: 6, mdd: 1 }, [{ sum: 5.5 }, { sum: 0.5 }], b, bp, 2, Object.assign({}, O, { WinShare: 0.75 })).ok);
  ok('judge-data', !judge({ n: 4, sum: 6, mdd: 1 }, [{ sum: 6 }], b, [{ sum: 5 }], 1, O).ok);
  ok('judge-trades', !judge({ n: 2, sum: 6, mdd: 1 }, [{ sum: 4 }, { sum: 2 }], b, bp, 2, O).ok);
  console.log((fail ? 'SELFTEST FAIL ' : 'SELFTEST OK ') + pass + '/' + (pass + fail));
  process.exit(fail ? 1 : 0);
}
if (!ROOT || !OFILE || (MODE !== 'freeze' && MODE !== 'run')) die('usage: node sz-lab.cjs <root> <freeze|run|selftest> <opts.json>');
const O = readJson(OFILE);
const SD = path.join(ROOT, 'strategies'), ENG = path.join(SD, 'engines'), FRZ = path.join(SD, 'frozen');
const CAND = path.join(SD, 'candidates'), SURV = path.join(SD, 'survivors'), MAN = path.join(SD, 'manifest.json');
const OUT = path.join(ROOT, 'out', 'lab'), tickDir = path.join(ROOT, 'data', 'ticks'), dailyDir = path.join(ROOT, 'data', 'daily');
[SD, ENG, FRZ, CAND, SURV, OUT].forEach(d => fs.mkdirSync(d, { recursive: true }));
const L = []; const say = s => L.push(s);

// ---- data loaders (sz-run.cjs 와 동일 로직)
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
function loadTicksText(text) {
  const rows = parseCsv(text);
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
  if (bars.length < 10) throw new Error('too few bars: ' + bars.length);
  if (bars[0].t > bars[bars.length - 1].t) bars.reverse();
  for (let i = 1; i < bars.length; i++) if (bars[i].t < bars[i - 1].t) { bars.sort((a, b) => a.t - b.t); break; }
  return bars;
}
function loadDaily(code, date, warn) {
  const f = path.join(dailyDir, code + '.csv');
  if (!fs.existsSync(f)) { warn.push('일봉 없음'); return null; }
  const rows = parseCsv(fs.readFileSync(f, 'utf8')), h = rows[0].map(x => x.trim().toLowerCase());
  const iD = h.indexOf('date'), iC = h.indexOf('close'), iP = h.indexOf('chg_pct');
  if (iD < 0 || iC < 0) { warn.push('일봉 열 없음'); return null; }
  const list = rows.slice(1).map(r => ({ d: String(r[iD]).replace(/\D/g, '').slice(0, 8), c: Math.abs(num(r[iC])), p: iP >= 0 ? num(r[iP]) : NaN }))
    .filter(x => x.d.length === 8 && x.c > 0).sort((a, b) => a.d < b.d ? -1 : a.d > b.d ? 1 : 0);
  let k = -1; for (let j = 0; j < list.length; j++) if (list[j].d < date) k = j;
  if (k < 0) { warn.push('일봉 전일 없음'); return null; }
  let chg = list[k].p;
  if (!isFinite(chg) && k > 0) chg = (list[k].c / list[k - 1].c - 1) * 100;
  return { d: list[k].d, chg };
}
function dailyHash(code) { const f = path.join(dailyDir, code + '.csv'); return fs.existsSync(f) ? sha(fs.readFileSync(f)).slice(0, 12) : 'none'; }
function dayMfe(it) {
  const st = O.SearchTime * 100; let k = -1;
  for (let i = it.start; i < it.bars.length && it.bars[i].d === it.date; i++) if (it.bars[i].hms >= st) { k = i; break; }
  if (k < 0) return null;
  const sp = it.bars[k].c; let hi = sp;
  for (let i = k; i < it.bars.length && it.bars[i].d === it.date && it.bars[i].hms <= 153000; i++) if (it.bars[i].h > hi) hi = it.bars[i].h;
  return { sp, mfe: (hi / sp - 1) * 100 };
}
function loadDataset(match) {
  if (!fs.existsSync(tickDir)) die('no folder ' + tickDir);
  const files = fs.readdirSync(tickDir).filter(f => f.toLowerCase().endsWith('.csv') && f.includes(match)).sort();
  if (!files.length) die('no tick csv matching ' + match);
  const items = [];
  for (const f of files) {
    try {
      const buf = fs.readFileSync(path.join(tickDir, f));
      const bars = loadTicksText(buf.toString('utf8'));
      const code = f.split('_')[0], dm = f.match(/(\d{8})\.csv$/i), m = f.match(/_(\d+)t_/);
      const date = dm ? dm[1] : bars[bars.length - 1].d;
      const start = bars.findIndex(b => b.d === date);
      if (start < 0) throw new Error('target date not in file');
      const warn = [], dly = loadDaily(code, date, warn);
      const it = { f, code, date, bars, start, scope: m ? Number(m[1]) : 120, dly, warn, fp: f + ':' + sha(buf).slice(0, 16) + ':' + dailyHash(code) };
      it.dm = dayMfe(it);
      items.push(it);
    } catch (e) { say('[제외] ' + f + ': ' + e.message); }
  }
  return { items, id: sha(items.map(x => x.fp).join('|')).slice(0, 10) };
}
function runStrategy(eng, params, ds) {
  const per = []; let all = [];
  for (const it of ds.items) {
    const P = eng.prep(Object.assign({}, params, { Date: '', TickScope: it.scope }));
    const dayComplete = it.bars[it.start].hms <= P._sessMax;
    let limKind = null;
    if (it.dly && isFinite(it.dly.chg)) { if (it.dly.chg >= P.LimPct) limKind = 'limit'; else if (it.dly.chg >= P.SurgePct) limKind = 'surge'; }
    const ind = eng.compute(it.bars, P);
    const R = eng.simulate(it.bars, ind, P, { start: it.start, date: it.date, dayComplete, limKind });
    const tr = R.trades.map(t => ({ in: it.bars[t.inI].hms, inPx: t.inPx, out: it.bars[t.outI].hms, outPx: t.outPx, why: t.why, ret: t.ret, mfe: t.mfe }));
    per.push(Object.assign({ f: it.f }, stats(tr), { trades: tr }));
    all = all.concat(tr);
  }
  return { per, tot: stats(all) };
}
function loadEngine(man, name) {
  const e = man.engines && man.engines[name];
  if (!e) throw new Error('engine not registered: ' + name);
  const f = path.join(ENG, e.file), buf = fs.readFileSync(f);
  if (sha(buf) !== e.sha256) throw new Error('engine ' + name + ' hash mismatch (frozen file modified)');
  return require(f);
}
function resolveParams(base, ov, lib) {
  const b = lib[base]; if (!b) throw new Error('base not found: ' + base);
  const p = Object.assign({}, b.params);
  for (const k of Object.keys(ov || {})) { if (!(k in p)) throw new Error('unknown param: ' + k); p[k] = ov[k]; }
  return p;
}
const pct = x => (x > 0 ? '+' : '') + Number(x).toFixed(2);
const fmtT = h => { const s = String(h).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };

// ================================================================ FREEZE
if (MODE === 'freeze') {
  if (fs.existsSync(MAN)) die('already frozen: ' + MAN + ' (baseline is immutable)');
  const src = path.join(ROOT, 'tools', 'sz-engine.cjs');
  if (!fs.existsSync(src)) die('missing ' + src + ' (run 13_trade.ps1)');
  const buf = fs.readFileSync(src);
  if (!buf.toString('utf8').includes('ArmMode')) die('engine not patched (run 13a_patch.ps1)');
  const ef = path.join(ENG, 'v1.cjs'); fs.writeFileSync(ef, buf); try { fs.chmodSync(ef, 0o444); } catch (e) { }
  const pf = path.join(ROOT, 'out', 'trade', 'params.json');
  if (!fs.existsSync(pf)) die('missing ' + pf + ' (run 13_trade.ps1)');
  const eng = require(ef), raw = readJson(pf); raw.Date = '';
  const full = eng.prep(raw), params = {};
  Object.keys(full).forEach(k => { if (k[0] !== '_') params[k] = full[k]; });
  const now = new Date().toISOString();
  const S000 = { id: 'S000', name: 'SafeZone v1 기준선', engine: 'v1', base: null, frozen: true, created: now, note: '13_trade + 13a_patch 기본값', params };
  const R000 = { id: 'R000', name: '기본규칙(시그널↓) 참고', engine: 'v1', base: null, frozen: true, created: now, note: '비교용',
    params: Object.assign({}, params, { SafeBelow: 'macd_sig', SafeAbove: 'macd_sig', UnsafeBelow: 'macd_sig', UnsafeAbove: 'macd_sig' }) };
  const ds = loadDataset(params.Match);
  if (!ds.items.length) die('no usable tick files');
  const r = runStrategy(eng, params, ds), ref = {};
  ds.items.forEach((it, k) => { ref[it.fp] = { n: r.per[k].n, sum: r.per[k].sum }; });
  for (const s of [S000, R000]) { const f = path.join(FRZ, s.id + '.json'); writeJson(f, s); try { fs.chmodSync(f, 0o444); } catch (e) { } }
  writeJson(MAN, { created: now, baseline: 'S000', engines: { v1: { file: 'v1.cjs', sha256: sha(buf), from: 'tools/sz-engine.cjs' } },
    frozen: { S000: sha(JSON.stringify(S000.params)), R000: sha(JSON.stringify(R000.params)) }, ref: { dataset: ds.id, files: ref }, seeded: false });
  say('기준선 박제 완료: 엔진 v1 sha256 ' + sha(buf).slice(0, 16) + '…');
  ds.items.forEach((it, k) => say('  ' + it.code + ' ' + it.date + ': 거래 ' + r.per[k].n + ', 합계 ' + pct(r.per[k].sum) + '%'));
  say('  전체: 거래 ' + r.tot.n + ', 승 ' + r.tot.w + ', 합계 ' + pct(r.tot.sum) + '%  ← 13_trade 결과와 같아야 함');
  fs.writeFileSync(path.join(OUT, 'summary.txt'), L.join('\r\n'), 'utf8');
  console.log('FROZEN S000 n=' + r.tot.n + ' sum=' + r.tot.sum.toFixed(2));
  process.exit(0);
}

// ================================================================ RUN
if (!fs.existsSync(MAN)) die('not frozen yet: run 14_lab.ps1 -Freeze');
const man = readJson(MAN), lib = {};
for (const f of fs.readdirSync(FRZ).filter(x => x.endsWith('.json'))) {
  const s = readJson(path.join(FRZ, f));
  if (!man.frozen || man.frozen[s.id] !== sha(JSON.stringify(s.params))) die('frozen strategy modified or unknown: ' + s.id);
  lib[s.id] = s;
}
const B = lib[man.baseline]; if (!B) die('baseline missing: ' + man.baseline);
const SEED = [
  ['C001', '안심 이탈 히스테리시스 99.5', { SafeExitTh: 99.5 }, 'Mom 100선 잔진동으로 인한 이탈·목표전 시그널↓ 소손실 억제'],
  ['C002', '안심 진입/이탈 2봉 확인', { SafeConfirm: 2 }, '안심존 깜빡임 억제'],
  ['C003', '이탈·목표전 ST하락', { UnsafeBelow: 'supertrend' }, '이탈 직후 시그널↓ 털림 방지'],
  ['C004', '이탈·목표전 강도0선', { UnsafeBelow: 'macd_zero' }, '이탈 직후 시그널↓ 털림 방지'],
  ['C005', '이탈·목표후 트레일 1.5%', { UnsafeAbove: 'trail', TrailPct: 1.5 }, '고MFE 꼬리 수익 연장'],
  ['C006', '안심·목표후 트레일 2%', { SafeAbove: 'trail', TrailPct: 2 }, '목표 후 수익 잠금'],
  ['C007', '목표 3%', { TargetPct: 3 }, ''],
  ['C008', '목표 7%', { TargetPct: 7 }, '고MFE 종목 목표 상향'],
  ['C009', '체결속도 K1.2', { TickK: 1.2 }, ''],
  ['C010', '재진입 간격 5봉', { ReentryGap: 5 }, ''],
  ['C011', '히스테리시스+ST', { SafeExitTh: 99.5, UnsafeBelow: 'supertrend' }, 'C001+C003'],
  ['C012', '손절 2%', { StopPct: 2 }, '']
];
if (!man.seeded) {
  const now = new Date().toISOString(); let w = 0;
  for (const [id, name, ov, note] of SEED) {
    const f = path.join(CAND, id + '.json');
    if (!fs.existsSync(f)) { writeJson(f, { id, name, engine: 'v1', base: 'S000', overrides: ov, note, created: now }); w++; }
  }
  man.seeded = true; writeJson(MAN, man); say('[정보] 후보 전략 ' + w + '개 생성: ' + CAND);
}
const surv = {};
for (const f of fs.readdirSync(SURV).filter(x => x.endsWith('.json'))) { const s = readJson(path.join(SURV, f)); surv[s.id] = s; if (!lib[s.id]) lib[s.id] = s; }
const engC = {}; const getEng = n => engC[n] || (engC[n] = loadEngine(man, n));
const ds = loadDataset(B.params.Match);
if (!ds.items.length) die('no usable tick files');
const base = runStrategy(getEng(B.engine), B.params, ds);
let checked = 0;
ds.items.forEach((it, k) => {
  const r = man.ref.files[it.fp]; if (!r) return; checked++;
  const p = base.per[k];
  if (p.n !== r.n || Math.abs(p.sum - r.sum) > 1e-6) die('baseline reproduction mismatch ' + it.f + ': now n=' + p.n + ' sum=' + p.sum.toFixed(4) + ' / ref n=' + r.n + ' sum=' + r.sum.toFixed(4));
});
const only = String(O.Only || '').split(',').map(s => s.trim()).filter(Boolean);
const want = id => !only.length || only.indexOf(id) >= 0;
const runs = [{ def: B, params: B.params, kind: 'baseline', res: base }];
for (const id of Object.keys(lib)) if (id !== B.id && lib[id].frozen && want(id)) runs.push({ def: lib[id], params: lib[id].params, kind: 'reference' });
for (const id of Object.keys(surv).sort()) if (want(id)) runs.push({ def: surv[id], params: surv[id].params, kind: 'survivor' });
let errs = 0;
for (const f of fs.readdirSync(CAND).filter(x => x.endsWith('.json')).sort()) {
  let c; try { c = readJson(path.join(CAND, f)); } catch (e) { say('[오류] ' + f + ': JSON ' + e.message); errs++; continue; }
  if (!c.id || surv[c.id] || (lib[c.id] && lib[c.id].frozen) || !want(c.id)) continue;
  try { runs.push({ def: c, params: resolveParams(c.base || B.id, c.overrides, lib), kind: 'candidate' }); }
  catch (e) { say('[오류] ' + c.id + ': ' + e.message); errs++; }
}
const totMfe = ds.items.reduce((s, it) => s + (it.dm ? Math.max(it.dm.mfe, 0) : 0), 0);
for (const r of runs) {
  if (!r.res) { try { r.res = runStrategy(getEng(r.def.engine || 'v1'), r.params, ds); } catch (e) { say('[오류] ' + r.def.id + ': ' + e.message); errs++; r.err = e.message; continue; } }
  r.capture = totMfe > 0 ? r.res.tot.sum / totMfe * 100 : 0;
  if (r.kind !== 'baseline') r.j = judge(r.res.tot, r.res.per, base.tot, base.per, ds.items.length, O);
}
const now = new Date().toISOString(), status = ds.items.length >= O.ConfirmStockDays ? 'alive' : 'provisional';
for (const r of runs) {
  if (r.err) { r.verdict = '오류'; continue; }
  if (r.kind === 'baseline') { r.verdict = '기준선'; continue; }
  if (r.kind === 'reference') { r.verdict = r.j.ok ? '기준초과(참고)' : '기준미달(참고)'; continue; }
  const chk = { at: now, dataset: ds.id, stockDays: ds.items.length, ok: r.j.ok, n: r.res.tot.n, sum: +r.res.tot.sum.toFixed(4),
    baseSum: +base.tot.sum.toFixed(4), mdd: +r.res.tot.mdd.toFixed(4), share: +r.j.share.toFixed(3), reasons: r.j.reasons };
  if (r.kind === 'candidate') {
    if (!r.j.ok) { r.verdict = '탈락'; continue; }
    writeJson(path.join(SURV, r.def.id + '.json'), { id: r.def.id, name: r.def.name, engine: r.def.engine || 'v1', base: r.def.base || B.id,
      overrides: r.def.overrides || {}, params: r.params, note: r.def.note || '', survivedAt: now, status, checks: [chk] });
    r.verdict = '생존(신규 ' + status + ')';
  } else {
    const s = r.def; s.checks = (s.checks || []).filter(x => x.dataset !== ds.id); s.checks.push(chk);
    s.status = r.j.ok ? status : 'lapsed'; writeJson(path.join(SURV, s.id + '.json'), s);
    r.verdict = r.j.ok ? '생존유지(' + status + ')' : '실효(lapsed)';
  }
}
// ---- ledger (append-only)
const LED = path.join(SD, 'ledger.csv');
if (!fs.existsSync(LED)) fs.writeFileSync(LED, '\uFEFFrun_at,dataset,stock_days,id,kind,engine,n,win,sum,avg,pf,mdd,capture,share,verdict,reasons\r\n', 'utf8');
const led = [];
for (const r of runs) {
  if (r.err) continue; const t = r.res.tot;
  led.push([now, ds.id, ds.items.length, r.def.id, r.kind, r.def.engine || 'v1', t.n, t.w, t.sum.toFixed(3), t.avg.toFixed(3), t.pf.toFixed(2), t.mdd.toFixed(3),
    r.capture.toFixed(1), r.j ? r.j.share.toFixed(2) : '', r.verdict, r.j ? r.j.reasons.join('/') : ''].join(','));
}
fs.appendFileSync(LED, led.join('\r\n') + '\r\n', 'utf8');
// ---- outputs
const ok = runs.filter(r => !r.err);
const sorted = [ok[0]].concat(ok.slice(1).sort((a, b) => b.res.tot.sum - a.res.tot.sum));
const tcsv = ['\uFEFFid,code,date,no,in,in_px,out,out_px,why,ret,mfe'];
sorted.forEach(r => r.res.per.forEach((p, k) => p.trades.forEach((t, m) => tcsv.push([r.def.id, ds.items[k].code, ds.items[k].date, m + 1, fmtT(t.in), t.inPx.toFixed(0), fmtT(t.out), t.outPx.toFixed(0), t.why, t.ret.toFixed(3), t.mfe.toFixed(3)].join(',')))));
fs.writeFileSync(path.join(OUT, 'trades.csv'), tcsv.join('\r\n'), 'utf8');
const ST = '<style>body{background:#111;color:#ddd;font:13px "Malgun Gothic",sans-serif;margin:10px}table{border-collapse:collapse;margin:8px 0}' +
  'td,th{border:1px solid #333;padding:3px 8px;text-align:right}th{background:#222}td.l{text-align:left}.up{color:#ff6b6b}.dn{color:#5cc8ff}.sv{color:#7f7;font-weight:bold}.bs{color:#fc3}</style>';
let h = '<!doctype html><html><head><meta charset="utf-8"><title>SafeZone Lab</title>' + ST + '</head><body><h2>전략 연구소 · 데이터 ' + ds.id + ' · 종목일 ' + ds.items.length + '</h2>';
h += '<div>기준선 ' + B.id + ' 재현 검사 ' + checked + '파일 일치 · 생존조건: 합계&gt;기준+' + O.MarginPct + ', 종목일우위≥' + O.WinShare * 100 + '%, MDD≤기준+' + O.MddTol + ', 거래≥' + O.MinTrades + '</div>';
h += '<table><tr><th>ID</th><th>이름</th><th>구분</th><th>엔진</th><th>거래</th><th>승률</th><th>합계%</th><th>평균%</th><th>PF</th><th>MDD</th><th>포착률%</th><th>우위</th><th>판정</th><th>사유</th></tr>';
sorted.forEach(r => {
  const t = r.res.tot, cls = r.kind === 'baseline' ? 'bs' : (r.verdict.indexOf('생존') === 0 ? 'sv' : '');
  h += '<tr><td class="l ' + cls + '">' + r.def.id + '</td><td class="l">' + r.def.name + '</td><td>' + r.kind + '</td><td>' + (r.def.engine || 'v1') + '</td><td>' + t.n + '</td><td>' +
    (t.n ? Math.round(t.w / t.n * 100) : 0) + '%</td><td class="' + (t.sum > 0 ? 'up' : 'dn') + '">' + pct(t.sum) + '</td><td>' + pct(t.avg) + '</td><td>' + t.pf.toFixed(2) + '</td><td>' + t.mdd.toFixed(2) +
    '</td><td>' + r.capture.toFixed(1) + '</td><td>' + (r.j ? Math.round(r.j.share * 100) + '%' : '-') + '</td><td class="' + cls + '">' + r.verdict + '</td><td class="l">' + (r.j ? r.j.reasons.join(', ') : '') + '</td></tr>';
});
h += '</table><h3>종목일별 합계%</h3><table><tr><th>종목</th><th>일자</th><th>당일MFE%</th>' + sorted.map(r => '<th>' + r.def.id + '</th>').join('') + '</tr>';
ds.items.forEach((it, k) => {
  h += '<tr><td>' + it.code + '</td><td>' + it.date + '</td><td>' + (it.dm ? pct(it.dm.mfe) : '-') + '</td>' +
    sorted.map(r => { const s = r.res.per[k].sum; return '<td class="' + (s > 0 ? 'up' : 'dn') + '">' + pct(s) + ' (' + r.res.per[k].n + ')</td>'; }).join('') + '</tr>';
});
fs.writeFileSync(path.join(OUT, 'index.html'), h + '</table></body></html>', 'utf8');
say('데이터 ' + ds.id + ': 종목일 ' + ds.items.length + ' / 기준선 재현 ' + checked + '파일 일치');
ds.items.forEach(it => say('  ' + it.code + ' ' + it.date + ' 당일MFE(' + O.SearchTime + '기준) ' + (it.dm ? pct(it.dm.mfe) + '%' : '-') + (it.warn.length ? ' [' + it.warn.join(',') + ']' : '')));
sorted.forEach(r => {
  const t = r.res.tot;
  say(r.def.id + ' ' + r.def.name + ' | ' + r.verdict + (r.j && r.j.reasons.length ? ' (' + r.j.reasons.join(', ') + ')' : ''));
  say('     거래 ' + t.n + ' 승 ' + t.w + ' 합계 ' + pct(t.sum) + '% 평균 ' + pct(t.avg) + '% PF ' + t.pf.toFixed(2) + ' MDD ' + t.mdd.toFixed(2) + ' 포착률 ' + r.capture.toFixed(1) + '%');
});
const nSurv = runs.filter(r => r.verdict && r.verdict.indexOf('생존') === 0).length;
say('=== 생존 ' + nSurv + ' / 평가 ' + (runs.length - 1) + (status === 'provisional' ? ' (종목일 ' + ds.items.length + '<' + O.ConfirmStockDays + ': 잠정)' : ''));
fs.writeFileSync(path.join(OUT, 'summary.txt'), L.join('\r\n'), 'utf8');
console.log('DONE runs=' + runs.length + ' survivors=' + nSurv + ' errors=' + errs);
process.exit(errs ? 2 : 0);
'@

try { Write-Utf8NoBom (Join-Path $tools 'sz-lab.cjs') $lab; Ok "sz-lab.cjs 기록" } catch { Fail $_.Exception.Message; exit 1 }
$labF = Join-Path $tools 'sz-lab.cjs'
$ErrorActionPreference = 'Continue'
$chk = & node --check $labF 2>&1
if ($LASTEXITCODE -ne 0) { $chk | ForEach-Object { Info $_ }; Fail 'JS 문법 오류 - 위 내용을 붙여주세요'; exit 1 }
$st = & node $labF $Root selftest x 2>&1
$code = $LASTEXITCODE; $st | ForEach-Object { Info $_ }
if ($code -ne 0) { Fail '자가검증 실패'; exit 1 }
Ok '자가검증 통과'

$opt = [ordered]@{ SearchTime = $SearchTime; MinStockDays = $MinStockDays; ConfirmStockDays = $ConfirmStockDays; MinTrades = $MinTrades;
  MarginPct = $MarginPct; WinShare = $WinShare; MddTol = $MddTol; Only = $Only }
$oFile = Join-Path $out 'lab-opts.json'
Write-Utf8NoBom $oFile ($opt | ConvertTo-Json)
$sumF = Join-Path $out 'summary.txt'
if (Test-Path $sumF) { Remove-Item $sumF -Force }
$mode = if ($Freeze) { 'freeze' } else { 'run' }
$rn = & node $labF $Root $mode $oFile 2>&1
$code = $LASTEXITCODE; $rn | ForEach-Object { Info $_ }
if (Test-Path $sumF) { Write-Host '----- 요약 -----'; Get-Content $sumF -Encoding UTF8 | ForEach-Object { Write-Host $_ } }
if ($code -eq 1) { Fail '실행 실패 - 위 FAIL 줄을 붙여주세요'; exit 1 }
if ($code -eq 2) { Fail '일부 전략 오류 (요약의 [오류] 줄 확인)' } else { Ok "완료 ($mode)" }
$index = Join-Path $out 'index.html'
if (-not $Freeze -and -not $NoOpen -and (Test-Path $index)) { Start-Process $index }
