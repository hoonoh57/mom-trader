. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '08_verify.ps1'
Write-Info "08_verify: 1단계 검증 시작 → $Root"

$LogDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("verify-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Log = New-Object System.Collections.Generic.List[string]

function Save-Log { [System.IO.File]::WriteAllLines($LogFile, $Log, $Utf8NoBom) }

function Stop-Verify {
  param([string]$Stage, [string]$Reason, [string[]]$Hints = @(), [string[]]$Tail = @())
  Save-Log
  Write-Host ''
  Write-Fail "검증 실패 — 단계: $Stage"
  Write-Host "  원인: $Reason" -ForegroundColor Yellow
  foreach ($h in $Hints) { Write-Host "  조치: $h" -ForegroundColor Yellow }
  if ($Tail.Count -gt 0) {
    Write-Host '  ── 관련 출력 ──' -ForegroundColor DarkGray
    foreach ($t in $Tail) { Write-Host "  $t" -ForegroundColor DarkGray }
  }
  Write-Host "  전체 로그: $LogFile"
  exit 1
}

function Invoke-Cmd([string]$Label, [string]$CommandLine) {
  $Log.Add("===== $Label : $CommandLine =====")
  Push-Location -LiteralPath $Root
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & cmd.exe /d /c "$CommandLine 2>&1"
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
    Pop-Location
  }
  $lines = @($out | ForEach-Object { [string]$_ })
  foreach ($l in $lines) { $Log.Add($l) }
  $Log.Add("exit=$code")
  return [pscustomobject]@{ Code = $code; Lines = $lines }
}

# [1/6] 인코딩
Write-Ok '[1/6] 스크립트/콘솔 인코딩 정상 (UTF-8)'

# [2/6] Node / npm
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Stop-Verify 'Node.js 확인' 'node 명령을 찾을 수 없음' @('Node.js 18 이상 설치 후 새 PowerShell 창에서 다시 실행')
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
  Stop-Verify 'npm 확인' 'npm 명령을 찾을 수 없음' @('Node.js 설치 시 npm 포함 여부 확인, PATH 확인')
}
$nodeVer = ([string](& node -v)).Trim()
$major = 0
[void][int]::TryParse(($nodeVer.TrimStart('v').Split('.')[0]), [ref]$major)
if ($major -lt 18) {
  Stop-Verify 'Node.js 버전' "현재 $nodeVer (18 이상 필요)" @('Node.js LTS 로 업그레이드')
}
Write-Ok "[2/6] Node $nodeVer"

# [3/6] 파일 존재 + BOM 검사
$owner = [ordered]@{
  'package.json'                = '01_scaffold.ps1'
  'tsconfig.json'               = '01_scaffold.ps1'
  'src\core\types.ts'           = '02_core.ps1'
  'src\core\incremental.ts'     = '02_core.ps1'
  'src\core\session.ts'         = '02_core.ps1'
  'src\core\amount.ts'          = '02_core.ps1'
  'src\core\params.ts'          = '02_core.ps1'
  'src\indicators\momentum.ts'  = '03_momentum.ps1'
  'src\indicators\nmacd.ts'     = '04_nmacd.ps1'
  'src\indicators\bigprint.ts'  = '05_bigprint.ps1'
  'src\indicators\dayAmount.ts' = '06_dayamount.ps1'
  'src\index.ts'                = '06_dayamount.ps1'
  'tests\harness.ts'            = '07_tests.ps1'
  'tests\fixtures.ts'           = '07_tests.ps1'
  'tests\indicators.test.ts'    = '07_tests.ps1'
  'tests\run.ts'                = '07_tests.ps1'
}
$missing = @(); $bomFiles = @(); $fixBy = @()
foreach ($rel in $owner.Keys) {
  $full = Join-Path $Root $rel
  if (-not (Test-Path -LiteralPath $full)) { $missing += $rel; $fixBy += $owner[$rel]; continue }
  $b = [System.IO.File]::ReadAllBytes($full)
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $bomFiles += $rel; $fixBy += $owner[$rel] }
}
if ($missing.Count -gt 0 -or $bomFiles.Count -gt 0) {
  $reason = @()
  if ($missing.Count)  { $reason += "누락: $($missing -join ', ')" }
  if ($bomFiles.Count) { $reason += "BOM 포함: $($bomFiles -join ', ')" }
  Stop-Verify '파일 확인' ($reason -join ' / ') @("다시 실행: $((($fixBy | Select-Object -Unique) -join ', '))")
}
Write-Ok "[3/6] 필수 파일 $($owner.Count)개 확인 (UTF-8, BOM 없음)"

