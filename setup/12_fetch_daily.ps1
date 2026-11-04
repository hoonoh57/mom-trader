#requires -Version 5.1
# mom-trader : 키움 REST ka10081 일봉 다운로드 (전일 상한가 판정용, KRX 종가 기준)
param(
  [string[]]$Codes = @('030530'),
  [string]$BaseDate = (Get-Date -Format 'yyyyMMdd'),
  [ValidateSet('AUTO','MOCK','REAL')][string]$Server = 'AUTO',
  [string]$EnvPath = 'E:\parent\security\.env',
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [double]$LimPct = 29,
  [int]$DelayMs = 300
)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM' -ForegroundColor Red; exit 1 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
function Ok([string]$m)   { Write-Host "[성공] $m" -ForegroundColor Green }
function Bad([string]$m)  { Write-Host "[실패] $m" -ForegroundColor Red }
function Info([string]$m) { Write-Host $m -ForegroundColor Gray }

function To-Num($s) {
  if ($null -eq $s) { return $null }
  $t = "$s".Trim().Replace(',', ''); if ($t -eq '') { return $null }
  [double]$d = 0
  if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return [math]::Abs($d) }
  return $null
}
function Read-DotEnv([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw ".env 파일 없음: $Path" }
  $map = @{}
  foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
    $t = $line.Trim(); if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('='); if ($i -lt 1) { continue }
    $v = $t.Substring($i + 1).Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) { $v = $v.Substring(1, $v.Length - 2) }
    $map[$t.Substring(0, $i).Trim()] = $v
  }
  return $map
}
function Invoke-Kiwoom([string]$Url, [hashtable]$Headers, [hashtable]$Body) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
      $resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $Headers -Body $bytes -ContentType 'application/json;charset=UTF-8' -UseBasicParsing -TimeoutSec 20
      $ms = New-Object IO.MemoryStream; $resp.RawContentStream.Position = 0; $resp.RawContentStream.CopyTo($ms)
      $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
      return [pscustomobject]@{ Text = $text; Json = ($text | ConvertFrom-Json) }
    } catch {
      $status = 0; $err = $_.Exception.Message
      if ($_.Exception.Response) { try { $status = [int]$_.Exception.Response.StatusCode } catch {} }
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $err = $_.ErrorDetails.Message }
      if ($status -eq 429 -and $attempt -lt 4) { Start-Sleep -Milliseconds (1000 * $attempt); continue }
      throw "HTTP $status : $err"
    }
  }
}

Write-Host "=== mom-trader 일봉 다운로드 (ka10081, 기준일 $BaseDate) ===" -ForegroundColor Cyan
try { $envMap = Read-DotEnv $EnvPath } catch { Bad $_.Exception.Message; exit 1 }
$useMock = switch ($Server) { 'MOCK' { $true } 'REAL' { $false } default { "$($envMap['KIWOOM_USE_MOCK'])".Trim().ToLower() -eq 'true' } }
if ($useMock) { $base = 'https://mockapi.kiwoom.com'; $kName = 'KIWOOM_MOCK_APP_KEY'; $sName = 'KIWOOM_MOCK_SECRET_KEY' }
else          { $base = 'https://api.kiwoom.com';     $kName = 'KIWOOM_REAL_APP_KEY'; $sName = 'KIWOOM_REAL_SECRET_KEY' }
$appKey = "$($envMap[$kName])"; $secret = "$($envMap[$sName])"
if (-not $appKey -or -not $secret) { Bad "$kName / $sName 값이 비어 있음"; exit 1 }
try {
  $t = Invoke-Kiwoom "$base/oauth2/token" @{} @{ grant_type = 'client_credentials'; appkey = $appKey; secretkey = $secret }
  $token = "$($t.Json.token)"; if (-not $token) { throw "return_code=$($t.Json.return_code) msg=$($t.Json.return_msg)" }
  Ok '토큰 발급'
} catch { Bad "토큰 발급 실패: $($_.Exception.Message)"; exit 1 }

