. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '03_momentum.ps1'
Write-Info '03_momentum: Momentum(L) 지표'

$c = @'
import type { Bar } from '../core/types.js';
import { Incremental } from '../core/incremental.js';
import { dayKey, timeToSec } from '../core/session.js';
import { boolParam, intParam } from '../core/params.js';

/**
 * Momentum(L) = C / C[L] × 100   (120틱 기준 L=50)
 * - mom ≥ 100 : 안심구간 (현재가 > L봉 전 가격)
 * - refPrice  : 안심구간 지지선 = C[L]
 * - spanSec   : L봉이 덮는 시간(초) = 종목 템포
 * - slope     : mom − mom[slopeLen]
 */
export interface MomentumParams {
  len: number;
  /** false 면 기준봉이 다른 거래일일 때 null */
  crossSession: boolean;
  slopeLen: number;
}

export const MOMENTUM_DEFAULTS: Readonly<MomentumParams> = {
  len: 50,
  crossSession: true,
  slopeLen: 5,
};

export interface MomentumPoint {
  mom: number | null;
  refPrice: number | null;
  spanSec: number | null;
  slope: number | null;
}

export function normalizeMomentumParams(raw: Partial<MomentumParams> = {}): MomentumParams {
  return {
    len: intParam(raw.len, MOMENTUM_DEFAULTS.len, 1, 100000),
    crossSession: boolParam(raw.crossSession, MOMENTUM_DEFAULTS.crossSession),
    slopeLen: intParam(raw.slopeLen, MOMENTUM_DEFAULTS.slopeLen, 1, 100000),
  };
}

function momentumAt(bars: readonly Bar[], i: number, p: MomentumParams): number | null {
  if (i < p.len) return null;
  const ref = bars[i - p.len];
  const cur = bars[i];
  if (!(ref.close > 0)) return null;
  if (!p.crossSession && dayKey(ref) !== dayKey(cur)) return null;
  return (cur.close / ref.close) * 100;
}

export function createMomentum(raw: Partial<MomentumParams> = {}): Incremental<MomentumPoint> {
  const p = normalizeMomentumParams(raw);
  return new Incremental<MomentumPoint>((bars, i) => {
    const mom = momentumAt(bars, i, p);
    if (mom === null) return { mom: null, refPrice: null, spanSec: null, slope: null };

    const ref = bars[i - p.len];
    const now = timeToSec(bars[i].time);
    const then = timeToSec(ref.time);
    const prevMom = i - p.slopeLen >= 0 ? momentumAt(bars, i - p.slopeLen, p) : null;

    return {
      mom,
      refPrice: ref.close,
      spanSec: now !== null && then !== null ? now - then : null,
      slope: prevMom !== null ? mom - prevMom : null,
    };
  });
}
'@
Write-ProjectFile 'src\indicators\momentum.ts' $c

Complete-Step '03_momentum'
