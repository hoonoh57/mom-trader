# 세션 인계 (HANDOFF) - 새 세션은 이 파일부터 읽는다

## 1. 읽는 순서
1. research/CHARTER.md - 목표와 판정 원칙 (GOAL-1 잃지 않는다, GOAL-2 그것을 잊지 않는다)
2. research/LEDGER.md - 합의(D), 결과(R), 미해결 단서(C)
3. research/STAGES.md - 완료 단계, 현재 단계, 다음 게이트
4. PUB_INDEX.txt - 파일 목록, 크기, 줄 수, sha256 앞 12자리

## 2. 원문 읽는 방법
- 공개 미러: https://github.com/hoonoh57/mom-trader (rea 저장소와 별개, 읽기 전용 용도)
- 원문 주소: https://raw.githubusercontent.com/hoonoh57/mom-trader/<커밋SHA>/<경로>
- 커밋 SHA는 FOR_OPUS.txt의 HEAD= 줄. 브랜치명 대신 SHA로 읽는다.
- 박제 엔진 해시는 strategies/manifest.json 과 PUB_INDEX.txt로 대조한다.
- data, logs, out 폴더는 올라가지 않는다. 실행 결과는 FOR_OPUS.txt로 받는다.

## 3. 작업 방식
- Opus가 PowerShell 블록을 주면 사용자가 실행하고 out/FOR_OPUS.txt만 첨부한다.
- 블록은 & { ... } 하나로 감싸 콘솔 붙여넣기에서 끊기지 않게 한다.
- 스크립트 코드는 ASCII 우선, 한글 문서는 UTF-8 무BOM으로 쓴다.
- 작업 후 setup/41_pub.ps1 -Push 로 동기화한다 (허용목록 복사, 비밀값 검사, 커밋, push).
- 자료를 확인하기 전에는 코딩하지 않는다. 사실 확인이 끝난 단계는 바로 코딩한다.
- 박제 엔진(v1, risk1, v3)은 수정하지 않는다. 바꿀 때는 새 버전을 만들고 manifest에 등록한다.

## 4. 로컬 경로
- 루트: E:\parent\projects\rea\projects\mom-trader
- 공개 미러 작업 폴더: E:\parent\projects\mom-trader-pub
- 키 파일: E:\parent\security\.env (절대 공개 금지)
- 틱 아카이브: data\rest\ , 조건식 포착 CSV: data\screen\five_percent.csv
- 인간검증 차트: out\charts\ , 인간 라벨: out\human\review.csv
