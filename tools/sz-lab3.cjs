'use strict';
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const ROOT = process.argv[2], MODE = process.argv[3], OFILE = process.argv[4];
function die(m) { console.log('FAIL: ' + m); process.exit(1); }
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const readJson = f => JSON.parse(fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, ''));
const writeJson = (f, o) => fs.writeFileSync(f, JSON.stringify(o, null, 2), 'utf8');
const list = s => String(s == null ? '' : s).split(',').map(x => x.trim()).filter(Boolean);
if (!ROOT || !OFILE || ['register', 'selftest', 'run'].indexOf(MODE) < 0) die('usage: node sz-lab3.cjs <root> <register|selftest|run> <opts.json>');
const O = readJson(OFILE);
const SD = path.join(ROOT, 'strategies'), ENG = path.join(SD, 'engines'), FRZ = path.join(SD, 'frozen');
const CAND = path.join(SD, 'candidates'), SURV = path.join(SD, 'survivors'), RISK = path.join(SD, 'risk');
const SURV3 = path.join(SD, 'survivors3'), MAN = path.join(SD, 'manifest.json');
const OUT = path.join(ROOT, 'out', 'lab3'), tickDir = path.join(ROOT, 'data', 'ticks'), dailyDir = path.join(ROOT, 'data', 'daily');
[SURV3, OUT].forEach(d => fs.mkdirSync(d, { recursive: true }));
if (!fs.existsSync(MAN)) die('manifest missing: run 14_lab.ps1 -Freeze first');
const man = readJson(MAN);
function loadEng(name) {
  const e = man.engines && man.engines[name];
  if (!e) die('engine not registered: ' + name);
  const f = path.join(ENG, e.file);
  if (!fs.existsSync(f)) die('engine file missing: ' + f);
  if (sha(fs.readFileSync(f)) !== e.sha256) die('engine ' + name + ' hash mismatch (frozen file modified)');
  return require(f);
}
const V1REJ = ['time', 'count', 'gap', 'lim', 'ema', 'disp', 'tick'];
const TF = ['inI', 'inPx', 'outI', 'outPx', 'why', 'gross', 'ret', 'mfe', 'mae', 'bars', 'reached', 'held'];
function same(a, b) {
  if (a.trades.length !== b.trades.length) return 'trades ' + a.trades.length + ' vs ' + b.trades.length;
  for (let k = 0; k < a.trades.length; k++) for (const f of TF)
    if (a.trades[k][f] !== b.trades[k][f]) return 'trade#' + (k + 1) + ' ' + f + ' ' + a.trades[k][f] + ' vs ' + b.trades[k][f];
  for (const k of V1REJ) if (a.rej[k] !== b.rej[k]) return 'rej.' + k + ' ' + a.rej[k] + ' vs ' + b.rej[k];
  if (a.arms !== b.arms || a.sigs !== b.sigs || a.held !== b.held) return 'arms/sigs/held ' + [a.arms, a.sigs, a.held] + ' vs ' + [b.arms, b.sigs, b.held];
  return null;
}
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

