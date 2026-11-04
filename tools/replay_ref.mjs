import fs from 'node:fs';
import path from 'node:path';

const [tickDir, outDir, P1, P2, P3, MOM, BIG, STRONG, CPS] = process.argv.slice(2);
const p1 = +P1, p2 = +P2, p3 = +P3, momLen = +MOM, bigTh = +BIG, strongA = +STRONG;
const cps = String(CPS || '').split(',').filter(Boolean).map(s => s.trim().padEnd(6, '0'));
const fmt = (x, d = 4) => (x === null || !Number.isFinite(x)) ? '' : String(Number(x.toFixed(d)));
const hms = t => t ? `${t.slice(0, 2)}:${t.slice(2, 4)}:${t.slice(4, 6)}` : '-';
const pad = (s, w) => String(s).padStart(w);

function ema(values, p) {
  const a = 2 / (p + 1); let e = null;
  return values.map(v => (e = e === null ? v : e + a * (v - e)));
}

function load(file) {
  const lines = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const head = lines[0].split(',');
  const col = k => { const i = head.indexOf(k); if (i < 0) throw new Error(`missing column: ${k}`); return i; };
  const I = {}; for (const k of ['ts', 'date', 'time', 'open', 'high', 'low', 'close', 'volume', 'is_target']) I[k] = col(k);
  return lines.slice(1).map(l => {
    const c = l.split(',');
    return { ts: c[I.ts], date: c[I.date], time: c[I.time], o: +c[I.open], h: +c[I.high], l: +c[I.low],
             c: +c[I.close], v: +c[I.volume], target: c[I.is_target] === '1' };
  });
}

let failed = 0;
for (const f of fs.readdirSync(tickDir).filter(x => x.endsWith('.csv'))) {
  try {
    const bars = load(path.join(tickDir, f));
    const e1 = ema(bars.map(b => b.c), p1), e2 = ema(bars.map(b => b.c), p2);
    const n = bars.map((b, i) => (e1[i] - e2[i]) / b.c * 100);
    const sig = ema(n, p3);
    const rows = ['ts,time,close,mom,n,sig,bar_amount,bigprint,taamt,strong,safe'];
    const cpRows = [];
    let day = null, taamt = 0, tgt = 0, safe = 0, big = 0, bad = 0, cpi = 0;
    let firstStrong = null, firstArm = null, firstEntry = null;
    for (let i = 0; i < bars.length; i++) {
      const b = bars[i];
      if (b.date !== day) { day = b.date; taamt = 0; }
      const amt = (b.o + b.h + b.l + b.c) / 4 * b.v;
      taamt += amt;
      if (!b.target) continue;
      tgt++;
      const mom = i >= momLen ? b.c / bars[i - momLen].c * 100 : null;
      const isSafe = mom !== null && mom >= 100, isBig = amt >= bigTh, strong = taamt > strongA;
      if (isSafe) safe++;
      if (isBig) big++;
      if (strong && !firstStrong) firstStrong = b.time;
      const crossUp = i > 0 && n[i - 1] <= 0 && n[i] > 0;
      if (!firstArm) { if (isSafe && strong && crossUp) firstArm = b.time; }
      else if (!firstEntry && isSafe && isBig) firstEntry = b.time;
      if ((mom !== null && !Number.isFinite(mom)) || !Number.isFinite(n[i]) || !Number.isFinite(sig[i])) bad++;
      rows.push([b.ts, b.time, fmt(b.c, 0), fmt(mom), fmt(n[i], 6), fmt(sig[i], 6), fmt(amt, 0),
                 isBig ? 1 : 0, fmt(taamt, 0), strong ? 1 : 0, isSafe ? 1 : 0].join(','));
      while (cpi < cps.length && b.time >= cps[cpi]) {
        cpRows.push(`     ${cps[cpi].slice(0, 4)} -> ${hms(b.time)} ${pad(fmt(b.c, 0), 8)} ${pad(fmt(mom, 2), 8)} ${pad(fmt(n[i], 4), 9)} ${pad(fmt(sig[i], 4), 9)} ${pad(Math.round(taamt).toLocaleString('en-US'), 16)}`);
        cpi++;
      }
    }
    if (tgt === 0) throw new Error('no target-day bars');
    if (bad > 0) throw new Error(`non-finite values: ${bad}`);
    const out = path.join(outDir, f.replace(/\.csv$/, '_ref.csv'));
    fs.writeFileSync(out, rows.join('\n') + '\n', 'utf8');
    console.log(`[OK] ${f}: bars=${tgt}, safe(mom>=100)=${(safe / tgt * 100).toFixed(1)}%, bigprint=${big}, taamt=${Math.round(taamt).toLocaleString('en-US')}`);
    console.log(`     first strong=${hms(firstStrong)} | preview ARM=${hms(firstArm)} | preview entry=${hms(firstEntry)}`);
    console.log('     check -> bar time    close      mom         n       sig            taamt');
    for (const r of cpRows) console.log(r);
  } catch (e) {
    failed++;
    console.log(`[FAIL] ${f}: ${e.message}`);
  }
}
process.exit(failed ? 1 : 0);