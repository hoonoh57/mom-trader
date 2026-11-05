. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '05_bigprint.ps1'
Write-Info '05_bigprint: 1억 신호 (봉당 거래대금)'

$c = @'
import type { Bar } from '../core/types.js';
import { Incremental } from '../core/incremental.js';
import { barAmount } from '../core/amount.js';
import { boolParam, intParam, numParam } from '../core/params.js';

/**
 * 1억 신호: 봉당 거래대금 (O+H+L+C)/4 × V 가 threshold 이상.
 * inclusive=true 면 >=, false 면 > (영웅문 신호식 비교연산자에 맞춘다).
 * density: 최근 densityWin 봉 중 신호 개수 (점수화용).
 * 판정은 확정봉 기준으로 사용할 것 (진행봉은 V가 계속 증가).
 */
export interface BigPrintParams {
  threshold: number;
  inclusive: boolean;
  densityWin: number;
}

export const BIGPRINT_DEFAULTS: Readonly<BigPrintParams> = {
  threshold: 100_000_000,
  inclusive: true,
  densityWin: 20,
};

export interface BigPrintPoint {
  amount: number;
  flag: boolean;
  density: number;
}

export function normalizeBigPrintParams(raw: Partial<BigPrintParams> = {}): BigPrintParams {
  return {
    threshold: numParam(raw.threshold, BIGPRINT_DEFAULTS.threshold, 0),
    inclusive: boolParam(raw.inclusive, BIGPRINT_DEFAULTS.inclusive),
    densityWin: intParam(raw.densityWin, BIGPRINT_DEFAULTS.densityWin, 1, 100000),
  };
}

export function isBigPrint(bar: Bar, p: BigPrintParams): boolean {
  const a = barAmount(bar);
  return p.inclusive ? a >= p.threshold : a > p.threshold;
}

export function createBigPrint(raw: Partial<BigPrintParams> = {}): Incremental<BigPrintPoint> {
  const p = normalizeBigPrintParams(raw);
  return new Incremental<BigPrintPoint>((bars, i, prev) => {
    const amount = barAmount(bars[i]);
    const flag = p.inclusive ? amount >= p.threshold : amount > p.threshold;
    const enter = flag ? 1 : 0;
    const leave = i - p.densityWin >= 0 && isBigPrint(bars[i - p.densityWin], p) ? 1 : 0;
    const density = prev === null ? enter : prev.density + enter - leave;
    return { amount, flag, density };
  });
}
'@
Write-ProjectFile 'src\indicators\bigprint.ts' $c

Complete-Step '05_bigprint'
