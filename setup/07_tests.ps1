. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '07_tests.ps1'
Write-Info '07_tests: 테스트 하네스 / 픽스처 / 지표 테스트 / 러너'

$c = @'
type TestFn = () => void;

const cases: Array<{ name: string; fn: TestFn }> = [];

export class AssertError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AssertError';
  }
}

export function test(name: string, fn: TestFn): void {
  cases.push({ name, fn });
}

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new AssertError(message);
}

export function approx(
  actual: number | null | undefined,
  expected: number,
  message: string,
  eps = 1e-9,
): void {
  if (typeof actual !== 'number' || !Number.isFinite(actual)) {
    throw new AssertError(`${message}: 숫자가 아님 (${String(actual)})`);
  }
  const tol = eps * Math.max(1, Math.abs(expected));
  if (Math.abs(actual - expected) > tol) {
    throw new AssertError(`${message}: 기대 ${expected}, 실제 ${actual}`);
  }
}

/** 두 값을 재귀 비교. 같으면 null, 다르면 첫 차이 경로 문자열 */
export function deepClose(a: unknown, b: unknown, path = '$', eps = 1e-9): string | null {
  if (typeof a === 'number' && typeof b === 'number') {
    if (Number.isNaN(a) && Number.isNaN(b)) return null;
    const tol = eps * Math.max(1, Math.abs(a), Math.abs(b));
    return Math.abs(a - b) <= tol ? null : `${path}: ${a} != ${b}`;
  }
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') {
    return Object.is(a, b) ? null : `${path}: ${String(a)} != ${String(b)}`;
  }
  if (Array.isArray(a) !== Array.isArray(b)) return `${path}: 배열/객체 형태 불일치`;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return `${path}.length: ${a.length} != ${b.length}`;
    for (let i = 0; i < a.length; i++) {
      const d = deepClose(a[i], b[i], `${path}[${i}]`, eps);
      if (d) return d;
    }
    return null;
  }
  const ra = a as Record<string, unknown>;
  const rb = b as Record<string, unknown>;
  const ka = Object.keys(ra).sort();
  const kb = Object.keys(rb).sort();
  if (ka.join(',') !== kb.join(',')) return `${path}: 키 불일치 [${ka.join(',')}] vs [${kb.join(',')}]`;
  for (const k of ka) {
    const d = deepClose(ra[k], rb[k], `${path}.${k}`, eps);
    if (d) return d;
  }
  return null;
}

export function run(title: string): number {
  console.log(`\n=== ${title} ===`);
  let pass = 0;
  const fails: string[] = [];
  for (const c of cases) {
    const t0 = Date.now();
    try {
      c.fn();
      pass++;
      console.log(`  [PASS] ${c.name} (${Date.now() - t0}ms)`);
    } catch (e) {
      fails.push(c.name);
      const msg = e instanceof Error ? e.message : String(e);
      console.log(`  [FAIL] ${c.name}`);
      console.log(`         원인: ${msg}`);
      if (!(e instanceof AssertError) && e instanceof Error && e.stack) {
        console.log(e.stack.split('\n').slice(1, 4).join('\n'));
      }
    }
  }
  console.log(`\nRESULT: ${pass}/${cases.length}`);
  if (fails.length) console.log(`FAILED: ${fails.join(' | ')}`);
  return fails.length;
}
'@
Write-ProjectFile 'tests\harness.ts' $c

$c = @'
import type { Bar, Incremental } from '../src/index.js';
import { deepClose } from './harness.js';

/** 결정론적 난수 (같은 seed → 같은 데이터) */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export interface FixtureOptions {
  days: number;
  barsPerDay: number;
  seed: number;
  startPrice: number;
  baseVolume: number;
}

/** 여러 거래일에 걸친 120틱 유사 봉 생성 (가끔 거래량 급증 포함) */
export function makeBars(o: FixtureOptions): Bar[] {
  const rnd = mulberry32(o.seed);
  const bars: Bar[] = [];
  let price = o.startPrice;
  const day0 = Date.UTC(2026, 9, 29) / 1000;
  for (let d = 0; d < o.days; d++) {
    const dayStart = day0 + d * 86400;
    const tradingDate = new Date(dayStart * 1000).toISOString().slice(0, 10);
    let t = dayStart + 9 * 3600;
    for (let k = 0; k < o.barsPerDay; k++) {
      t += 1 + Math.floor(rnd() * 20);
      const open = price;
      const drift = (rnd() - 0.48) * price * 0.004;
      const close = Math.max(1, Math.round(open + drift));
      const high = Math.max(open, close) + Math.round(rnd() * price * 0.002);
      const low = Math.max(1, Math.min(open, close) - Math.round(rnd() * price * 0.002));
      const spike = rnd() < 0.05 ? 6 : 1;
      const volume = Math.max(1, Math.round(o.baseVolume * (0.2 + rnd() * 2) * spike));
      bars.push({ time: t, tradingDate, open, high, low, close, volume });
      price = close;
    }
  }
  return bars;
}

