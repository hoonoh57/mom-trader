SafeZone Trader 설계서
조건검색 포착 종목 × 멀티차트 × Momentum 안심구간 자동매매
문서 버전: v1.0 (2026-11-02) 대상 저장소: hoonoh57/kiwoom-desk (main) 성격: kiwoom-desk 표준 Workbench 위에 올리는 응용 Add-on의 구현 설계서

0. 이 문서의 범위와 전제
목표: 조건검색으로 포착된 종목 중 지정한 수만큼 차트를 한 화면에 자동으로 띄웁니다. 각 차트에서 120틱 기준 Momentum(50) 안심구간 로직으로 선별, 진입, 보유, 청산을 동시에 자동 실행합니다.

전제가 된 관찰 (2026-11-02, 5종목, 하루치):

Mom(50) < 100인 종목은 저수익이고 거래대금도 적었습니다.
Mom ≥ 100인 구간에서는 SuperTrend나 MACD 시그널의 작은 매도 신호를 무시하고 보유하면 휩소를 피했습니다.
진입은 Mom ≥ 100, 거래대금 충족, 정규화 MACD 0선 돌파(예비), 1억 신호(확정) 순서로 할 때 약세 종목이 걸러졌습니다.
이 관찰은 아직 검증할 가설입니다. 그래서 이 설계의 모든 임계값과 매도 규칙은 하드코딩하지 않고 파라미터로 받습니다. 10장의 기록 구조로 장기간 검증한 뒤 값을 정합니다.

1. 저장소 분석 결과 (확인한 사실)
1.1 아키텍처 원칙 — 이 설계가 반드시 지킬 경계
저장소 헌법은 상대강도 순위, 거래대금 점수, 합성점수, Top N 자동선별, 진입·청산 판단, 자동매매 정책, MFE/MAE 분석을 기본 src/에서 제외합니다. 이런 기능은 별도 응용 프로젝트나 제거 가능한 addons/ 계층에 두도록 정하고 있습니다 Source. 기본 Workbench는 표준·참고용이고, 전략 수익률을 최적화하는 프로젝트로 바꾸지 않는다는 점도 명시돼 있습니다 Source.

결론: SafeZone Trader는 아래 두 곳에만 둡니다.

Copyaddons/indicators-safezone/   ← 신규 지표 플러그인 (Momentum, 정규화MACD, 1억신호, 누적대금, 시가선)
addons/safezone-trader/       ← 후보풀, 점수화, 멀티차트 오케스트레이터, 전략 플러그인, 리스크가드, 기록기
src/는 수정하지 않습니다. 필요한 경우에도 공개 계약(EventBus, registerChartPlugin, registerStrategyPlugin)만 사용합니다.

1.2 그대로 재사용할 수 있는 자산
자산	위치	재사용 방법
120틱 차트	src/chart/tickAggregation.ts	네이티브 틱 범위 1·3·5·10·30·60·120, 합성 240~720 Source
차트 수명주기	src/chart/extensions.ts	onBarsReset / onBarChanged(bar, 'append'|'replace', bars) Source
전략 플러그인 계약	addons/chart-strategies/types.ts	StrategyPlugin.create(params) → { reset, update }, 파라미터 정의, migrateParams Source
중앙 실행기	addons/chart-strategies/execution.ts	signal/paper/broker 모드, ARM 게이트, in-flight 중복 차단, ka10076 체결확인 Source
이벤트 계약	src/core/events.ts	ConditionHit, RealtimeTick, StrategyTradeIntent, StrategyPortfolioChanged 등 Source
차트별 AUTO/반자동/수동	src/forms/ChartWorkspaceForm.ts	차트별 잠금, 제어모드, 수량 파라미터(params.locked, params.controlMode, params.qty) Source
확정봉 주문 원칙	헌법 16장	진행 중 봉의 replace는 주문하지 않고, append로 직전 봉이 확정된 뒤의 BUY/SELL만 주문 의도가 됨 Source
기존 지표 플러그인은 SMA, EMA, Bollinger, RSI, OBV, MACD, SuperTrend, JMA, DMI/ADX, Disparity, VWAP입니다 Source. Momentum, 정규화 MACD(강도), 1억 신호, 누적거래대금, 시가 배수선은 없습니다. 따라서 이 다섯 가지를 새로 만들어야 합니다.

1.3 성능·효율·안전 측면에서 발견한 점 (개선 필요)
코드를 읽고 판단한 내용입니다. 장중 실측으로 확인해야 하는 항목은 "확인 필요"로 표시했습니다.

#	발견	영향 (N개 차트 동시 운용 시)	이 설계에서의 대응
P1	체결확인 reconcileFill이 주문마다 ka10076을 최대 8회 개별 폴링 (1.2초 후 시작, 이후 2초 간격) Source	동시 주문이 많으면 REST 유량제한(1700 응답) 위험. 8회 안에 체결이 안 되면 PENDING 상태로 방치됨	중앙 FillReconciler: 한 번 조회해 여러 주문을 대조하는 배치 방식. 실시간 주문체결 WS가 있으면 그쪽을 우선 사용
P2	broker 주문유형을 시장가('3') 등 단가 없는 유형으로 강제 정규화	저유동 종목에서 슬리피지	4장 유동성 게이트로 저유동 종목을 사전 차단하고, 슬리피지를 기록해 측정
P3	전략 평가 결과가 매번 전체 신호 배열 스냅샷 (signals: readonly StrategySignal[])	틱마다 차트 수 × 신호 수만큼 복사 (확인 필요)	전략 내부 상태는 증분으로 관리하고 신호 배열은 append만. 화면 표시는 최근 K개로 제한
P4	포지션을 sessionStorage에서 복원하는데, 복원 시점에 실제 잔고와 대조하지 않음	앱이 재시작되면 유령 포지션이나 누락 포지션이 생길 수 있음	시작 시 계좌 잔고와 대조(Reconcile)한 뒤에만 전략 포지션을 활성화
P5	AUTO/반자동/수동 게이트가 StrategyHost의 private 메서드를 prototype에서 교체하는 방식 Source	StrategyHost가 바뀌면 조용히 깨질 수 있음	이 설계는 패치에 의존하지 않고 StrategyTradeIntent 발행 전 자체 게이트를 둠
P6	차트를 하나 열 때마다 이력 데이터를 개별 REST로 조회	N개 차트를 동시에 열면 조회가 폭주	SlotLoader 직렬 큐: 동시 로드 수 제한 + 간격 지연
P7	손절이 확정봉 기준으로만 판단됨	120틱 봉 하나가 길게 이어지는 동안 급락하면 손절이 늦어짐	하드스탑은 RiskGuard가 RealtimeTick 기준 틱 단위로 별도 감시
P8	장중 WS, 재접속, soak, 실제 broker 체결은 미검증 상태 Source	실매매 전 필수 확인 사항	12장 단계별 출시: signal → paper → 모의 broker → 실전 소액

2. 전체 아키텍처
2.1 컴포넌트 구성

