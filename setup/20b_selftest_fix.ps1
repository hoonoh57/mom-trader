#requires -Version 5.1
param([string]$Root = 'E:\parent\projects\rea\projects\mom-trader')
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "[성공] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[실패] $m" -ForegroundColor Red }
$enc = New-Object System.Text.UTF8Encoding($false)

Write-Host '=== 자가검증 파일 복구 + 테스트 재삽입 ==='

# 1) 리스크 모듈 수정 상태 확인 (20a 결과)
$mod = [IO.File]::ReadAllText((Join-Path $Root 'tools\sz-risk.cjs'), $enc)
$nb = [regex]::Matches($mod, 'v\.base').Count
if (-not $mod.Contains("'risk-1.1'") -or $nb -ne 4) { Fail "sz-risk.cjs 수정 상태 이상 (risk-1.1=$($mod.Contains("'risk-1.1'")), v.base=$nb). 20a_risk_fix.ps1 먼저 실행"; exit 1 }
Ok "sz-risk.cjs 상태 정상 (risk-1.1, v.base $nb 곳)"

# 2) 백업에서 복구
$st  = Join-Path $Root 'tools\sz-risk-selftest.cjs'
$bak = "$st.bak20a"
if (-not (Test-Path $bak)) { Fail "백업 없음: $bak"; exit 1 }
$t = [IO.File]::ReadAllText($bak, $enc)
$anchor = "t('daily loss flatten', () => {"
$n = [regex]::Matches($t, [regex]::Escape($anchor)).Count
if ($n -ne 1) { Fail "백업 파일 기준 문자열 $n 개 (1개여야 함)"; exit 1 }
if ($t.Contains('daily loss baseline at day roll')) { Fail '백업 파일이 이미 수정본임 - 20_risk.ps1 재실행 후 20a 다시 실행 필요'; exit 1 }

# 3) 새 테스트를 앵커 앞에 삽입 (괄호로 우선순위 명시)
$newTest = @'
t('daily loss baseline at day roll', () => {
  const A = R.createAccount(PA({ dailyLoss: { enabled: true, pct: 2, action: 'block' } }));
  A.onEntry(Object.assign(Q('A'), { w: 0.5 })); A.mark('A', -5);
  eq(A.canEnter(Q('B', 's', 36000, '20261103')).ok, true, 'roll');
  near(A.equityPct(), 0, 'eq after roll');
  A.mark('A', -7); near(A.equityPct(), -1, 'delta');
  eq(A.canEnter(Q('B', 's', 36100, '20261103')).ok, true, 'within');
  A.mark('A', -10); eq(A.canEnter(Q('B', 's', 36200, '20261103')).why, 'daily_loss');
});
'@
$newTest = ($newTest -replace "`r`n", "`n") + "`n"
$replacement = $newTest + $anchor
$t2 = $t.Replace($anchor, $replacement)

# 4) 삽입 결과 검사: 앵커 1개, 새 테스트 1개 유지
$cA = [regex]::Matches($t2, [regex]::Escape($anchor)).Count
$cN = [regex]::Matches($t2, [regex]::Escape("t('daily loss baseline at day roll'")).Count
if ($cA -ne 1 -or $cN -ne 1) { Fail "삽입 검사 실패 (앵커 $cA, 새테스트 $cN)"; exit 1 }

[IO.File]::WriteAllText($st, $t2, $enc)
if ([IO.File]::ReadAllText($st, $enc) -ne $t2) { Fail '재읽기 불일치'; exit 1 }
Ok '자가검증 파일 복구 및 테스트 삽입 (앵커 1, 새테스트 1)'

# 5) 문법 검사 후 실행
$ErrorActionPreference = 'Continue'
$chk = & node --check $st 2>&1
$cc = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($cc -ne 0) { $chk | ForEach-Object { Write-Host "  $_" }; Fail '문법 오류 - 위 내용을 붙여 주세요'; exit 1 }
Ok '문법 검사 통과'

$ErrorActionPreference = 'Continue'
$out = & node $st (Join-Path $Root 'strategies\risk') 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$out | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0) { Fail "자가검증 실패 (exit $code) - FAIL 줄을 붙여 주세요"; exit 1 }
Ok '리스크 자가검증 통과'

$ErrorActionPreference = 'Continue'
& node (Join-Path $Root 'tools\sz-probe.cjs') $Root 2>&1 | ForEach-Object { Write-Host "  $_" }
$ErrorActionPreference = 'Stop'
Ok '완료'
