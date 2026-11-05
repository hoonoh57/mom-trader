. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '02_core.ps1'
Write-Info '02_core: 공통 타입/증분 엔진/세션/거래대금/파라미터'

$c = @'
/**
 * kiwoom-desk 의 OhlcvBar 와 구조적으로 호환되는 봉 타입.
 * time: 초 단위 timestamp(number) 또는 문자열.
 * tradingDate: 거래 세션 날짜(YYYY-MM-DD). 있으면 일자 구분에 우선 사용.
 */
export interface Bar {
  time: number | string;
  tradingDate?: string;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

/** append: 새 봉 추가, replace: 진행 중인 마지막 봉 갱신 */
export type BarChange = 'append' | 'replace';
'@
Write-ProjectFile 'src\core\types.ts' $c

$c = @'
import type { Bar, BarChange } from './types.js';

/**
 * 1차 점화식 지표의 한 스텝.
 * i 번째 봉의 상태를 (전체 봉 배열, i, 직전 상태)만으로 계산해야 한다.
 * 그래야 reset / append / replace 결과가 항상 같다(parity).
 */
export type StepFn<S> = (bars: readonly Bar[], i: number, prev: S | null) => S;

export class Incremental<S> {
  private states: S[] = [];

  constructor(private readonly step: StepFn<S>) {}

  /** 전체 재계산 */
  reset(bars: readonly Bar[]): readonly S[] {
    const next: S[] = [];
    for (let i = 0; i < bars.length; i++) {
      next.push(this.step(bars, i, i > 0 ? next[i - 1] : null));
    }
    this.states = next;
    return this.states;
  }

  /**
   * 증분 갱신. bars 는 변경이 반영된 전체 배열.
   * 내부 상태 길이가 기대와 다르면 안전하게 전체 재계산한다.
   */
  update(bars: readonly Bar[], change: BarChange): S | null {
    if (bars.length === 0) {
      this.states = [];
      return null;
    }
    const i = bars.length - 1;
    const expected = change === 'append' ? bars.length - 1 : bars.length;
    if (this.states.length !== expected) {
      this.reset(bars);
      return this.states[i] ?? null;
    }
    const s = this.step(bars, i, i > 0 ? this.states[i - 1] : null);
    if (change === 'append') this.states.push(s);
    else this.states[i] = s;
    return s;
  }

  values(): readonly S[] {
    return this.states;
  }

  last(): S | null {
    return this.states.length ? this.states[this.states.length - 1] : null;
  }
}
'@
Write-ProjectFile 'src\core\incremental.ts' $c

$c = @'
import type { Bar } from './types.js';

/** 거래일 키. kiwoom-desk tickAggregation.sessionKey 와 같은 규칙. */
export function dayKey(bar: Bar): string {
  const explicit = String(bar.tradingDate ?? '').trim();
  if (explicit) return explicit;
  const t = bar.time;
  if (typeof t === 'number' && Number.isFinite(t)) {
    return new Date(Math.trunc(t) * 1000).toISOString().slice(0, 10);
  }
  return String(t ?? '').slice(0, 10);
}

/** time → 초. 변환 불가면 null */
export function timeToSec(t: Bar['time']): number | null {
  if (typeof t === 'number') return Number.isFinite(t) ? t : null;
  const ms = Date.parse(t);
  return Number.isFinite(ms) ? ms / 1000 : null;
}
'@
Write-ProjectFile 'src\core\session.ts' $c

$c = @'
import type { Bar } from './types.js';

/**
 * 봉 거래대금. 영웅문 수식 (C+O+H+L)/4*V 와 동일.
 * 1억 신호와 당일 누적거래대금이 같은 기준을 쓰도록 이 함수 하나만 사용한다.
 */
export function barAmount(bar: Bar): number {
  return ((bar.close + bar.open + bar.high + bar.low) / 4) * bar.volume;
}
'@
Write-ProjectFile 'src\core\amount.ts' $c

$c = @'
/** 파라미터 정규화: 잘못된 값은 기본값, 범위 밖은 경계값으로 보정한다. */
export function intParam(
  value: unknown,
  fallback: number,
  min: number,
  max: number = Number.MAX_SAFE_INTEGER,
): number {
  if (value === undefined || value === null || value === '') return fallback;
  const n = Math.trunc(Number(value));
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

export function numParam(
  value: unknown,
  fallback: number,
  min: number = -Infinity,
  max: number = Infinity,
): number {
  if (value === undefined || value === null || value === '') return fallback;
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

export function boolParam(value: unknown, fallback: boolean): boolean {
  if (typeof value === 'boolean') return value;
  if (value === 'true' || value === 1 || value === '1') return true;
  if (value === 'false' || value === 0 || value === '0') return false;
  return fallback;
}
'@
Write-ProjectFile 'src\core\params.ts' $c

Complete-Step '02_core'