┌────────────── kiwoom-desk 표준 (수정 금지) ──────────────┐
│ ConditionForm ─ Topics.ConditionHit / 조건검색 실시간     │
│ ChartForm / ChartWorkspaceForm (120틱, append/replace)    │
│ RealtimeTick(0B) / Strategy* Topics / AccountForm         │
└───────────────────────────┬──────────────────────────────┘
                            │ 공개 계약만 사용
┌─────────────────── addons/safezone-trader ───────────────┐
│ ① CandidatePool      조건 편입/이탈 → 후보 목록, 포착 시각  │
│ ② FeatureEngine      종목별 피처 계산 (지표 calculator 재사용) │
│ ③ Scorer             게이트 판정 + 점수 → 순위             │
│ ④ SlotOrchestrator   N개 슬롯 배정/교체/해제, 레이아웃      │
│ ⑤ SlotLoader         차트 이력 로드 직렬 큐                 │
│ ⑥ SafeZoneStrategy   전략 플러그인 (진입/청산 상태머신)     │
│ ⑦ RiskGuard          틱 단위 하드스탑, 일손실 한도, 장마감 청산 │
│ ⑧ FillReconciler     배치 체결확인                          │
│ ⑨ TradeRecorder      피처 스냅샷, MFE/MAE, 거래 로그 → 서버 DB │
│ ⑩ SafeZoneBoard      관제 UI (슬롯 상태, 점수, 사유)        │
└──────────────────────────────────────────────────────────┘
┌─────────────── addons/indicators-safezone ───────────────┐
│ momentum / nmacd / bigprint(1억) / cumvalue / openlines   │
└──────────────────────────────────────────────────────────┘

2.2 데이터 흐름 (한 종목 기준)

조건 편입(ConditionHit)
  → CandidatePool.add(code, hitTime, hitPrice)
  → SlotLoader 큐 등록 → 120틱 이력 로드 (Mom 계산용 최소 봉 수 확보)
  → FeatureEngine.reset(bars) → 이후 RealtimeTick마다 update
  → Scorer: 게이트 통과 여부 + 점수
  → SlotOrchestrator: 빈 슬롯 또는 교체 대상이 있으면 차트 슬롯 배정
  → 슬롯 차트에 SafeZoneStrategy 인스턴스 부착
  → 확정봉 BUY/SELL → StrategyTradeIntent → 중앙 실행기
  → RiskGuard는 틱마다 하드스탑 감시 → 필요하면 SELL intent
  → TradeRecorder가 전 과정을 기록

핵심 설계 결정 — 피처 계산과 차트 표시를 분리합니다. 화면 슬롯 수(예: 6개)보다 후보가 많아도(예: 20개), 모든 후보의 피처는 FeatureEngine이 차트 없이 계산합니다. 차트는 슬롯에 배정된 종목만 그립니다. 그래야 "아직 화면에 없는 후보가 더 좋아졌을 때 교체"가 가능하고, 렌더링 부하도 슬롯 수로 제한됩니다.

FeatureEngine과 차트 위 전략은 같은 calculator 코드를 import해서 씁니다. 그래서 계산식이 서로 어긋나지 않습니다. 저장소의 전략 작성 원칙에도 검증된 indicator calculator를 재사용하라고 돼 있습니다 Source.

3. 지표 정의 (addons/indicators-safezone)
모든 지표는 기존 MACD·SuperTrend 플러그인과 같은 패턴을 따릅니다. 핵심은 states[] 배열과 함께, append면 push하고 replace면 마지막 원소만 재계산하는 것입니다. 길이가 맞지 않으면 rebuild합니다 Source. append/replace 결과는 같은 데이터로 새로 reset한 결과와 일치해야 하며(parity), 이를 테스트로 고정합니다.

3.1 Momentum (momentum)

Mom[i] = close[i] / close[i - L] × 100          (i ≥ L)
         null                                    (i < L)
파라미터: L (기본 50), crossSession (boolean, 기본 true)

crossSession=false이면 i-L이 다른 거래일(tradingDate)에 속할 때 null을 반환합니다. 120틱은 장중에 50봉이 금방 차지만, 거래가 적은 종목은 이전 날짜의 가격을 참조하게 됩니다. 앞의 분석에서 바로 이 특성이 저유동 종목을 걸러내는 효과로 이어졌습니다. 그래서 기본값은 true(날짜를 넘어 참조) 이고, 검증으로 비교합니다.
함께 계산하는 부가 출력은 이렇습니다.
refPrice[i] = close[i-L] — 안심구간 지지선 가격입니다. 차트에 가격선으로 그릴 수 있습니다.
spanSec[i] = time[i] - time[i-L] — 50봉이 몇 초에 해당하는지로, 종목의 템포를 나타냅니다.
slope[i] = Mom[i] - Mom[i-s] (s 기본 5)
증분 계산: O(1). close 링버퍼는 L+1개만 있으면 됩니다.
3.2 정규화 MACD (nmacd, 차트의 "강도(7,14,5)")
정규화 방식을 확인하지 못했기 때문에 방식 자체를 파라미터로 둡니다.

macd    = EMA(close, fast) − EMA(close, slow)
norm 선택:
  'price' : n = macd / close × 100
  'atr'   : n = macd / ATR(atrLen)
  'zscore': n = (macd − mean(macd, zLen)) / stdev(macd, zLen)
signal  = EMA(n, sig)
hist    = n − signal
파라미터: fast=7, slow=14, sig=5, norm='price', atrLen=14, zLen=100
부가 출력:
  crossUpZero[i]   = n[i-1] ≤ 0 && n[i] > 0
  crossDownZero[i] = n[i-1] ≥ 0 && n[i] < 0
  crossDownSig[i]  = n[i-1] ≥ signal[i-1] && n[i] < signal[i]
  relMax[i]        = n[i] / max(n[i-R..i-1])    (R 기본 300, 자기 이력 대비 강도)

EMA는 기존 MACD 플러그인의 nextState와 같은 방식(첫 봉에서 seed, alpha = 2/(p+1))을 사용합니다.

3.3 1억 신호 (bigprint)

barValue[i] = Σ(체결가 × 체결량) within bar i     (정확값, 1틱 데이터가 있을 때)
            ≈ typical[i] × volume[i]              (근사, typical = (H+L+C)/3)
bigprint[i] = barValue[i] ≥ threshold
파라미터: threshold (기본 100,000,000원), mode ('bar' | 'singleTrade')
부가 출력: density[i] = 최근 W봉 중 bigprint 개수 (W 기본 20)

주의: 원래 정의가 '봉당 체결대금 1억'인지 '단일 체결 1억'인지 확인되지 않았습니다. mode 파라미터로 둘 다 지원합니다. singleTrade는 RealtimeTick(0B)의 체결량 × 체결가로 판정하고, 해당 봉에 플래그를 세웁니다.
120틱 봉은 체결 120건입니다. 따라서 봉당 1억은 평균 체결 금액이 약 83만 원 이상이라는 뜻입니다.

