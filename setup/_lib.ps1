# mom-trader setup 공용 함수 — 반드시 "UTF-8 with BOM" 으로 저장
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Root = 'E:\parent\projects\rea\projects\mom-trader'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try { chcp.com 65001 > $null } catch { }
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$script:WriteCount = 0
$script:FailCount = 0

function Assert-ScriptEncoding([string]$Sample, [string]$ScriptName) {
  $expected = -join @([char]0xD55C, [char]0xAE00)
  if ($Sample -cne $expected) {
    Write-Host "[FAIL] $ScriptName : Korean text is broken. Re-save this .ps1 file as 'UTF-8 with BOM' and run again." -ForegroundColor Red
    exit 1
  }
}
Assert-ScriptEncoding '한글' '_lib.ps1'

function Write-Ok([string]$Message)   { Write-Host "[성공] $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host "[실패] $Message" -ForegroundColor Red }
function Write-Info([string]$Message) { Write-Host "[진행] $Message" -ForegroundColor Cyan }

$drive = Split-Path -Qualifier $Root
if (-not (Test-Path -LiteralPath "$drive\")) {
  Write-Fail "드라이브 $drive 를 찾을 수 없음 — _lib.ps1 의 `$Root 경로를 확인하세요."
  exit 1
}

function Write-ProjectFile {
  param(
    [Parameter(Mandatory)] [string]$RelPath,
    [Parameter(Mandatory)] [AllowEmptyString()] [string]$Content
  )
  $full = Join-Path $Root $RelPath
  try {
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $text = $Content -replace "`r`n", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [System.IO.File]::WriteAllText($full, $text, $Utf8NoBom)

    $bytes = [System.IO.File]::ReadAllBytes($full)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) { throw 'BOM이 기록됨 (UTF-8 no BOM 이어야 함)' }

    $back = [System.IO.File]::ReadAllText($full, $Utf8NoBom)
    if ($back -cne $text) {
      $n = [Math]::Min($back.Length, $text.Length); $i = 0
      while ($i -lt $n -and $back[$i] -ceq $text[$i]) { $i++ }
      throw "재읽기 내용 불일치 (첫 차이 위치 $i, 기대 길이 $($text.Length), 실제 $($back.Length))"
    }
    $script:WriteCount++
    Write-Host ("  [OK] {0}  ({1:N0} bytes)" -f $RelPath, $bytes.Length) -ForegroundColor DarkGreen
  } catch {
    $script:FailCount++
    Write-Fail "$RelPath : $($_.Exception.Message)"
    Write-Host "         경로: $full" -ForegroundColor DarkYellow
  }
}

function Complete-Step([string]$StepName) {
  if ($script:FailCount -gt 0) {
    Write-Fail "$StepName : $($script:FailCount)개 파일 실패 — 위 [실패] 줄의 경로/원인을 확인하세요."
    exit 1
  }
  Write-Ok "$StepName : $($script:WriteCount)개 파일 작성 및 재읽기 검증 완료"
  exit 0
}