/** 손으로 만드는 단순 봉 (O=H=L=C) */
export function flatBar(close: number, index: number, date = '2026-11-02', volume = 1000): Bar {
  const base = Date.parse(`${date}T09:00:00Z`) / 1000;
  return { time: base + index * 10, tradingDate: date, open: close, high: close, low: close, close, volume };
}

/** 최종봉 하나를 진행봉 시퀀스로 분해. 마지막 원소 = 최종봉 */
export function partialsOf(final: Bar, steps: number): Bar[] {
  const out: Bar[] = [];
  const n = Math.max(1, Math.trunc(steps));
  for (let k = 1; k <= n; k++) {
    if (k === n) {
      out.push({ ...final });
      break;
    }
    const frac = k / n;
    const close = Math.round(final.open + (final.close - final.open) * frac);
    out.push({
      ...final,
      close,
      high: Math.max(final.open, close),
      low: Math.min(final.open, close),
      volume: Math.max(1, Math.round(final.volume * frac)),
    });
  }
  return out;
}

/**
 * 실시간 재현: seed 봉으로 reset → 이후 봉마다 append(진행봉) + replace 반복.
 * 최종 상태가 전체 reset 결과와 같으면 null.
 */
export function streamParity<S>(
  create: () => Incremental<S>,
  bars: readonly Bar[],
  seedCount: number,
  steps = 4,
): string | null {
  const live = create();
  const cur: Bar[] = bars.slice(0, seedCount);
  live.reset(cur);
  for (let i = seedCount; i < bars.length; i++) {
    const parts = partialsOf(bars[i], steps);
    cur.push(parts[0]);
    live.update(cur, 'append');
    for (let k = 1; k < parts.length; k++) {
      cur[cur.length - 1] = parts[k];
      live.update(cur, 'replace');
    }
  }
  const fresh = create().reset(bars);
  const diff = deepClose(live.values(), fresh);
  return diff === null ? null : `seed=${seedCount}: ${diff}`;
}
'@
Write-ProjectFile 'tests\fixtures.ts' $c

$c = @'
import { test, assert, approx, deepClose } from './harness.js';
import { makeBars, flatBar, streamParity } from './fixtures.js';
import {
  barAmount,
  createBigPrint,
  createDayAmount,
  createMomentum,
  createNmacd,
  type Bar,
  type Incremental,
} from '../src/index.js';

const FIX: Bar[] = makeBars({ days: 3, barsPerDay: 160, seed: 20261102, startPrice: 30000, baseVolume: 2000 });

// ───────── 픽스처 자체 점검 (분기가 실제로 실행되는지) ─────────
test('Fixture: 테스트 데이터가 주요 분기를 모두 포함', () => {
  const bp = createBigPrint().reset(FIX);
  const flags = bp.filter(x => x.flag).length;
  assert(flags > 0 && flags < FIX.length, `1억 신호 분포 이상: ${flags}/${FIX.length}`);
  assert(createDayAmount().reset(FIX).some(x => x.strong), '강세패턴(taamt > 10억) 발생 없음');
  const nm = createNmacd().reset(FIX);
  assert(nm.some(x => x.crossUpZero) && nm.some(x => x.crossDownZero), '강도 0선 교차 없음');
  assert(nm.some(x => x.crossUpSig) && nm.some(x => x.crossDownSig), '강도-시그널 교차 없음');
  const mo = createMomentum().reset(FIX);
  assert(mo.some(x => x.mom !== null && x.mom >= 100), '안심구간(mom>=100) 없음');
  assert(mo.some(x => x.mom !== null && x.mom < 100), '비안심구간(mom<100) 없음');
});