3.4 누적거래대금 (cumvalue)
Copycum[i] = Σ barValue  (같은 tradingDate 안에서, 날짜가 바뀌면 0으로 reset)
부가 출력:
  reached10e[i]   = cum[i] ≥ 1,000,000,000 처음 도달 여부
  velocity[i]     = (cum[i] − cum[i-k]) / (time[i] − time[i-k])   (원/초)
  timeTo10e       = 포착 시각부터 10억 도달까지 걸린 초 (도달 전에는 null)
장 시작 직후 이력 로드가 늦게 끝나면 누적값이 틀립니다. 이를 막기 위해 가능하면 API의 당일 누적거래대금 값으로 보정합니다. 실시간 0B 체결 데이터에 누적거래대금 필드가 있는지는 확인이 필요합니다.

3.5 시가 배수선 (openlines)
CopydayOpen = 해당 tradingDate의 첫 봉 open
lines   = dayOpen × [1.03, 1.097, 1.15]     (배수 목록 파라미터)
level[i] = 현재 close가 돌파한 가장 높은 배수의 인덱스 (0~3)
4. 선별: 게이트 + 점수화 (Scorer)
4.1 2단 구조
1단 게이트(통과/탈락)는 이번 분석의 핵심 발견을 담습니다. 2단 점수는 후보가 슬롯 수보다 많을 때 순위를 매기는 용도로만 씁니다. 점수가 높다는 이유로 게이트를 우회하지는 못합니다.

4.2 게이트 (모두 AND, 각 항목은 on/off와 임계값을 파라미터로)
ID	조건	기본값	근거
G1	Mom ≥ safeTh	100	핵심 발견: 100 미만은 저수익·저대금
G2	cum ≥ minCumValue	10억	누적10억 강세패턴
G3	spanSec ≤ maxSpanSec	1800 (30분)	틱 템포. 50봉이 너무 오래 걸리면 활력이 약함
G4	데이터 충분성: bars ≥ L+1	—	Mom 계산 불가 시 탈락이 아니라 대기 상태
G5	시간대: entryStart ≤ now ≤ entryCutoff	09:00~14:30	장 막판 신호는 먹을 구간이 짧음
4.3 점수 (게이트 통과 종목끼리만 비교)
후보 풀 안에서 백분위로 정규화한 뒤 가중합합니다. 종목 간 스케일 차이를 없애기 위해 절댓값 대신 후보 풀 내 백분위를 씁니다.

Copyscore = Σ w_k × pct_k
  k ∈ {
    velocity    : 누적대금 속도
    density     : 1억 신호 밀도
    relMax      : 강도의 자기 이력 대비 비율
    momLevel    : Mom − 100
    momSlope    : Mom 기울기
    tempo       : 1 / spanSec
  }
기본 가중치: 모두 동일 (1/6)  ← 검증 전 중립값
정직한 경고: 대화에서 확인된 것은 G1의 효과뿐입니다. 점수 항목과 가중치는 근거 없는 초기값입니다. 10장의 기록 데이터로 MFE와의 상관을 확인한 뒤 조정하거나 제거해야 합니다. 거래대금, 1억 신호, 강도는 모두 수급을 재는 지표라 서로 겹친다는 점도 감안해야 합니다.

4.4 출력
Copyinterface CandidateScore {
  code: string;
  gate: 'pass' | 'fail' | 'wait';
  failReasons: string[];   // 예: ['G1:mom=98.7<100', 'G2:cum=3.2e<10e']
  score: number | null;
  rank: number | null;
  features: FeatureSnapshot;   // 10장에서 그대로 기록
  evaluatedAt: number;
}
평가 주기는 해당 종목 봉이 확정될 때마다(append)입니다. 틱마다 하는 replace 시점에는 평가하지 않습니다. 이렇게 해야 CPU 부하가 줄고, 재현성(백테스트와 실시간 결과 일치)이 확보됩니다.

5. 멀티차트 슬롯 관리 (SlotOrchestrator)
5.1 슬롯 상태
CopyEMPTY → LOADING → WATCHING → (전략 내부: GATED/PRE_ARMED/LONG...) → RELEASING → EMPTY
상태	의미
EMPTY	비어 있음
LOADING	SlotLoader 큐에서 이력 로드 중
WATCHING	차트 표시 중. 전략이 진입 신호를 기다림
HOLDING	포지션 보유 (전략이 LONG 상태)
RELEASING	청산 완료 후 쿨다운 대기
5.2 배정·교체 규칙
배정: gate=pass인 후보를 점수 순으로 빈 슬롯에 채웁니다.
교체: 슬롯이 꽉 찼고, 슬롯 종목이 WATCHING 상태이며, 아래 중 하나에 해당하면 교체합니다.
슬롯 종목이 게이트에서 fail로 releaseAfterFailBars봉(기본 10) 연속 머문 경우
대기 중인 후보 점수가 슬롯 최저 점수보다 swapMargin(기본 0.15) 이상 높은 경우
보호: HOLDING, 미체결 주문 보유, RELEASING 쿨다운 중인 슬롯은 절대 교체하지 않습니다. 기존 TradeProtection 계약과 같은 원칙입니다.
조건 이탈: 조건검색에서 이탈해도 보유 중이면 유지합니다. WATCHING 상태면 exitOnConditionDrop 파라미터에 따릅니다.
재진입 쿨다운: 같은 종목을 청산한 뒤 reentryCooldownSec(기본 300초) 동안은 재배정하지 않습니다.
5.3 레이아웃
Copy파라미터: slotCount (1~12), layout ('auto' | '2x2' | '2x3' | '3x3' | '3x4')
auto: slotCount에 따라 cols = ceil(sqrt(n)), rows = ceil(n/cols)
각 슬롯은 ChartWorkspaceForm을 params = { code, name, period:'tick', scope:'120', locked:true, controlMode, qty }로 생성합니다. locked=true는 필수입니다. 외부 종목 선택 이벤트가 자동매매 중인 차트의 종목을 바꾸지 못하게 막아야 하기 때문입니다. ChartWorkspaceForm의 기본값도 userLocked=true입니다 Source. Dockview 그리드 배치는 DockService의 공개 API로 합니다. 패널 키는 중앙 registry가 정한다는 원칙을 지킵니다.

