. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '06_dayamount.ps1'
Write-Info '06_dayamount: 당일 누적거래대금 / 강세패턴 + index'

$c = @'
import { Incremental } from '../core/incremental.js';
import { barAmount } from '../core/amount.js';
import { dayKey } from '../core/session.js';
import { boolParam, numParam } from '../core/params.js';

/**
 * 영웅문 수식
 *   amt   = sum((C+O+H+L)/4*V)
 *   oamt  = valuewhen(1, date != date(1), amt(1))
 *   taamt = amt - oamt            → 당일 누적거래대금
 *   강세패턴 = taamt > a
 * 일자별 누적합으로 구현(결과 동일).
 * 영웅문은 로드 범위 첫 날짜에 oamt 가 없어 값이 무효 → complete=false.
 * 첫날이 장 시작부터 로드됐다고 보장되면 firstDayComplete=true.
 */
export interface DayAmountParams {
  strongA: number;
  firstDayComplete: boolean;
}

export const DAYAMOUNT_DEFAULTS: Readonly<DayAmountParams> = {
  strongA: 1_000_000_000,
  firstDayComplete: false,
};

export interface DayAmountPoint {
  barAmount: number;
  taamt: number;
  strong: boolean;
  firstStrongTime: number | string | null;
  dayKey: string;
  dayOrdinal: number;
  dayBarIndex: number;
  complete: boolean;
}

export function normalizeDayAmountParams(raw: Partial<DayAmountParams> = {}): DayAmountParams {
  return {
    strongA: numParam(raw.strongA, DAYAMOUNT_DEFAULTS.strongA, 0),
    firstDayComplete: boolParam(raw.firstDayComplete, DAYAMOUNT_DEFAULTS.firstDayComplete),
  };
}

export function createDayAmount(raw: Partial<DayAmountParams> = {}): Incremental<DayAmountPoint> {
  const p = normalizeDayAmountParams(raw);
  return new Incremental<DayAmountPoint>((bars, i, prev) => {
    const bar = bars[i];
    const key = dayKey(bar);
    const amount = barAmount(bar);

    if (prev !== null && prev.dayKey === key) {
      const taamt = prev.taamt + amount;
      const strong = prev.complete && taamt > p.strongA;
      return {
        barAmount: amount,
        taamt,
        strong,
        firstStrongTime: prev.firstStrongTime ?? (strong ? bar.time : null),
        dayKey: key,
        dayOrdinal: prev.dayOrdinal,
        dayBarIndex: prev.dayBarIndex + 1,
        complete: prev.complete,
      };
    }

    const dayOrdinal = prev === null ? 0 : prev.dayOrdinal + 1;
    const complete = dayOrdinal > 0 || p.firstDayComplete;
    const strong = complete && amount > p.strongA;
    return {
      barAmount: amount,
      taamt: amount,
      strong,
      firstStrongTime: strong ? bar.time : null,
      dayKey: key,
      dayOrdinal,
      dayBarIndex: 0,
      complete,
    };
  });
}
'@
Write-ProjectFile 'src\indicators\dayAmount.ts' $c

$c = @'
export type { Bar, BarChange } from './core/types.js';
export { Incremental, type StepFn } from './core/incremental.js';
export { dayKey, timeToSec } from './core/session.js';
export { barAmount } from './core/amount.js';
export { intParam, numParam, boolParam } from './core/params.js';
export * from './indicators/momentum.js';
export * from './indicators/nmacd.js';
export * from './indicators/bigprint.js';
export * from './indicators/dayAmount.js';
'@
Write-ProjectFile 'src\index.ts' $c

Complete-Step '06_dayamount'