# [4/6] 의존성
$tscPath = Join-Path $Root 'node_modules\typescript\bin\tsc'
$typesNode = Join-Path $Root 'node_modules\@types\node\package.json'
if (-not (Test-Path -LiteralPath $tscPath) -or -not (Test-Path -LiteralPath $typesNode)) {
  Write-Info '[4/6] npm install 실행 중 (최초 1회, 네트워크 필요)...'
  $r = Invoke-Cmd 'npm install' 'npm install --no-audit --no-fund'
  if ($r.Code -ne 0) {
    Stop-Verify 'npm install' "종료코드 $($r.Code)" @('네트워크/프록시 확인', 'npm cache verify 후 재실행') ($r.Lines | Select-Object -Last 8)
  }
}
Write-Ok '[4/6] 의존성 준비 (typescript, @types/node)'

# [5/6] 타입 검사
$r = Invoke-Cmd 'typecheck' 'node node_modules\typescript\bin\tsc -p tsconfig.json --noEmit'
if ($r.Code -ne 0) {
  $errs = @($r.Lines | Where-Object { $_ -match 'error TS\d+' } | Select-Object -First 10)
  if ($errs.Count -eq 0) { $errs = @($r.Lines | Select-Object -Last 10) }
  Stop-Verify '타입 검사' "TypeScript 오류 $(@($r.Lines | Where-Object { $_ -match 'error TS\d+' }).Count)건" @(
    '오류 줄의 파일(줄,열) 위치를 확인',
    '해당 파일을 만드는 0X 스크립트를 다시 실행해 재생성'
  ) $errs
}
Write-Ok '[5/6] 타입 검사 통과 (strict)'

# [6/6] 빌드 + 테스트
$dist = Join-Path $Root 'dist'
if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
$r = Invoke-Cmd 'build' 'node node_modules\typescript\bin\tsc -p tsconfig.json'
if ($r.Code -ne 0) {
  Stop-Verify '빌드' "tsc 종료코드 $($r.Code)" @('타입 검사는 통과했는데 빌드 실패 → dist 폴더 권한/잠금 확인') ($r.Lines | Select-Object -Last 10)
}

$test = Invoke-Cmd 'test' 'node dist\tests\run.js'
foreach ($l in $test.Lines) {
  if ($l -match '\[PASS\]')          { Write-Host $l -ForegroundColor Green }
  elseif ($l -match '\[FAIL\]|원인:') { Write-Host $l -ForegroundColor Red }
  else                                { Write-Host $l }
}

$resultLine = $test.Lines | Where-Object { $_ -match '^RESULT: (\d+)/(\d+)' } | Select-Object -Last 1
if (-not $resultLine) {
  Stop-Verify '테스트 실행' "테스트 러너가 결과를 출력하지 못함 (exit=$($test.Code))" @(
    '런타임 예외 가능성: 아래 출력의 Error 줄 확인',
    'dist 삭제 후 08_verify.ps1 재실행'
  ) ($test.Lines | Select-Object -Last 15)
}
$null = $resultLine -match '^RESULT: (\d+)/(\d+)'
$passed = [int]$Matches[1]
$total = [int]$Matches[2]
if ($test.Code -ne 0 -or $passed -ne $total) {
  $failLines = @($test.Lines | Where-Object { $_ -match '\[FAIL\]|원인:' })
  Stop-Verify '테스트' "테스트 $passed/$total 통과" @('아래 실패 케이스 이름과 원인을 그대로 전달해 주세요') $failLines
}

Save-Log
Write-Host ''
Write-Ok "mom-trader 1단계 검증 통과 — 테스트 $passed/$total, Node $nodeVer"
Write-Host "  로그: $LogFile"
exit 0