5.4 SlotLoader (P6 대응)
CopymaxConcurrentLoads = 2
loadGapMs          = 350
우선순위: 점수 높은 순. 동점이면 포착 시각이 빠른 순
실패 처리: 지수 백오프 3회 후 포기 → 후보에 'load_failed' 표시
6. 진입 로직 (SafeZoneStrategy — 진입 상태머신)
6.1 상태
CopyIDLE ──(게이트 G1~G3 충족)──▶ GATED
GATED ──(nmacd.crossUpZero)──▶ PRE_ARMED          [ARM 마커]
PRE_ARMED ──(bigprint 발생 & 게이트 유지)──▶ BUY → LONG   [BUY 마커]
PRE_ARMED ──(Mom<safeTh | nmacd<0 | 대기 armExpiryBars 초과)──▶ GATED 또는 IDLE  [FAIL 마커]
GATED ──(게이트 이탈)──▶ IDLE
6.2 판정 의사코드 (확정봉 i에서만 실행)
Copyfunction onBarFinalized(i: number): Signal | null {
  const g = gatePass(i);                        // G1~G3, G5
  switch (state) {
    case 'IDLE':
      if (g) state = 'GATED';
      return null;

    case 'GATED':
      if (!g) { state = 'IDLE'; return null; }
      if (nmacd.crossUpZero[i] || (p.allowAlreadyAbove && nmacd.n[i] > 0 && nmacd.n[i-1] <= 0)) {
        state = 'PRE_ARMED'; armedAt = i;
        return { type: 'arm', reason: `nmacd 0선 돌파 n=${nmacd.n[i]}` };
      }
      return null;

    case 'PRE_ARMED':
      if (!g || nmacd.n[i] < 0) {
        state = g ? 'GATED' : 'IDLE';
        return { type: 'fail', reason: !g ? 'gate 이탈' : 'nmacd<0' };
      }
      if (p.armExpiryBars > 0 && i - armedAt > p.armExpiryBars) {
        state = 'GATED';
        return { type: 'fail', reason: 'ARM 만료' };
      }
      if (bigprint.flag[i]) {
        state = 'LONG'; entry = { bar: i, price: close[i], peak: close[i] };
        return { type: 'buy', reason: `1억신호 mom=${mom[i]} nmacd=${nmacd.n[i]}` };
      }
      return null;
  }
}
Copy
설계 포인트:

BUY 판정은 확정봉에서만 하고, 다음 봉이 append될 때 중앙 실행기로 넘어갑니다. 기존 프레임워크가 이미 이렇게 동작합니다.
1억 신호는 기존 차트처럼 하락 중에도 발생합니다. 원익홀딩스 14:00~14:45 사례가 그랬습니다. 그래서 PRE_ARMED 단계에서 G1(Mom 게이트)을 반드시 다시 확인합니다.
armExpiryBars=0은 만료 없음을 뜻합니다.
7. 청산 로직 (SafeZoneStrategy — 보유 상태머신)
7.1 두 축 네 상태
보유 중에는 매 확정봉마다 두 가지를 판정합니다.

safe = Mom[i] ≥ safeTh. 이탈 판정은 safeConfirmBars봉 연속 미만일 때만 인정합니다.
reached = 최고 수익률(peak 기준) ≥ targetPct. 한 번 도달하면 이후 계속 true로 고정합니다.
상태	조건	적용할 매도 규칙 (파라미터)
S1	safe & !reached	exitSafeBelow
S2	safe & reached	exitSafeAbove
S3	!safe & reached	exitUnsafeAbove
S4	!safe & !reached	exitUnsafeBelow
7.2 매도 규칙 카탈로그
각 상태 파라미터에는 아래 규칙 id 중 하나를 지정합니다.

규칙 id	매도 조건
hold	매도 신호 없음 (다른 상태로 바뀌거나 하드스탑에 걸릴 때까지 보유)
immediate	이 상태에 들어오는 즉시 매도
nmacd_sig	정규화 MACD 시그널 하향돌파 (가장 위험이 적은 매도)
nmacd_zero	정규화 MACD 0선 하향돌파 (안심구간 버팀목)
supertrend	SuperTrend 하락반전 (파라미터: atrPeriod, multiplier)
trail_pct	peak 대비 x% 하락 (trailPct)
mom_div	가격은 신고가인데 Mom은 직전 Mom 고점 미달 (다이버전스)
ref_break	종가가 refPrice(C[i-L]) 아래로 내려감 = Mom 100 이탈과 동일
대화에서 정리한 로직을 기본 프리셋으로 넣습니다.

Copy{
  "exitSafeBelow":  "nmacd_zero",
  "exitSafeAbove":  "hold",
  "exitUnsafeAbove":"nmacd_sig",
  "exitUnsafeBelow":"nmacd_sig"
}
S2의 hold는 안심구간 동안 목표 이상의 수익을 끝까지 챙기는 동작입니다. S3와 S4에서 immediate와 nmacd_sig 중 무엇을 쓸지는 백테스트로 고르는 파라미터입니다. 하드코딩하지 않습니다.

7.3 상태와 무관한 상위 규칙 (우선순위 순)
하드스탑: 진입가 대비 hardStopPct(기본 -3%). RiskGuard가 틱 단위로 감시합니다(P7).
장마감 청산: flattenTime(기본 15:15) 이후에는 전량 청산 intent를 냅니다.
시간 손절 (선택): 진입 후 timeStopSec 안에 수익률이 timeStopMinPct에 못 미치면 청산합니다. 0이면 사용하지 않습니다.
그다음 7.1의 상태별 규칙을 적용합니다.
7.4 보유 판정 의사코드
Copyfunction onBarFinalizedLong(i: number): Signal | null {
  pos.peak = Math.max(pos.peak, high[i]);
  const ret   = close[i] / pos.entry - 1;
  const peakR = pos.peak / pos.entry - 1;
  if (peakR * 100 >= p.targetPct) pos.reached = true;

  belowCount = mom[i] < p.safeTh ? belowCount + 1 : 0;
  const safe = belowCount < p.safeConfirmBars;

  if (p.flattenTime && timeOf(i) >= p.flattenTime) return sell('장마감 청산');
  if (p.timeStopSec && elapsed(i) >= p.timeStopSec && ret*100 < p.timeStopMinPct)
    return sell('시간 손절');

  const rule = safe
    ? (pos.reached ? p.exitSafeAbove   : p.exitSafeBelow)
    : (pos.reached ? p.exitUnsafeAbove : p.exitUnsafeBelow);

  if (evalRule(rule, i)) {
    return sell(`${safe?'safe':'unsafe'}/${pos.reached?'reached':'below'}:${rule}`);
  }
  return null;
}
매도 사유 문자열에 상태와 규칙을 함께 남깁니다. 나중에 SQL로 "어느 상태의 어떤 규칙이 손실을 만드는지" 바로 집계하기 위해서입니다.

7.5 재진입
SELL 이후에는 상태를 GATED(게이트 충족 시) 또는 IDLE로 되돌립니다. 같은 종목 재진입은 reentryCooldownBars(기본 0)와 하루 최대 진입 횟수 maxEntriesPerDay(기본 3)로 제한합니다.

8. 리스크 관리와 실행
8.1 RiskGuard (계좌 수준)
파라미터	기본값	동작
maxPositions	slotCount	동시 보유 종목 수 상한
capitalPerTrade	계좌 평가액 × 10%	수량 = floor(배정금액 / 현재가)
dailyLossLimitPct	-3% (계좌 기준)	도달하면 신규 진입 전면 중단 + 관제판 경고
maxConsecutiveLosses	4	연속 손절 시 cooldownAfterLossesSec 동안 신규 진입 중단
hardStopPct	-3%	틱 단위 감시 (0B 현재가 기준)
수량 계산을 전략 바깥에 두는 이유: 기존 실행 계약의 qty는 전략 instance에 고정돼 있습니다. 하지만 종목 가격이 제각각이라 금액 기준 배분이 필요합니다. SafeZone Trader는 intent를 발행하기 직전에 수량을 계산해 채웁니다.