// ================================================================ REGISTER
if (MODE === 'register') {
  const v1 = man.engines && man.engines.v1;
  if (!v1) die('v1 not registered');
  if (sha(fs.readFileSync(path.join(ENG, v1.file))) !== v1.sha256) die('v1 hash mismatch');
  const reg = (name, srcRel, file) => {
    const buf = fs.readFileSync(path.join(ROOT, srcRel)), h = sha(buf), dst = path.join(ENG, file), cur = man.engines[name];
    if (cur && cur.sha256 !== h && !O.Force) die(name + ' already registered with different hash ' + cur.sha256.slice(0, 12) + ' -> ' + h.slice(0, 12) + ' (use -Force during development)');
    if (cur && cur.sha256 === h && fs.existsSync(dst) && sha(fs.readFileSync(dst)) === h) { console.log('REG ' + name + ' unchanged ' + h.slice(0, 12)); return; }
    if (fs.existsSync(dst)) { try { fs.chmodSync(dst, 0o644); } catch (e) { } }
    fs.writeFileSync(dst, buf); try { fs.chmodSync(dst, 0o444); } catch (e) { }
    const hist = cur && cur.sha256 !== h ? (cur.history || []).concat([{ sha256: cur.sha256, until: new Date().toISOString() }]) : (cur && cur.history) || [];
    man.engines[name] = { file, sha256: h, from: srcRel, registered: new Date().toISOString(), history: hist };
    console.log('REG ' + name + ' ' + h.slice(0, 12));
  };
  reg('risk1', 'tools/sz-risk.cjs', 'risk1.cjs');
  reg('v3', 'tools/sz-engine3.cjs', 'v3.cjs');
  writeJson(MAN, man);
  const R = loadEng('risk1');
  const S0 = readJson(path.join(FRZ, man.baseline + '.json'));
  const tgt = Number(S0.params.TargetPct);
  if (!(tgt > 0)) die('baseline TargetPct invalid: ' + S0.params.TargetPct);
  for (const f of fs.readdirSync(RISK).filter(x => /\.json$/i.test(x)).sort()) {
    const fp = path.join(RISK, f), raw = readJson(fp);
    const unk = R.unknownKeys(raw); if (unk.length) die(f + ': unknown keys ' + unk.join(','));
    const v = R.validate(R.load(raw)); if (v.length) die(f + ': invalid ' + v.join(','));
    const tp = raw.position && raw.position.takeProfit;
    if (tp && tp.enabled && Number(tp.ratio == null ? 0.5 : tp.ratio) < 1 && Number(tp.pct) !== tgt) {
      console.log('SYNC ' + f + ' takeProfit.pct ' + tp.pct + ' -> ' + tgt + ' (baseline TargetPct)');
      tp.pct = tgt; writeJson(fp, raw);
    }
  }
  console.log('REGISTER OK baseline=' + man.baseline + ' TargetPct=' + tgt);
  process.exit(0);
}

const R = loadEng('risk1'), V1 = loadEng('v1'), E3 = loadEng('v3')(V1, R);