// ───────── Momentum ─────────
test('Momentum: L봉 전까지 null, 이후 C/C[L]*100', () => {
  const bars = [100, 101, 102, 103, 110].map((c, i) => flatBar(c, i));
  const v = createMomentum({ len: 3, slopeLen: 1 }).reset(bars);
  for (let i = 0; i < 3; i++) assert(v[i].mom === null, `mom[${i}] 는 null 이어야 함: ${v[i].mom}`);
  approx(v[3].mom, 103, 'mom[3]');
  approx(v[4].mom, (110 / 101) * 100, 'mom[4]');
  approx(v[4].refPrice, 101, 'refPrice[4]');
  approx(v[4].spanSec, 30, 'spanSec[4]');
  approx(v[4].slope, (110 / 101) * 100 - (103 / 100) * 100, 'slope[4]');
  assert(v[3].slope === null, 'slope[3] 은 null (mom[2] 없음)');
});

test('Momentum: crossSession=false 면 다른 거래일 기준봉은 null', () => {
  const bars = [
    ...[100, 100, 100].map((c, i) => flatBar(c, i, '2026-10-30')),
    ...[105, 106, 108].map((c, i) => flatBar(c, i, '2026-11-02')),
  ];
  const a = createMomentum({ len: 2, crossSession: true }).reset(bars);
  const b = createMomentum({ len: 2, crossSession: false }).reset(bars);
  approx(a[3].mom, 105, 'crossSession=true mom[3]');
  assert(b[3].mom === null && b[4].mom === null, 'crossSession=false 에서 날짜 경계 mom 은 null');
  approx(b[5].mom, (108 / 105) * 100, 'crossSession=false mom[5]');
});

// ───────── 강도 (정규화 MACD) ─────────
function refNmacd(bars: readonly Bar[], p1: number, p2: number, p3: number) {
  const a = (p: number) => 2 / (p + 1);
  let e1 = 0, e2 = 0, sig = 0;
  return bars.map((b, i) => {
    const c = b.close;
    if (i === 0) { e1 = c; e2 = c; sig = 0; return { n: 0, sig: 0 }; }
    e1 = e1 + a(p1) * (c - e1);
    e2 = e2 + a(p2) * (c - e2);
    const n = ((e1 - e2) / c) * 100;
    sig = sig + a(p3) * (n - sig);
    return { n, sig };
  });
}

test('강도: 영웅문 수식 기준구현과 일치 (7,14,5)', () => {
  const v = createNmacd({ p1: 7, p2: 14, p3: 5 }).reset(FIX).map(x => ({ n: x.n, sig: x.sig }));
  const diff = deepClose(v, refNmacd(FIX, 7, 14, 5));
  assert(diff === null, diff ?? '');
});

test('강도: 횡보 후 상승 첫 봉에서 0선 상향돌파', () => {
  const bars = [...Array.from({ length: 20 }, (_, i) => flatBar(100, i)), flatBar(101, 20), flatBar(102, 21)];
  const v = createNmacd().reset(bars);
  const idx = v.map((x, i) => (x.crossUpZero ? i : -1)).filter(i => i >= 0);
  assert(idx.length === 1 && idx[0] === 20, `crossUpZero 위치 기대 [20], 실제 [${idx.join(',')}]`);
  assert(v[20].n > 0, '상승 봉 강도 > 0');
});

test('강도: warmupBars 이후 ready=true', () => {
  const v = createNmacd({ warmupBars: 100 }).reset(FIX);
  assert(v[98].ready === false && v[99].ready === true, `ready 경계 오류: [98]=${v[98].ready}, [99]=${v[99].ready}`);
});

// ───────── 1억 신호 ─────────
test('1억 신호: (O+H+L+C)/4*V 와 비교연산자 경계', () => {
  const b = flatBar(10000, 0, '2026-11-02', 10000); // 정확히 1억
  approx(barAmount(b), 100_000_000, 'barAmount');
  assert(createBigPrint({ inclusive: true }).reset([b])[0].flag === true, 'inclusive=true: 1억 == 기준 → 신호');
  assert(createBigPrint({ inclusive: false }).reset([b])[0].flag === false, 'inclusive=false: 1억 == 기준 → 신호 아님');
});

test('1억 신호: density 가 직접 센 값과 일치', () => {
  const W = 20;
  const v = createBigPrint({ densityWin: W }).reset(FIX);
  for (let i = 0; i < v.length; i++) {
    let cnt = 0;
    for (let j = Math.max(0, i - W + 1); j <= i; j++) if (v[j].flag) cnt++;
    assert(v[i].density === cnt, `density[${i}] 기대 ${cnt}, 실제 ${v[i].density}`);
  }
});