8.2 실행 경로
CopySafeZoneStrategy (확정봉 BUY/SELL)
  → [게이트] SlotOrchestrator.controlMode (auto/semi/manual)
  → [게이트] RiskGuard.allow(intent)  (일손실, 연속손절, 동시보유, 중복)
  → bus.emit(Topics.StrategyTradeIntent, intent)
  → 기존 StrategyExecutionRuntime (paper/broker, ARM 게이트 유지)
broker ARM 계약은 그대로 유지합니다. 앱 시작 시 항상 LOCKED이고, 현재 세션에서 사용자가 명시적으로 확인해야만 주문이 나갑니다 Source.
FillReconciler (P1): PENDING 주문이 하나라도 있으면 ka10076을 reconcileIntervalMs(기본 2000ms)마다 한 번만 조회해 모든 대기 주문의 주문번호와 대조합니다. 대기 주문이 없으면 조회를 멈춥니다. 1700 유량제한 응답을 받으면 간격을 2배로 늘립니다(최대 10초). 기존 reconcileFill은 대체 대상이며, 실행기 수정이 필요하면 add-on 내부 확장으로 처리합니다.
시작 시 대조 (P4): 앱이 시작되면 계좌 잔고와 미체결을 먼저 조회하고, sessionStorage의 전략 포지션과 대조합니다. 결과가 다르면 해당 슬롯을 RECONCILE_REQUIRED로 표시하고 자동매매를 막습니다.
9. 파라미터 스키마 (JSON 전체)
전략 plugin의 parameters 정의와 별도 설정 JSON 두 곳에 저장합니다. 저장소 계약대로 계산 결과는 저장하지 않고 설정만 저장합니다 Source.

Copy{
  "schemaVersion": 1,
  "chart":    { "tickScope": 120 },
  "momentum": { "len": 50, "crossSession": true, "slopeLen": 5 },
  "nmacd":    { "fast": 7, "slow": 14, "sig": 5, "norm": "price", "atrLen": 14, "zLen": 100, "relMaxLen": 300 },
  "bigprint": { "threshold": 100000000, "mode": "bar", "densityWin": 20 },
  "cumvalue": { "velocityBars": 20 },
  "openlines":{ "multipliers": [1.03, 1.097, 1.15] },

  "gate": {
    "safeTh": 100, "minCumValue": 1000000000, "maxSpanSec": 1800,
    "entryStart": "09:00", "entryCutoff": "14:30",
    "enable": { "G1": true, "G2": true, "G3": true, "G5": true }
  },
  "score": {
    "weights": { "velocity": 1, "density": 1, "relMax": 1, "momLevel": 1, "momSlope": 1, "tempo": 1 }
  },
  "slots": {
    "slotCount": 6, "layout": "auto", "controlMode": "manual",
    "swapMargin": 0.15, "releaseAfterFailBars": 10,
    "exitOnConditionDrop": false, "reentryCooldownSec": 300,
    "maxConcurrentLoads": 2, "loadGapMs": 350
  },
  "entry": { "armExpiryBars": 0, "allowAlreadyAbove": false, "maxEntriesPerDay": 3 },
  "exit": {
    "targetPct": 5, "safeConfirmBars": 1,
    "exitSafeBelow": "nmacd_zero", "exitSafeAbove": "hold",
    "exitUnsafeAbove": "nmacd_sig", "exitUnsafeBelow": "nmacd_sig",
    "trailPct": 2.0, "supertrend": { "atrPeriod": 14, "multiplier": 1.5 },
    "timeStopSec": 0, "timeStopMinPct": 1.0, "flattenTime": "15:15"
  },
  "risk": {
    "capitalPerTradePct": 10, "hardStopPct": -3, "dailyLossLimitPct": -3,
    "maxConsecutiveLosses": 4, "cooldownAfterLossesSec": 1800
  },
  "execution": { "mode": "signal", "exchange": "KRX", "orderType": "3" }
}
Copy
controlMode 기본값은 manual, execution.mode 기본값은 signal입니다. 안전 기본값이므로, 처음 설치했을 때는 주문이 나가지 않습니다.

10. 기록과 검증 (TradeRecorder)
이 시스템의 성패는 가설 검증 데이터에 달려 있습니다. 매매한 종목뿐 아니라 포착된 모든 후보를 기록합니다. 그래야 "걸러낸 종목이 정말 나빴는지"를 확인할 수 있습니다.

10.1 저장 위치
브라우저 저장소가 아니라 기존 server/의 로컬 서버로 보내 SQLite나 PostgreSQL에 저장합니다. 전송은 배치로 하고(flushIntervalMs 5000), 서버가 꺼져 있어도 매매는 멈추지 않습니다. 실패한 기록은 큐에 보관했다가 다시 보냅니다.

10.2 테이블
Copy-- 포착 후보 (매매 여부와 무관하게 전부)
CREATE TABLE candidate (
  id            INTEGER PRIMARY KEY,
  trade_date    DATE, code TEXT, name TEXT,
  hit_time      TIMESTAMP, hit_price REAL, condition_name TEXT,
  slotted       BOOLEAN, traded BOOLEAN,
  mfe_pct       REAL,   -- 포착가 대비 장마감까지 최고 수익률
  mae_pct       REAL,   -- 포착가 대비 최대 역행
  mfe_time      TIMESTAMP, close_ret_pct REAL
);

-- 피처 스냅샷 (포착 시점, +5분, +10분, +30분, 진입 시점, 청산 시점)
CREATE TABLE feature_snapshot (
  candidate_id  INTEGER REFERENCES candidate(id),
  tag           TEXT,      -- 'hit' | 't+5m' | 't+10m' | 't+30m' | 'entry' | 'exit'
  ts            TIMESTAMP, price REAL,
  mom REAL, mom_slope REAL, ref_price REAL, span_sec REAL,
  nmacd REAL, nmacd_sig REAL, nmacd_relmax REAL,
  cum_value REAL, velocity REAL, bigprint_density INTEGER,
  open_level INTEGER, gate TEXT, fail_reasons TEXT, score REAL, rank INTEGER
);

-- 매매 내역
CREATE TABLE trade (
  id            INTEGER PRIMARY KEY,
  candidate_id  INTEGER REFERENCES candidate(id),
  mode          TEXT, params_hash TEXT,
  entry_time    TIMESTAMP, entry_ref REAL, entry_fill REAL,
  exit_time     TIMESTAMP, exit_ref REAL, exit_fill REAL,
  qty INTEGER, ret_pct REAL,
  mfe_pct REAL, mae_pct REAL,          -- 보유 중 최고/최저
  exit_state TEXT,                      -- S1~S4
  exit_rule  TEXT,                      -- hold/nmacd_zero/... 또는 hardstop/flatten/timestop
  safe_ratio REAL,                      -- 보유 기간 중 Mom≥100 봉 비율
  slippage_bp REAL
);
Copy
params_hash는 설정 JSON의 해시입니다. 파라미터를 바꾼 전후 성과를 섞지 않기 위해 둡니다.