// ================================================================ SELFTEST
if (MODE === 'selftest') {
  const S0 = readJson(path.join(FRZ, man.baseline + '.json')).params;
  let pass = 0, fail = 0;
  const ok = (n, c, info) => { if (c) pass++; else { fail++; console.log('FAIL ' + n + (info !== undefined ? ' :: ' + info : '')); } };
  function rng(seed) { let s = seed >>> 0 || 1; return () => { s = (Math.imul(s, 1664525) + 1013904223) >>> 0; return s / 4294967296; }; }
  function synth(seed) {
    const r = rng(seed), bars = []; let px = 10000;
    const mk = (d, day, n) => {
      let t = 9 * 3600, drift = 0;
      for (let k = 0; k < n; k++) {
        if (k % 150 === 0) drift = (r() - 0.4) * 0.004;
        t += 5 + Math.floor(r() * 25);
        const o = px, c = Math.max(1000, Math.round(o * (1 + drift + (r() - 0.5) * 0.008)));
        const h = Math.max(o, c) * (1 + r() * 0.003), l = Math.min(o, c) * (1 - r() * 0.003);
        const hh = Math.floor(t / 3600), mi = Math.floor(t % 3600 / 60), ss = t % 60;
        bars.push({ d, hms: hh * 10000 + mi * 100 + ss, t: Date.UTC(2026, 10, day, hh, mi, ss) / 1000, o, h, l, c, v: 5000 + Math.floor(r() * 40000) });
        px = c;
      }
    };
    mk('20261102', 2, 600); mk('20261103', 3, 1100);
    return bars;
  }
  const mkItem = (params, seed, code) => {
    const bars = synth(seed), P = V1.prep(Object.assign({}, params, { Date: '', TickScope: 120 }));
    const start = bars.findIndex(b => b.d === '20261103');
    return { code: code || ('T' + seed), bars, ind: V1.compute(bars, P), P, ctx: { start, date: '20261103', dayComplete: bars[start].hms <= P._sessMax, limKind: null } };
  };
  const SEEDS = [11, 22, 33], RP0 = R.load({});
  const SETS = [['S000', {}],
    ['R000', { SafeBelow: 'macd_sig', SafeAbove: 'macd_sig', UnsafeBelow: 'macd_sig', UnsafeAbove: 'macd_sig' }],
    ['cross', { ArmMode: 'cross', StopPct: 1, ReentryGap: 3 }],
    ['mix', { SafeNoLoss: 0, UnsafeBelow: 'supertrend', SafeAbove: 'trail' }]];
  let nT = 0, perr = null;
  for (const [nm, ov] of SETS) for (const sd of SEEDS) {
    const x = mkItem(Object.assign({}, S0, ov), sd);
    const a = V1.simulate(x.bars, x.ind, x.P, x.ctx);
    const m = same(a, E3.simulate(x.bars, x.ind, x.P, x.ctx, null)) || same(a, E3.simulate(x.bars, x.ind, x.P, x.ctx, RP0)) || same(a, E3.runPortfolio([x], RP0)[0]);
    nT += a.trades.length;
    if (m && !perr) perr = nm + '/seed' + sd + ': ' + m;
  }
  ok('parity v1==v3 (4 sets x 3 seeds x 3 paths)', !perr, perr);
  ok('synthetic data produces trades', nT > 0, nT);
  const items = SEEDS.map(sd => mkItem(S0, sd));
  { const mae = [];
    for (const x of items) for (const t of E3.simulate(x.bars, x.ind, x.P, x.ctx, RP0).trades) {
      let lo = Infinity; for (let j = t.inI + 1; j <= t.outI; j++) lo = Math.min(lo, x.bars[j].l);
      if (lo < Infinity) mae.push((lo / t.inPx - 1) * 100);
    }
    const worst = mae.length ? Math.min.apply(null, mae) : 0;
    const runHard = pct => { const RP = R.load({ position: { hardStop: { enabled: true, pct: pct } } }); let bad = null, hits = 0;
      for (const x of items) for (const t of E3.simulate(x.bars, x.ind, x.P, x.ctx, RP).trades) {
        if (t.why === 'r_hard') hits++;
        if (t.outPx < t.inPx * (1 - pct / 100) - 1e-9 && t.outPx !== x.bars[t.outI].o) bad = t.why + '@' + t.outI + ' px=' + t.outPx;
      }
      return { bad: bad, hits: hits }; };
    const h1 = runHard(1);
    ok('hard stop 1% caps loss (gap -> open)', !h1.bad, h1.bad);
    const info = 'trades=' + mae.length + ' worstMAE=' + worst.toFixed(3) + '%';
    if (worst <= -1) ok('hard stop triggered', h1.hits > 0, 'pct=1 hits=0 but ' + info + ' -> engine/risk bug');
    else if (worst < -0.02) { const pa = Math.round(-worst * 0.9 * 1000) / 1000, h2 = runHard(pa);
      ok('hard stop triggered', h2.hits > 0 && !h2.bad, 'pct=' + pa + ' hits=' + h2.hits + ' bad=' + h2.bad + ' ' + info); }
    else ok('hard stop triggered', false, 'no adverse excursion in synthetic data: ' + info); }
  { const RP = R.load({ position: { takeProfit: { enabled: true, pct: 1, ratio: 0.5 } } }); let bad = null, np = 0;
    for (const x of items) for (const t of E3.simulate(x.bars, x.ind, x.P, x.ctx, RP).trades) if (t.parts) {
      np++; const q = t.parts[0];
      const exp = (q.frac * (q.px / t.inPx - 1) + (1 - q.frac) * (t.outPx / t.inPx - 1)) * 100 - x.P.FeePct;
      if (Math.abs(exp - t.ret) > 1e-9) bad = exp + ' vs ' + t.ret;
    }
    ok('partial TP blended return', !bad, bad); ok('partial TP triggered', np > 0, np); }
  { const RP = R.load({ account: { noReentrySameDay: { enabled: true } } }); let mx = 0;
    for (const x of items) mx = Math.max(mx, E3.runPortfolio([x], RP)[0].trades.length);
    ok('no reentry same day (<=1 trade)', mx <= 1, mx); }
  { const RP = R.load({ account: { maxDailyEntries: { enabled: true, n: 2 } } }); let mx = 0;
    for (const x of items) mx = Math.max(mx, E3.runPortfolio([x], RP)[0].trades.length);
    ok('max daily entries 2', mx <= 2, mx); }
  { const RP = R.load({ account: { flatten: { enabled: true, time: '130000' } } }); let bad = null;
    for (const x of items) {
      const fi = x.bars.findIndex((b, i) => i >= x.ctx.start && b.hms >= 130000);
      for (const t of E3.simulate(x.bars, x.ind, x.P, x.ctx, RP).trades) {
        if (x.bars[t.inI].hms >= 130000) bad = 'entry ' + x.bars[t.inI].hms;
        if (fi >= 0 && t.outI > fi) bad = 'exit ' + x.bars[t.outI].hms;
      }
    }
    ok('flatten 13:00 (exit + entry block)', !bad, bad); }
  const its = SEEDS.map((sd, k) => mkItem(S0, sd, 'P' + k));
  { const pr = E3.runPortfolio(its, RP0); let m = null;
    its.forEach((x, k) => { m = m || same(V1.simulate(x.bars, x.ind, x.P, x.ctx), pr[k]); });
    ok('portfolio RP000 == independent v1', !m, m); }
  { const pr = E3.runPortfolio(its, R.load({ account: { maxSlots: { enabled: true, n: 1 } } })); const all = [];
    pr.forEach((r, k) => r.trades.forEach(t => all.push({ a: its[k].bars[t.inI].t, b: its[k].bars[t.outI].t })));
    all.sort((p, q) => p.a - q.a); let bad = null;
    for (let j = 1; j < all.length; j++) if (all[j].a < all[j - 1].b) bad = 'overlap at ' + j;
    ok('max slots 1 -> no overlap', !bad, bad); }
  { const pk = E3.runPortfolio(its, null, { topK: 1 }); let rr = 0; pk.forEach(r => { rr += r.rej.r_rank || 0; });
    ok('rank top1 gate active', rr > 0, rr); }
  console.log((fail ? 'SELFTEST FAIL ' : 'SELFTEST OK ') + pass + '/' + (pass + fail) + ' (' + E3.VERSION + ', ' + R.VERSION + ', parity trades=' + nT + ')');
  process.exit(fail ? 1 : 0);
}

