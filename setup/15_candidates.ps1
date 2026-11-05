#requires -Version 5.1
# 15_candidates.ps1 : 안심존 확장 후보(MomLen 그리드) 추가
param([string]$Root = 'E:\parent\projects\rea\projects\mom-trader', [switch]$Force)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
$dir = Join-Path $Root 'strategies\candidates'
if (-not (Test-Path (Join-Path $Root 'strategies\manifest.json'))) { Write-Host '[실패] 기준선 미박제: 14_lab.ps1 -Freeze 먼저' -ForegroundColor Red; exit 1 }
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$enc = New-Object System.Text.UTF8Encoding($false)
$now = (Get-Date).ToUniversalTime().ToString('o')
$list = @(
  @('C013', '안심존 Mom(80)',            @{ MomLen = 80 },  '안심존 확장 그리드'),
  @('C014', '안심존 Mom(100)',           @{ MomLen = 100 }, '안심존 확장 그리드'),
  @('C015', '안심존 Mom(120)',           @{ MomLen = 120 }, '키움 Momentum 120과 동일'),
  @('C016', '안심존 Mom(160)',           @{ MomLen = 160 }, '안심존 확장 그리드'),
  @('C017', '안심존 Mom(200)',           @{ MomLen = 200 }, '워밍업 부족 종목은 장초 수 봉 Mom 없음'),
  @('C018', 'Mom(120)+이탈·목표전 ST',   @{ MomLen = 120; UnsafeBelow = 'supertrend' }, 'C015 + 생존 C003'),
  @('C019', 'Mom(120)+안심 강도0선 익절', @{ MomLen = 120; SafeBelow = 'macd_zero' }, '손실매도 금지 유지, 수익 중일 때만 강도0선 청산'),
  @('C020', 'Mom(120)+이탈 2봉 확인',     @{ MomLen = 120; SafeConfirm = 2 }, '확장 안심존에서 확인봉 효과')
)
$w = 0; $s = 0
try {
  foreach ($c in $list) {
    $f = Join-Path $dir ($c[0] + '.json')
    if ((Test-Path $f) -and -not $Force) { $s++; continue }
    $o = [ordered]@{ id = $c[0]; name = $c[1]; engine = 'v1'; base = 'S000'; overrides = $c[2]; note = $c[3]; created = $now }
    $json = $o | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($f, $json, $enc)
    $back = [IO.File]::ReadAllText($f, $enc) | ConvertFrom-Json
    if ($back.id -ne $c[0] -or $back.name -ne $c[1]) { throw "검증 실패: $f" }
    $w++
  }
} catch { Write-Host "[실패] $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
Write-Host "[성공] 후보 기록 $w 개, 기존 유지 $s 개: $dir" -ForegroundColor Green