10.3 핵심 검증 쿼리
Copy-- Q1. Mom 게이트의 선별력: 포착 시점 Mom≥100 여부별 MFE 분포
SELECT (f.mom >= 100) AS safe, COUNT(*) n,
       AVG(c.mfe_pct) avg_mfe,
       AVG(CASE WHEN c.mfe_pct >= 10 THEN 1.0 ELSE 0 END) p_mfe10,
       AVG(CASE WHEN c.mfe_pct <= 5  THEN 1.0 ELSE 0 END) p_mfe5
FROM candidate c JOIN feature_snapshot f ON f.candidate_id=c.id AND f.tag='t+5m'
GROUP BY safe;

-- Q2. 청산 상태/규칙별 손익 (어느 규칙이 계좌를 깎는가)
SELECT exit_state, exit_rule, COUNT(*) n, AVG(ret_pct) avg_ret,
       MIN(ret_pct) worst, AVG(mfe_pct - ret_pct) giveback
FROM trade GROUP BY exit_state, exit_rule ORDER BY avg_ret;

-- Q3. 갭 효과 분리: 장 시작 후 50봉 이내 진입 vs 이후
-- Q4. 진입 시각대별 성과 (entryCutoff 결정용)
-- Q5. 점수 항목별 MFE 상관 (가중치 결정용)
10.4 파라미터 탐색 원칙
그리드 탐색 결과에서는 최고 성과 하나보다 주변 값에서도 성과가 고르게 나오는 넓은 영역을 고릅니다. 예를 들어 momLen을 30·40·50·60·80, safeTh를 99·99.5·100·100.5로 바꿔도 성과가 유지되는지 봅니다.
학습 기간과 검증 기간을 나눕니다(walk-forward). 예: 2개월로 학습하고 다음 1개월로 검증합니다.
시장 국면별로 나눠 집계합니다. 지수가 크게 오른 날과 내린 날의 성과를 따로 봅니다.
11. 관제 UI (SafeZoneBoard)
AutoTradeForm은 주문을 직접 소유하지 않는 관제판으로 유지합니다. SafeZoneBoard는 add-on 패널로 따로 둡니다.

영역	표시 내용
상단	전체 controlMode, broker ARM 상태, 오늘 손익, 일손실 한도까지 남은 여유, 신규 진입 차단 여부
후보 표	종목, 포착 시각, gate(통과/탈락/대기), 탈락 사유, 점수, 순위, Mom, 누적대금, spanSec
슬롯 표	슬롯 번호, 종목, 전략 상태(IDLE/GATED/PRE_ARMED/LONG), 안심구간 여부, 목표 도달 여부, 수익률, peak 수익률
이벤트 로그	ARM, BUY, SELL, FAIL, 교체, 리스크 차단 사유 (최근 200건)
각 슬롯 차트에는 Mom pane(100선 표시), refPrice 가격선, 시가 배수선, 1억 신호 점, 안심구간 배경색(Mom ≥ 100 구간 음영)을 표시합니다.

12. 구현 순서와 완료 기준
단계	작업	완료 기준
1	지표 5종 플러그인	reset/append/replace parity 테스트 통과. 영웅문 차트 값과 샘플 대조
2	FeatureEngine + Scorer	과거 데이터를 재생했을 때 실시간 결과와 동일 (결정론적)
3	SafeZoneStrategy (signal 모드)	11/02 원익·라온·SGA·HC보광·리파인 데이터로 ARM/BUY/SELL 마커가 대화에서 분석한 위치와 일치
4	TradeRecorder + 서버 DB	하루 동안 모든 후보와 스냅샷이 누락 없이 저장됨
5	SlotOrchestrator + SlotLoader	후보 20개, 슬롯 6개 조건에서 유량제한 응답 0건, 교체 규칙 동작
6	2~4주 signal 모드 운영	Q1~Q5 쿼리로 가설 검증. 여기서 실패하면 단계 7로 가지 않음
7	paper 모드	2주 이상, 슬리피지 가정을 포함한 성과 확인
8	RiskGuard + FillReconciler + 시작 시 대조	모의투자에서 부분체결, 재접속, 앱 재시작 시나리오 통과
9	모의 broker	모의투자는 KRX 주문만 사용 Source
10	실전 소액	슬롯 1~2개, 최소 수량으로 시작
테스트로 고정할 항목
지표 parity (append·replace 연속 적용 결과와 새 reset 결과가 같음)
진입 상태머신의 모든 전이 (특히 Mom < 100일 때 1억 신호가 나와도 BUY가 없음)
청산 4상태 × 규칙 카탈로그 조합
하드스탑이 확정봉을 기다리지 않고 틱에서 발동함
HOLDING 슬롯은 교체되지 않음
broker LOCKED 상태에서는 어떤 경로로도 주문이 나가지 않음
src/ 파일 변경 0건 (기존 test:audit 경계 유지)
13. 남은 확인 사항
설계를 확정하려면 아래 다섯 가지를 확인해야 합니다. 모두 파라미터로 열어두었기 때문에 구현을 시작하는 데는 지장이 없습니다.

1억 신호의 정확한 정의 (봉당 체결대금인지, 단일 체결인지)
정규화 MACD(강도)의 정규화 방식
"누적10억이상 강세패턴" 지표의 세부 조건
실시간 0B 데이터에 당일 누적거래대금 필드가 있는지
조건검색 실시간 편입 이벤트가 Topics.ConditionHit로 발행되는지, 페이로드 형식은 무엇인지 (ConditionForm 소스 확인 필요)
이 문서는 전략 설계와 구현 방법을 다룬 것이고, 투자 조언이 아닙니다. 실제 자금을 운용하기 전에는 12장의 단계별 검증을 거치시길 권합니다.

다음 작업으로는 1단계(지표 5종)를 저장소의 기존 플러그인 형식에 맞춘 TypeScript 코드와 parity 테스트로 바로 작성해 드릴 수 있습니다.

SafeZone Trader 설계서 v1.1
변경 요약
항목	v1.0	v1.1
1억 신호	봉당 또는 단일 체결 중 선택	봉당 거래대금 = (O+H+L+C)/4 × V ≥ 1억
정규화 MACD	정규화 방식 3가지 중 선택	(EMA(C,P1) − EMA(C,P2)) / C × 100 하나로 확정
누적거래대금	API 보정 포함	영웅문 수식을 그대로 옮긴 당일 누적합. API 값은 대조용으로만 사용
강세패턴	미정	당일 누적거래대금 > a
후보 포착	조건 실시간 편입 이벤트	지정 시각 T에 일반검색 1회 → 후보 고정
3.2 정규화 MACD (교체)
영웅문 수식과 코드 대응
Copy영웅문:  강도       = (eavg(C,P1) - eavg(C,P2)) / C * 100
        강도시그널 = eavg(강도, P3)