// ================================================================ RUN (loaders = sz-lab.cjs)
const L = []; const say = s => L.push(s);
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
  const lst = rows.slice(1).map(r => ({ d: String(r[iD]).replace(/\D/g, '').slice(0, 8), c: Math.abs(num(r[iC])), p: iP >= 0 ? num(r[iP]) : NaN }))
    .filter(x => x.d.length === 8 && x.c > 0).sort((a, b) => a.d < b.d ? -1 : a.d > b.d ? 1 : 0);
  let k = -1; for (let j = 0; j < lst.length; j++) if (lst[j].d < date) k = j;
  if (k < 0) { warn.push('일봉 전일 없음'); return null; }
  let chg = lst[k].p;
  if (!isFinite(chg) && k > 0) chg = (lst[k].c / lst[k - 1].c - 1) * 100;
  return { d: lst[k].d, chg };
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
const pct = x => (x > 0 ? '+' : '') + Number(x).toFixed(2);
const fmtT = h => { const s = String(h).padStart(6, '0'); return s.slice(0, 2) + ':' + s.slice(2, 4) + ':' + s.slice(4); };

const lib = {};
for (const f of fs.readdirSync(FRZ).filter(x => x.endsWith('.json'))) {
  const s = readJson(path.join(FRZ, f));
  if (!man.frozen || man.frozen[s.id] !== sha(JSON.stringify(s.params))) die('frozen strategy modified or unknown: ' + s.id);
  lib[s.id] = Object.assign({ kind: 'frozen' }, s);
}
const B = lib[man.baseline]; if (!B) die('baseline missing: ' + man.baseline);
if (fs.existsSync(SURV)) for (const f of fs.readdirSync(SURV).filter(x => x.endsWith('.json'))) {
  const s = readJson(path.join(SURV, f)); if (!lib[s.id]) lib[s.id] = Object.assign({ kind: 'survivor' }, s);
}
function resolve(id) {
  if (lib[id]) return lib[id];
  const f = path.join(CAND, id + '.json'); if (!fs.existsSync(f)) die('strategy not found: ' + id);
  const c = readJson(f), b = lib[c.base || B.id]; if (!b) die('base not found: ' + c.base);
  const p = Object.assign({}, b.params);
  for (const k of Object.keys(c.overrides || {})) { if (!(k in p)) die('unknown param ' + k + ' in ' + id); p[k] = c.overrides[k]; }
  return { id: c.id, name: c.name, params: p, kind: 'candidate', engine: c.engine || 'v1' };
}
let sids = list(O.Strategies);
if (!sids.length) sids = Object.keys(lib).filter(id => lib[id].kind === 'frozen' || lib[id].status !== 'lapsed').sort();
sids = [B.id].concat(sids.filter(x => x !== B.id));
const strats = sids.map(resolve);
for (const s of strats) if ((s.engine || 'v1') !== 'v1') die(s.id + ': engine ' + s.engine + ' not supported (v3 wraps v1 params)');
const pwant = list(O.Profiles), profs = [];
for (const f of fs.readdirSync(RISK).filter(x => /\.json$/i.test(x)).sort()) {
  const id = f.replace(/\.json$/i, '');
  if (pwant.length && pwant.indexOf(id) < 0 && id !== 'RP000') continue;
  const buf = fs.readFileSync(path.join(RISK, f)), raw = JSON.parse(buf.toString('utf8').replace(/^\uFEFF/, ''));
  const unk = R.unknownKeys(raw); if (unk.length) die(f + ': unknown keys ' + unk.join(','));
  const P = R.load(raw), v = R.validate(P); if (v.length) die(f + ': invalid ' + v.join(','));
  profs.push({ id, name: raw.name || id, P, sha: sha(buf).slice(0, 12) });
}
profs.sort((a, b) => (a.id === 'RP000' ? -1 : b.id === 'RP000' ? 1 : a.id < b.id ? -1 : 1));
const RP0 = profs[0];
if (!RP0 || RP0.id !== 'RP000' || !R.isPassive(RP0.P)) die('RP000 missing or not passive');