// ───────── 당일 누적거래대금 / 강세패턴 ─────────
test('당일누적: 일자별 누적합과 일치, 날짜 바뀌면 0부터', () => {
  const v = createDayAmount().reset(FIX);
  let run = 0;
  let key = '';
  for (let i = 0; i < FIX.length; i++) {
    const k = String(FIX[i].tradingDate);
    if (k !== key) {
      run = 0;
      key = k;
      assert(v[i].dayBarIndex === 0, `dayBarIndex[${i}] 는 0 이어야 함`);
    }
    run += barAmount(FIX[i]);
    approx(v[i].taamt, run, `taamt[${i}]`);
  }
  assert(v[0].complete === false, '로드 첫날은 complete=false (영웅문 oamt 없음)');
  assert(v[160].complete === true && v[160].dayOrdinal === 1, '둘째 날 complete=true, dayOrdinal=1');
});

test('강세패턴: taamt == a 는 아님, 초과 시 true, 최초 시각 유지', () => {
  const bars = [
    flatBar(10000, 0, '2026-10-30', 1),
    ...[0, 1, 2, 3].map(i => flatBar(10000, i, '2026-11-02', 50000)), // 봉당 5억
  ];
  const v = createDayAmount({ strongA: 1_000_000_000 }).reset(bars);
  approx(v[2].taamt, 1_000_000_000, 'taamt[2]');
  assert(v[2].strong === false, 'taamt == a 이면 강세 아님 (taamt > a)');
  assert(v[3].strong === true, 'taamt 15억 > 10억 → 강세');
  assert(v[3].firstStrongTime === bars[3].time, 'firstStrongTime = 처음 돌파한 봉 시각');
  assert(v[4].firstStrongTime === bars[3].time, 'firstStrongTime 은 당일 유지');
});

test('강세패턴: 로드 첫날은 무효, firstDayComplete=true 면 유효', () => {
  const bars = [0, 1].map(i => flatBar(10000, i, '2026-10-30', 1_000_000));
  const a = createDayAmount().reset(bars);
  assert(a.every(x => !x.complete && !x.strong), '기본값: 첫날 strong=false');
  const b = createDayAmount({ firstDayComplete: true }).reset(bars);
  assert(b[0].strong === true, 'firstDayComplete=true: 첫날도 판정');
});

// ───────── 증분 엔진 공통 ─────────
test('Incremental: 상태 길이 불일치 시 자동 재계산', () => {
  const inc = createBigPrint();
  inc.reset(FIX.slice(0, 10));
  const s = inc.update(FIX.slice(0, 15), 'append');
  const fresh = createBigPrint().reset(FIX.slice(0, 15));
  const d1 = deepClose(inc.values(), fresh);
  assert(d1 === null, d1 ?? '');
  const d2 = deepClose(s, fresh[14]);
  assert(d2 === null, d2 ?? '');
});

test('Incremental: 빈 배열 update 는 null 과 빈 상태', () => {
  const inc = createMomentum();
  inc.reset(FIX.slice(0, 5));
  assert(inc.update([], 'append') === null, 'null 반환');
  assert(inc.values().length === 0, '상태 비움');
});

// ───────── reset / append / replace parity ─────────
function parityTest<S>(label: string, create: () => Incremental<S>): void {
  test(`${label}: reset / append / replace parity`, () => {
    for (const seed of [1, 50, 170]) {
      const err = streamParity(create, FIX, seed, 4);
      assert(err === null, err ?? '');
    }
  });
}

parityTest('Momentum(50)', () => createMomentum());
parityTest('Momentum(50, crossSession=false)', () => createMomentum({ crossSession: false }));
parityTest('강도(7,14,5)', () => createNmacd());
parityTest('1억 신호(>=)', () => createBigPrint());
parityTest('1억 신호(>)', () => createBigPrint({ inclusive: false }));
parityTest('당일 누적거래대금', () => createDayAmount());
'@
Write-ProjectFile 'tests\indicators.test.ts' $c

$c = @'
import './indicators.test.js';
import { run } from './harness.js';

const failed = run('mom-trader 1단계: 지표 4종 검증');
process.exitCode = failed > 0 ? 1 : 0;
'@
Write-ProjectFile 'tests\run.ts' $c

Complete-Step '07_tests'