기본값:  P1=7, P2=14, P3=5   (차트 표기 "강도(7,14,5)")
Copyinterface NmacdState { e1: number; e2: number; n: number; sig: number; }
const alpha = (p: number) => 2 / (p + 1);

function nextNmacd(c: number, prev: NmacdState | null, P1: number, P2: number, P3: number): NmacdState {
  if (!prev) return { e1: c, e2: c, n: 0, sig: 0 };     // seed: 첫 종가
  const e1  = prev.e1 + alpha(P1) * (c - prev.e1);
  const e2  = prev.e2 + alpha(P2) * (c - prev.e2);
  const n   = (e1 - e2) / c * 100;                      // 분모는 EMA가 아니라 "현재 종가"
  const sig = prev.sig + alpha(P3) * (n - prev.sig);
  return { e1, e2, n, sig };
}
구현 규칙
분모는 당일 종가가 아니라 그 봉의 현재 종가 C입니다. 그래서 replace(진행 중인 봉 갱신)가 들어오면 분자와 분모가 함께 바뀝니다. 마지막 봉은 states[i-1]에서 다시 계산합니다. 기존 MACD 플러그인의 증분 패턴과 같습니다.
워밍업은 100봉이면 충분합니다. EMA 초기값 오차는 봉마다 (1−α)씩 줄어듭니다. P2=14이면 α=2/15이고, 100봉 뒤 남는 오차는 약 6×10⁻⁷ 배입니다. 영웅문 eavg의 초기값 처리 방식을 몰라도, 100봉 이후 값은 영웅문과 일치해야 합니다. 이걸 대조 테스트 기준으로 씁니다.
출력: n, sig, crossUpZero, crossDownZero, crossDownSig, crossUpSig
매매 규칙과 연결:
ARM 예비신호 = crossUpZero
가장 위험이 적은 매도 = crossDownSig (규칙 id nmacd_sig)
안심구간 버팀목 = crossDownZero (규칙 id nmacd_zero)
차트의 분홍 영역 기준선(0.2~0.3 부근)은 표시 전용 파라미터 hiLine으로만 둡니다. 매매 판정에는 쓰지 않습니다.
v1.0의 norm(atr/zscore) 옵션은 삭제합니다. relMax(자기 이력 대비 비율)는 점수 항목용 파생값으로 남깁니다.
3.3 1억 신호 (교체)
CopybarAmt[i]   = (O[i] + H[i] + L[i] + C[i]) / 4 × V[i]
bigprint[i] = barAmt[i] ≥ threshold          (threshold 기본 100,000,000)
density[i]  = 최근 W봉 중 bigprint 개수         (W 기본 20, 점수용)
대표가격을 누적거래대금과 같은 (O+H+L+C)/4로 통일합니다. 그래야 1억 신호와 강세패턴이 같은 기준의 거래대금을 씁니다.
120틱 봉에서 V는 체결 120건의 거래량 합계입니다. 진행 중인 봉은 V가 계속 늘어나므로, 봉 확정 전에 1억을 넘을 수 있습니다. 판정은 확정봉에서만 합니다. 6장 진입 상태머신과 같은 원칙입니다.
singleTrade 모드는 삭제합니다.
확인 필요: 영웅문 신호식이 ≥인지 >인지. 비교 연산자 하나 차이지만, 대조 테스트를 정확히 하려면 맞춰야 합니다.
3.4 누적거래대금과 강세패턴 (교체)
영웅문 수식과 의미
Copyamt   = sum((C+O+H+L)/4 * V)                       → 로드된 전체 봉의 누적합
oamt  = valuewhen(1, date != date(1), amt(1))      → 날짜가 바뀐 첫 봉에서 본 직전 봉의 amt
                                                      = 전일까지의 누적합
taamt = amt - oamt                                 → 당일 누적거래대금
강세패턴 = taamt > a                                → a 기본 1,000,000,000 (10억)
결국 거래일마다 0부터 다시 쌓는 누적합과 같습니다. 전체 누적합을 들고 다니면 숫자가 커지고 replace 처리가 복잡해집니다. 그래서 일자별 누적합으로 구현합니다. 결과는 같습니다.

증분 구현
Copy// taamt[i]: 당일 누적, dayKey = bar.tradingDate
reset(bars):
  run = 0; prevKey = null
  for i in bars:
    if (key(i) !== prevKey) { run = 0; prevKey = key(i); }
    run += barAmt(i); taamt[i] = run

append(bar):   // 새 봉
  base = (key(last-1) === key(last)) ? taamt[last-1] : 0
  taamt[last] = base + barAmt(last)

replace(bar):  // 진행 중인 봉 갱신 — append와 같은 식으로 마지막 원소만 다시 계산
  taamt[last] = base + barAmt(last)

strong[i] = taamt[i] > a
reachedAt = strong가 처음 true가 된 봉의 시각 (velocity, timeTo10e 계산에 사용)
데이터 완전성 규칙 (중요)
당일 첫 봉부터 로드돼 있어야 taamt가 맞습니다. 영웅문에서도 로드 범위의 첫 날짜는 oamt가 없어서 값이 정상이 아닙니다.
구현에서는 날짜별로 그 날의 첫 봉이 장 시작 봉인지 확인합니다. 아니면 partial=true로 표시하고, 그 날의 taamt는 판정에 쓰지 않습니다.
포착 시각 T가 장 초반(예: 09:00)이면 당일 봉이 적어 로드 부담이 거의 없습니다. 반면 장중에 앱을 재시작하면 연속조회로 당일 처음부터 다시 받아야 합니다. 이 경우 SlotLoader가 loadUntilSessionStart=true로 처리합니다.
실시간 0B의 누적거래대금 필드(필드 번호와 단위 확인 필요)는 대조용으로만 씁니다. 실제 체결대금과 (OHLC/4×V) 근사값은 다르기 때문입니다. 임계값 a는 영웅문 수식 기준으로 정한 값이라 대체하면 안 됩니다. 두 값의 차이가 maxAmtDeviationPct(기본 20%)를 넘으면 데이터 누락 경고를 냅니다.
시장 범위 (NXT) 주의
보내주신 차트에는 10/30 16:00~19:30 봉이 있습니다. 즉 차트는 NXT 시간외를 포함한 통합 시세로 보입니다. 반면 성과검증 화면은 KRX 시세로 검색했습니다. 통합 차트를 쓰면 taamt에 NXT 프리마켓(08:00~) 거래대금이 들어가고, Mom(50)의 50봉 전 기준가도 시간외 봉이 될 수 있습니다. 지금까지 관찰은 "검색은 KRX, 지표는 통합 차트" 조합에서 나왔습니다. 그래서 이 조합을 기본값으로 재현하고, 범위를 파라미터로 분리합니다.

Copy"marketScope": { "search": "KRX", "chart": "AL" }
5. 후보 포착과 슬롯 관리 (구조 변경)
5.0 포착 방식: 지정 시각 스냅샷
CopysearchTimes = ["09:00"]   (여러 개 지정 가능)
매 T마다:
  1. 조건식 conditionName으로 '일반검색' 1회 실행 (실시간 등록 아님)
  2. 결과 종목마다 searchPrice = T 시점 현재가 기록
  3. CandidatePool에 추가 (이미 있으면 유지, 처음 들어온 T만 기록)
  4. 후보는 candidateTTL(기본 7시간 = 성과검증 수익률기간) 동안 풀에 남음
