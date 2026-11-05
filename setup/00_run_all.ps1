. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '00_run_all.ps1'

$steps = @(
  '01_scaffold.ps1', '02_core.ps1', '03_momentum.ps1', '04_nmacd.ps1',
  '05_bigprint.ps1', '06_dayamount.ps1', '07_tests.ps1', '08_verify.ps1'
)

foreach ($s in $steps) {
  $path = Join-Path $PSScriptRoot $s
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Fail "스크립트 없음: $s (setup 폴더에 저장했는지 확인)"
    exit 1
  }
  Write-Host "`n>>> $s" -ForegroundColor Cyan
  try {
    & $path
  } catch {
    Write-Fail "$s 실행 중 예외: $($_.Exception.Message)"
    exit 1
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Fail "$s 에서 중단 (exit=$LASTEXITCODE). 위 메시지를 확인하세요."
    exit 1
  }
}
Write-Host ''
Write-Ok 'mom-trader 1단계 전체 완료'
exit 0