$codeList = @(($Codes -join ',') -split '[,\s]+' | Where-Object { $_ -match '^[0-9A-Z]{6}$' })
$__raw = @(($Codes -join ',') -split '[,\s;]+' | Where-Object { $_ }); $__bad = @($__raw | Where-Object { $codeList -notcontains $_.Trim() }); if ($__bad.Count -gt 0) { Write-Host ('[제외] 종목코드 형식 불일치: ' + ($__bad -join ', ')) -ForegroundColor Yellow }  # [16_patch]
if ($codeList.Count -eq 0) { Bad '유효한 6자리 종목코드 없음'; exit 1 }
$outDir = Join-Path $Root 'data\daily'; $logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $outDir, $logDir | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$fail = 0

foreach ($code in $codeList) {
  try {
    $h = @{ 'authorization' = "Bearer $token"; 'api-id' = 'ka10081' }
    $r = Invoke-Kiwoom "$base/api/dostk/chart" $h @{ stk_cd = $code; base_dt = $BaseDate; upd_stkpc_tp = '1' }
    if ("$($r.Json.return_code)" -ne '0') { throw "return_code=$($r.Json.return_code) msg=$($r.Json.return_msg)" }
    [IO.File]::WriteAllText((Join-Path $logDir "raw-daily-$code.json"), $r.Text, $utf8)
    $list = @(); if ($r.Json.stk_dt_pole_chart_qry) { $list = @($r.Json.stk_dt_pole_chart_qry) }
    if ($list.Count -eq 0) { throw "stk_dt_pole_chart_qry 비어 있음 (logs\raw-daily-$code.json 확인)" }
    $rows = foreach ($it in $list) {
      $d = "$($it.dt)".Trim()
      $o = To-Num $it.open_pric; $hi = To-Num $it.high_pric; $lo = To-Num $it.low_pric; $c = To-Num $it.cur_prc; $v = To-Num $it.trde_qty
      if ($d -match '^\d{8}$' -and $null -notin @($o, $hi, $lo, $c) -and $c -gt 0) { [pscustomobject]@{ date = $d; o = $o; h = $hi; l = $lo; c = $c; v = $v } }
    }
    $rows = @($rows | Sort-Object date -Unique)
    if ($rows.Count -lt 3) { throw "유효 일봉 $($rows.Count)개 (필드: $($list[0].PSObject.Properties.Name -join ', '))" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('date,open,high,low,close,volume,chg_pct')
    for ($i = 0; $i -lt $rows.Count; $i++) {
      $b = $rows[$i]; $chg = if ($i -gt 0) { ($b.c / $rows[$i - 1].c - 1) * 100 } else { $null }
      $lines.Add(('{0},{1},{2},{3},{4},{5},{6}' -f $b.date, $b.o, $b.h, $b.l, $b.c, $b.v, $(if ($null -eq $chg) { '' } else { $chg.ToString('0.00', $Inv) })))
    }
    $csv = Join-Path $outDir "$code.csv"
    [IO.File]::WriteAllLines($csv, $lines, $utf8)
    Ok "$code : $($rows.Count)일 ($($rows[0].date)~$($rows[-1].date)) -> $csv"
    for ($i = [math]::Max(1, $rows.Count - 4); $i -lt $rows.Count; $i++) {
      $chg = ($rows[$i].c / $rows[$i - 1].c - 1) * 100
      Info ("     {0}  종가 {1,10:N0}  {2,7:+0.00;-0.00}%{3}" -f $rows[$i].date, $rows[$i].c, $chg, $(if ($chg -ge $LimPct) { '  <- 상한가' } else { '' }))
    }
  } catch { Bad "$code : $($_.Exception.Message)"; $fail++ }
  Start-Sleep -Milliseconds $DelayMs
}
if ($fail -eq 0) { Ok "일봉 $($codeList.Count)종목 완료"; exit 0 }
Bad "$fail / $($codeList.Count) 종목 실패"; exit 1