성과검증(1516)은 영웅문 HTS 기능이라 REST로는 호출할 수 없습니다. 그래서 실시간 시스템은 T 시점에 kiwoom-desk에 이미 구현된 일반검색 경로로 직접 검색합니다. 별도 개발이 필요한 건 T 시각 스케줄러뿐입니다.
기준가는 searchPrice로 통일합니다. 그러면 시스템이 계산한 MFE가 성과검증의 "기간 내 최고수익률"과 같은 정의가 되어, 두 화면 결과를 직접 비교할 수 있습니다.
게이트 평가는 T에서 한 번으로 끝내지 않고 T 이후 계속합니다. SGA솔루션즈처럼 오후에 Mom이 다시 오르며 진입 조건이 생기는 종목이 있기 때문입니다. 포착은 한 번, 판정은 TTL 동안 확정봉마다 합니다.
5.0.1 실시간 검색과 성과검증 결과가 다를 수 있음
T=09:00에 실제로 실행한 일반검색과, 성과검증의 "분단위 검증"으로 다시 계산한 결과는 다를 수 있습니다. 검색이 실행된 초 단위 시점과 1분봉 확정 시점이 다르기 때문입니다. 그래서 후보마다 출처를 기록합니다.

source	의미
live	시스템이 T에 일반검색으로 얻은 종목
1516	장 마감 후 성과검증 화면 목록을 가져온 종목
both	둘 다에 있음
두 목록이 계속 다르다면, 성과검증으로 검증한 조건식 성과가 실시간에서는 재현되지 않는다는 뜻입니다. 전략 검증 전에 이 차이부터 확인해야 합니다.

5.0.2 성과검증 목록 가져오기 (백테스트·리플레이용)
과거 날짜의 후보를 REST로 다시 만들 수는 없습니다. 그래서 성과검증 화면 결과를 CSV로 넣는 경로를 둡니다.

CopyCSV 형식: trade_date, search_time, code, name, search_price, screen_mfe_pct(선택), screen_ret_pct(선택)
→ candidate 테이블에 source='1516'으로 저장
→ 리플레이 엔진이 저장된 틱봉으로 FeatureEngine, SafeZoneStrategy를 재생
→ 시스템 MFE와 screen_mfe를 비교 (차이가 크면 데이터 누락 경고)
틱 이력은 매일 직접 저장해야 합니다. REST 틱차트로 받을 수 있는 과거 기간은 제한적일 수 있으므로(확인 필요), 후보 종목의 30틱 원본봉을 매일 장 마감 후 DB에 저장합니다. 이게 쌓여야 120틱 등 다른 틱 단위와 파라미터로 리플레이할 수 있습니다. 저장소는 이미 30틱 원본으로 240~720틱을 합성하는 구조라 30틱 저장이면 충분합니다.

CopyCREATE TABLE tick30_bar (
  trade_date DATE, code TEXT, market_scope TEXT,   -- 'KRX' | 'AL'
  ts TIMESTAMP, o REAL, h REAL, l REAL, c REAL, v INTEGER,
  PRIMARY KEY (code, market_scope, ts)
);
5.1 바뀐 슬롯 동작
후보가 T마다 한꺼번에 들어오고 그날은 고정됩니다(11/02 기준 14종목). 실시간 편입이 없어 v1.0보다 단순합니다.
slotCount ≥ 후보 수이면 전 종목을 차트에 띄우고, 교체는 일어나지 않습니다.
slotCount < 후보 수이면 v1.0 5.2의 게이트, 점수, 교체 규칙을 그대로 씁니다. 차트에 없는 후보도 FeatureEngine이 계속 계산하므로, 오후에 살아나는 종목으로 교체할 수 있습니다.
T 시점 로드가 몰리는 문제: 후보 N개의 이력을 한꺼번에 받아야 합니다. 워밍업에 필요한 최소 봉 수는 아래와 같습니다.
CopyminBars = max(Mom.L + 1, nmacd 워밍업 100) = 100봉 (120틱 기준)
당일 봉만으로 부족하면 전일 봉까지 받습니다(crossSession). SlotLoader 설정(동시 2건, 간격 350ms)이면 14종목 기준 대략 10~20초로 예상됩니다. 이 시간 동안 해당 종목은 gate='wait'이고 진입하지 않습니다.
9. 파라미터 스키마 변경분
Copy{
  "capture": {
    "conditionName": "5%_일중",
    "searchTimes": ["09:00"],
    "candidateTTL": "7h",
    "marketScope": { "search": "KRX", "chart": "AL" }
  },
  "nmacd":    { "P1": 7, "P2": 14, "P3": 5, "warmupBars": 100, "hiLine": 0.2, "relMaxLen": 300 },
  "bigprint": { "threshold": 100000000, "densityWin": 20 },
  "cumvalue": { "strongA": 1000000000, "maxAmtDeviationPct": 20, "loadUntilSessionStart": true },
  "gate":     { "minCumValue": "→ cumvalue.strongA 참조로 통합" }
}
삭제된 키: nmacd.norm, nmacd.atrLen, nmacd.zLen, bigprint.mode, slots.exitOnConditionDrop(실시간 이탈이 없어졌기 때문)

10. 기록 테이블 변경분
CopyALTER TABLE candidate ADD COLUMN search_time TIMESTAMP;
ALTER TABLE candidate ADD COLUMN search_price REAL;      -- MFE/MAE 기준가
ALTER TABLE candidate ADD COLUMN source TEXT;            -- 'live' | '1516' | 'both'
ALTER TABLE candidate ADD COLUMN screen_mfe_pct REAL;    -- 성과검증 화면 값
-- hit_time, hit_price는 search_time, search_price로 대체
검증 쿼리 Q0을 추가합니다. 다른 분석보다 먼저 실행합니다.

Copy-- Q0. 실시간 검색과 성과검증 목록이 얼마나 일치하는가
SELECT trade_date,
       SUM(source='both')  AS both_n,
       SUM(source='live')  AS live_only,
       SUM(source='1516')  AS screen_only
FROM candidate GROUP BY trade_date;
13. 남은 확인 사항 (갱신)
해결된 것: 1억 정의, 강도 공식, 강세패턴, 누적거래대금, 포착 방식

새로 남은 것 (모두 파라미터로 열려 있어 구현을 막지는 않습니다):

영웅문 1억 신호식의 비교 연산자(≥인지 >인지)
영웅문 차트가 실제로 통합(AL) 시세인지 (시간외 봉으로 보아 통합으로 추정)
REST 틱차트로 받을 수 있는 과거 기간 (틱 DB 저장 필요성 판단용)
실시간 0B의 누적거래대금 필드 번호와 단위 (대조용)
성과검증 결과를 파일로 내보낼 수 있는지, 아니면 수동 입력이 필요한지