const ds = loadDataset(B.params.Match);
if (!ds.items.length) die('no usable tick files');
function mkItems(params) {
  return ds.items.map(it => {
    const P = V1.prep(Object.assign({}, params, { Date: '', TickScope: it.scope }));
    const dayComplete = it.bars[it.start].hms <= P._sessMax;
    let limKind = null;
    if (it.dly && isFinite(it.dly.chg)) { if (it.dly.chg >= P.LimPct) limKind = 'limit'; else if (it.dly.chg >= P.SurgePct) limKind = 'surge'; }
    return { code: it.code, source: '_', bars: it.bars, ind: V1.compute(it.bars, P), P, ctx: { start: it.start, date: it.date, dayComplete, limKind } };
  });
}
const conv = (it, trades) => trades.map(t => ({ in: it.bars[t.inI].hms, inPx: t.inPx, out: it.bars[t.outI].hms, outPx: t.outPx, why: t.why, ret: t.ret, mfe: t.mfe, parts: t.parts ? t.parts.length : 0 }));
const itemsB = mkItems(B.params);
const v1B = itemsB.map(x => V1.simulate(x.bars, x.ind, x.P, x.ctx));
let checked = 0;
ds.items.forEach((it, k) => {
  const r = man.ref && man.ref.files && man.ref.files[it.fp]; if (!r) return; checked++;
  const s = stats(conv(it, v1B[k].trades));
  if (s.n !== r.n || Math.abs(s.sum - r.sum) > 1e-6) die('baseline reproduction mismatch ' + it.f + ': now n=' + s.n + ' sum=' + s.sum.toFixed(4) + ' / ref n=' + r.n + ' sum=' + r.sum.toFixed(4));
});
const modes = [{ id: 'indep', topK: 0, port: false }, { id: 'port', topK: 0, port: true }];
list(O.RankTopK).map(Number).filter(k => k > 0).forEach(k => modes.push({ id: 'port-r' + k, topK: k, port: true }));
const runs = []; let parityN = 0;
for (const s of strats) {
  const items = s.id === B.id ? itemsB : mkItems(s.params);
  const v1r = s.id === B.id ? v1B : items.map(x => V1.simulate(x.bars, x.ind, x.P, x.ctx));
  items.forEach((x, k) => { const m = same(v1r[k], E3.runPortfolio([x], RP0.P)[0]); if (m) die('PARITY ' + s.id + ' ' + ds.items[k].f + ': ' + m); parityN++; });
  for (const p of profs) for (const m of modes) {
    const res = m.port ? E3.runPortfolio(items, p.P, { topK: m.topK, rankBy: O.RankBy }) : items.map(x => E3.runPortfolio([x], p.P)[0]);
    const per = res.map((r, k) => { const tr = conv(ds.items[k], r.trades); return Object.assign({ f: ds.items[k].f }, stats(tr), { trades: tr, rej: r.rej }); });
    const all = [].concat(...per.map(x => x.trades));
    runs.push({ key: s.id + '__' + p.id + '__' + m.id, s, p, m, per, tot: stats(all) });
  }
}
const base = runs.find(r => r.s.id === B.id && r.p.id === 'RP000' && r.m.id === 'indep');
const totMfe = ds.items.reduce((a, it) => a + (it.dm ? Math.max(it.dm.mfe, 0) : 0), 0);
const now = new Date().toISOString(), status = ds.items.length >= O.ConfirmStockDays ? 'alive' : 'provisional';
const rjs = r => { const a = {}; r.per.forEach(p => { for (const k of Object.keys(p.rej)) if (k.indexOf('r_') === 0 && p.rej[k]) a[k] = (a[k] || 0) + p.rej[k]; }); return Object.keys(a).map(k => k.slice(2) + ':' + a[k]).join(' '); };
const rex = r => { const a = {}; r.per.forEach(p => p.trades.forEach(t => { if (t.why.indexOf('r_') === 0) a[t.why] = (a[t.why] || 0) + 1; if (t.parts) a.partial = (a.partial || 0) + 1; })); return Object.keys(a).map(k => k.replace('r_', '') + ':' + a[k]).join(' '); };
for (const r of runs) {
  r.capture = totMfe > 0 ? r.tot.sum / totMfe * 100 : 0;
  if (r === base) { r.verdict = '기준선'; continue; }
  r.j = judge(r.tot, r.per, base.tot, base.per, ds.items.length, O);
  const f = path.join(SURV3, r.key + '.json');
  const chk = { at: now, dataset: ds.id, stockDays: ds.items.length, ok: r.j.ok, n: r.tot.n, sum: +r.tot.sum.toFixed(4), baseSum: +base.tot.sum.toFixed(4), mdd: +r.tot.mdd.toFixed(4), share: +r.j.share.toFixed(3), reasons: r.j.reasons };
  const old = fs.existsSync(f) ? readJson(f) : null;
  if (r.j.ok) {
    const checks = old ? (old.checks || []).filter(x => x.dataset !== ds.id) : []; checks.push(chk);
    writeJson(f, { key: r.key, strategy: r.s.id, profile: r.p.id, profileSha: r.p.sha, mode: r.m.id, engine: 'v3', params: r.s.params, risk: r.p.P, status, checks });
    r.verdict = old ? '생존유지(' + status + ')' : '생존(신규 ' + status + ')';
  } else if (old) {
    old.checks = (old.checks || []).filter(x => x.dataset !== ds.id); old.checks.push(chk); old.status = 'lapsed'; writeJson(f, old);
    r.verdict = '실효(lapsed)';
  } else r.verdict = '탈락';
}
const LED = path.join(SD, 'ledger3.csv');
if (!fs.existsSync(LED)) fs.writeFileSync(LED, '\uFEFFrun_at,dataset,stock_days,strategy,profile,profile_sha,mode,n,win,sum,avg,pf,mdd,capture,share,verdict,reasons\r\n', 'utf8');
fs.appendFileSync(LED, runs.map(r => [now, ds.id, ds.items.length, r.s.id, r.p.id, r.p.sha, r.m.id, r.tot.n, r.tot.w, r.tot.sum.toFixed(3), r.tot.avg.toFixed(3), r.tot.pf.toFixed(2), r.tot.mdd.toFixed(3), r.capture.toFixed(1), r.j ? r.j.share.toFixed(2) : '', r.verdict, r.j ? r.j.reasons.join('/') : ''].join(',')).join('\r\n') + '\r\n', 'utf8');
const sorted = [base].concat(runs.filter(r => r !== base).sort((a, b) => b.tot.sum - a.tot.sum));
const tcsv = ['\uFEFFkey,code,date,no,in,in_px,out,out_px,why,ret,mfe,parts'];
sorted.forEach(r => r.per.forEach((p, k) => p.trades.forEach((t, m) => tcsv.push([r.key, ds.items[k].code, ds.items[k].date, m + 1, fmtT(t.in), t.inPx.toFixed(0), fmtT(t.out), t.outPx.toFixed(0), t.why, t.ret.toFixed(3), t.mfe.toFixed(3), t.parts].join(',')))));
fs.writeFileSync(path.join(OUT, 'trades.csv'), tcsv.join('\r\n'), 'utf8');
const ST = '<style>body{background:#111;color:#ddd;font:13px "Malgun Gothic",sans-serif;margin:10px}table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid #333;padding:3px 8px;text-align:right}th{background:#222}td.l{text-align:left}.up{color:#ff6b6b}.dn{color:#5cc8ff}.sv{color:#7f7;font-weight:bold}.bs{color:#fc3}</style>';
let h = '<!doctype html><html><head><meta charset="utf-8"><title>SafeZone Lab3</title>' + ST + '</head><body><h2>연구소 v3 · 데이터 ' + ds.id + ' · 종목일 ' + ds.items.length + '</h2>';
h += '<div>기준선 ' + B.id + '×RP000×indep (=v1) · 재현 ' + checked + '파일 일치 · v1=v3(RP000) 패리티 ' + parityN + '건 일치</div>';
h += '<table><tr><th>전략</th><th>리스크</th><th>모드</th><th>거래</th><th>승률</th><th>합계%</th><th>PF</th><th>MDD</th><th>포착률%</th><th>우위</th><th>판정</th><th>리스크 거부</th><th>리스크 청산</th><th>사유</th></tr>';
sorted.forEach(r => {
  const t = r.tot, cls = r === base ? 'bs' : (r.verdict.indexOf('생존') === 0 ? 'sv' : '');
  h += '<tr><td class="l ' + cls + '">' + r.s.id + '</td><td class="l">' + r.p.id + '</td><td class="l">' + r.m.id + '</td><td>' + t.n + '</td><td>' + (t.n ? Math.round(t.w / t.n * 100) : 0) + '%</td><td class="' + (t.sum > 0 ? 'up' : 'dn') + '">' + pct(t.sum) + '</td><td>' + t.pf.toFixed(2) + '</td><td>' + t.mdd.toFixed(2) + '</td><td>' + r.capture.toFixed(1) + '</td><td>' + (r.j ? Math.round(r.j.share * 100) + '%' : '-') + '</td><td class="' + cls + '">' + r.verdict + '</td><td class="l">' + rjs(r) + '</td><td class="l">' + rex(r) + '</td><td class="l">' + (r.j ? r.j.reasons.join(', ') : '') + '</td></tr>';
});
h += '</table><h3>종목일별 합계% (상위 12 + 기준선)</h3><table><tr><th>종목</th><th>당일MFE%</th>' + sorted.slice(0, 13).map(r => '<th>' + r.key.replace(/__/g, '<br>') + '</th>').join('') + '</tr>';
ds.items.forEach((it, k) => { h += '<tr><td>' + it.code + '</td><td>' + (it.dm ? pct(it.dm.mfe) : '-') + '</td>' + sorted.slice(0, 13).map(r => { const s = r.per[k].sum; return '<td class="' + (s > 0 ? 'up' : 'dn') + '">' + pct(s) + ' (' + r.per[k].n + ')</td>'; }).join('') + '</tr>'; });
fs.writeFileSync(path.join(OUT, 'index.html'), h + '</table></body></html>', 'utf8');
say('데이터 ' + ds.id + ': 종목일 ' + ds.items.length + ' / 기준선 재현 ' + checked + '파일 일치 / v1=v3(RP000) 패리티 ' + parityN + '건 일치');
say('기준선 ' + B.id + '×RP000×indep: 거래 ' + base.tot.n + ' 합계 ' + pct(base.tot.sum) + '% PF ' + base.tot.pf.toFixed(2) + ' MDD ' + base.tot.mdd.toFixed(2));
say('--- 합계%(거래수), * = 생존 ---');
for (const s of strats) {
  say('[' + s.id + '] ' + (s.name || ''));
  for (const p of profs) say('  ' + (p.id + '      ').slice(0, 6) + ' ' + modes.map(m => { const r = runs.find(x => x.s === s && x.p === p && x.m === m); return m.id + ' ' + pct(r.tot.sum) + '(' + r.tot.n + ')' + (r.verdict.indexOf('생존') === 0 ? '*' : ''); }).join(' | '));
}
say('--- 상위 10 ---');
sorted.slice(1, 11).forEach(r => say(r.key + ' | ' + r.verdict + (r.j && r.j.reasons.length ? ' (' + r.j.reasons.join(', ') + ')' : '') + ' | 거래 ' + r.tot.n + ' 합계 ' + pct(r.tot.sum) + ' PF ' + r.tot.pf.toFixed(2) + ' MDD ' + r.tot.mdd.toFixed(2) + ' | 거부[' + rjs(r) + '] 청산[' + rex(r) + ']'));
const nSurv = runs.filter(r => r.verdict.indexOf('생존') === 0).length;
say('=== 생존 ' + nSurv + ' / 평가 ' + (runs.length - 1) + (status === 'provisional' ? ' (종목일 ' + ds.items.length + '<' + O.ConfirmStockDays + ': 잠정)' : ''));
fs.writeFileSync(path.join(OUT, 'summary.txt'), L.join('\r\n'), 'utf8');
console.log('DONE runs=' + runs.length + ' survivors=' + nSurv + ' parity=' + parityN);
process.exit(0);