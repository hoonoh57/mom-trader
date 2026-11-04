# mom-trader

kiwoom-desk(표준 Workbench)의 파생 프로젝트.
조건검색 포착 종목을 멀티차트로 띄우고 120틱 Momentum(50) 안심구간 로직으로 자동매매한다.

## 단계
- [x] 1단계: 지표 4종 + reset/append/replace parity 테스트
  - Momentum(L) = C / C[L] × 100 (refPrice, spanSec, slope)
  - 강도 = (EMA(C,P1) − EMA(C,P2)) / C × 100, 강도시그널 = EMA(강도, P3)
  - 1억 신호 = (O+H+L+C)/4 × V ≥ 1억 (봉당)
  - 당일 누적거래대금 taamt, 강세패턴 = taamt > a
- [ ] 2단계: FeatureEngine + Scorer
- [ ] 3단계: SafeZoneStrategy (signal)
- [ ] 이후: 기록기, 슬롯 오케스트레이터, paper, broker

## 명령
- npm test         : 빌드 + 테스트
- npm run typecheck: 타입 검사
- setup\08_verify.ps1 : 전체 검증 (인코딩/파일/타입/테스트)

## 인코딩 규칙
- 소스(.ts/.json/.md): UTF-8 (BOM 없음), LF
- setup\*.ps1: UTF-8 with BOM, CRLF (Windows PowerShell 5.1 한글 호환)
