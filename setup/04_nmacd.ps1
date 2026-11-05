. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '04_nmacd.ps1'
Write-Info '04_nmacd: 강도 / 강도시그널'

$c = @'
import { Incremental } from '../core/incremental.js';
import { intParam } from '../core/params.js';

/**
 * 영웅문 수식
 *   강도       = (eavg(C,P1) - eavg(C,P2)) / C * 100
 *   강도시그널 = eavg(강도, P3)
 * 분모는 그 봉의 현재 종가 C. EMA seed = 첫 종가, alpha = 2/(P+1).
 * 초기값 차이는 warmupBars(기본 100) 이후 무시 가능 → ready 플래그로 표시.
 */
export interface NmacdParams {
  p1: number;
  p2: number;
  p3: number;
  warmupBars: number;
}

export const NMACD_DEFAULTS: Readonly<NmacdParams> = { p1: 7, p2: 14, p3: 5, warmupBars: 100 };

export interface NmacdPoint {
  e1: number;
  e2: number;
  /** 강도 */
  n: number;
  /** 강도시그널 */
  sig: number;
  hist: number;
  count: number;
  ready: boolean;
  crossUpZero: boolean;
  crossDownZero: boolean;
  crossUpSig: boolean;
  crossDownSig: boolean;
}

export function normalizeNmacdParams(raw: Partial<NmacdParams> = {}): NmacdParams {
  return {
    p1: intParam(raw.p1, NMACD_DEFAULTS.p1, 1, 10000),
    p2: intParam(raw.p2, NMACD_DEFAULTS.p2, 1, 10000),
    p3: intParam(raw.p3, NMACD_DEFAULTS.p3, 1, 10000),
    warmupBars: intParam(raw.warmupBars, NMACD_DEFAULTS.warmupBars, 1, 100000),
  };
}

export function createNmacd(raw: Partial<NmacdParams> = {}): Incremental<NmacdPoint> {
  const p = normalizeNmacdParams(raw);
  const a1 = 2 / (p.p1 + 1);
  const a2 = 2 / (p.p2 + 1);
  const a3 = 2 / (p.p3 + 1);

  return new Incremental<NmacdPoint>((bars, i, prev) => {
    const c = bars[i].close;
    if (prev === null) {
      return {
        e1: c, e2: c, n: 0, sig: 0, hist: 0,
        count: 1, ready: p.warmupBars <= 1,
        crossUpZero: false, crossDownZero: false, crossUpSig: false, crossDownSig: false,
      };
    }
    const e1 = prev.e1 + a1 * (c - prev.e1);
    const e2 = prev.e2 + a2 * (c - prev.e2);
    const n = c > 0 ? ((e1 - e2) / c) * 100 : prev.n;
    const sig = prev.sig + a3 * (n - prev.sig);
    const count = prev.count + 1;
    return {
      e1, e2, n, sig,
      hist: n - sig,
      count,
      ready: count >= p.warmupBars,
      crossUpZero: prev.n <= 0 && n > 0,
      crossDownZero: prev.n >= 0 && n < 0,
      crossUpSig: prev.n <= prev.sig && n > sig,
      crossDownSig: prev.n >= prev.sig && n < sig,
    };
  });
}
'@
Write-ProjectFile 'src\indicators\nmacd.ts' $c

Complete-Step '04_nmacd'
