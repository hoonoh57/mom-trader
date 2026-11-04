#requires -Version 5.1
# mom-trader : 키움 REST ka10079 틱차트 다운로드 + 검증
param(
  [string[]]$Codes = @('030530'),
  [string]$Date = '',                       # yyyyMMdd, 비우면 응답의 최신 거래일
  [ValidateSet('1','3','5','10','30','60','120')][string]$Scope = '120',
  [ValidateSet('AUTO','KRX','NXT','AL')][string]$Market = 'AUTO',
  [ValidateSet('AUTO','MOCK','REAL')][string]$Server = 'AUTO',
  [string]$EnvPath = 'E:\parent\security\.env',
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [int]$WarmupBars = 200,                   # 대상일 이전 봉 확보 수 (Mom50/강도 워밍업)
  [int]$MaxPages = 80,
  [int]$DelayMs = 300,
  [switch]$SelfTestOnly
)

try { chcp.com 65001 > $null } catch { }
# [16_patch] [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# [16_patch] $OutputEncoding = [System.Text.Encoding]::UTF8

if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM' -ForegroundColor Red; exit 1 }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Log = New-Object System.Collections.Generic.List[string]

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c; $Log.Add($m) }
function Ok([string]$m)   { Say "[성공] $m" 'Green' }
function Bad([string]$m)  { Say "[실패] $m" 'Red' }
function Warn([string]$m) { Say "[주의] $m" 'Yellow' }
function F($d) { ([double]$d).ToString('0.####', $Inv) }

function To-Num($s) {
  if ($null -eq $s) { return $null }
  $t = "$s".Trim().Replace(',', '')
  if ($t -eq '') { return $null }
  [double]$d = 0
  if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return [math]::Abs($d) }
  return $null
}

function Read-DotEnv([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw ".env 파일 없음: $Path" }
  $map = @{}
  foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
    $map[$k] = $v
  }
  return $map
}

function Get-Header($headers, [string]$name) {
  if ($null -eq $headers) { return '' }
  foreach ($k in @($headers.Keys)) {
    if ($k -eq $name) { $v = $headers[$k]; if ($v -is [string]) { return $v }; return (@($v) -join ',') }
  }
  return ''
}

function ConvertTo-TickRow($it) {
  $ts = "$($it.cntr_tm)".Trim()
  if ($ts.Length -lt 14) { return $null }
  $o = To-Num $it.open_pric; $h = To-Num $it.high_pric; $l = To-Num $it.low_pric
  $c = To-Num $it.cur_prc;   $v = To-Num $it.trde_qty
  if ($null -in @($o, $h, $l, $c, $v)) { return $null }
  [pscustomobject]@{
    ts = $ts.Substring(0, 14); date = $ts.Substring(0, 8); time = $ts.Substring(8, 6)
    open = $o; high = $h; low = $l; close = $c; volume = $v
    amount = ($o + $h + $l + $c) / 4 * $v
  }
}

function Invoke-Kiwoom([string]$Url, [hashtable]$Headers, [hashtable]$Body) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    try {
      $resp = Invoke-WebRequest -Uri $Url -Method Post -Headers $Headers -Body $bytes `
              -ContentType 'application/json;charset=UTF-8' -UseBasicParsing -TimeoutSec 20
      $text = $null
      if ($resp.RawContentStream) {
        $ms = New-Object IO.MemoryStream; $resp.RawContentStream.Position = 0; $resp.RawContentStream.CopyTo($ms)
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
      } else { $text = $resp.Content }
      return [pscustomobject]@{ Headers = $resp.Headers; Text = $text; Json = ($text | ConvertFrom-Json) }
    } catch {
      $status = 0; $err = $_.Exception.Message
      $r = $_.Exception.Response
      if ($r) {
        try { $status = [int]$r.StatusCode } catch {}
        try { $sr = New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8); $err = $sr.ReadToEnd() } catch {}
      }
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $err = $_.ErrorDetails.Message }
      if ($status -eq 429 -and $attempt -lt 4) { Start-Sleep -Milliseconds (1000 * $attempt); continue }
      throw "HTTP $status : $err"
    }
  }
}

# ---------- 1. 오프라인 자가검증 ----------
function Invoke-SelfTest {
  $fail = 0
  if ((To-Num '-71200') -ne 71200 -or (To-Num '+1,234') -ne 1234 -or $null -ne (To-Num '')) { $fail++; Bad '자가검증: To-Num' }
  $tmp = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($tmp, "# c`nA=1`nB=`"x y`"`nC=`n", (New-Object Text.UTF8Encoding($false)))
  $e = Read-DotEnv $tmp; Remove-Item $tmp -Force
  if ($e['A'] -ne '1' -or $e['B'] -ne 'x y' -or $e['C'] -ne '' -or $e.ContainsKey('# c')) { $fail++; Bad '자가검증: Read-DotEnv' }
  $row = ConvertTo-TickRow ([pscustomobject]@{ cntr_tm='20261102090001'; open_pric='-100'; high_pric='110'; low_pric='90'; cur_prc='+100'; trde_qty='10' })
  if ($null -eq $row -or $row.amount -ne 1000 -or $row.date -ne '20261102' -or $row.time -ne '090001') { $fail++; Bad '자가검증: ConvertTo-TickRow' }
  if ((Get-Header @{ 'Cont-Yn' = 'Y' } 'cont-yn') -ne 'Y') { $fail++; Bad '자가검증: Get-Header' }
  if ($fail -eq 0) { Ok '자가검증 4/4 통과 (오프라인)' }
  return ($fail -eq 0)
}

Say "=== mom-trader 틱 다운로드 (ka10079, ${Scope}틱) ===" 'Cyan'
if (-not (Invoke-SelfTest)) { exit 1 }
if ($SelfTestOnly) { exit 0 }

# ---------- 2. 인증 정보 ----------
try { $envMap = Read-DotEnv $EnvPath } catch { Bad $_.Exception.Message; exit 1 }
$useMock = switch ($Server) { 'MOCK' { $true } 'REAL' { $false } default { "$($envMap['KIWOOM_USE_MOCK'])".Trim().ToLower() -eq 'true' } }
if ($useMock) { $base = 'https://mockapi.kiwoom.com'; $kName = 'KIWOOM_MOCK_APP_KEY'; $sName = 'KIWOOM_MOCK_SECRET_KEY' }
else          { $base = 'https://api.kiwoom.com';     $kName = 'KIWOOM_REAL_APP_KEY'; $sName = 'KIWOOM_REAL_SECRET_KEY' }
$appKey = "$($envMap[$kName])"; $secret = "$($envMap[$sName])"
if (-not $appKey) { Bad "$kName 값이 비어 있음 ($EnvPath)"; exit 1 }
if (-not $secret) { Bad "$sName 값이 비어 있음 ($EnvPath)"; exit 1 }
$mkt = if ($Market -ne 'AUTO') { $Market } else { 'AL' }
Say ("서버: {0} ({1}) / 키: {2} len={3} / 시장: {4}" -f ($(if ($useMock) {'모의'} else {'실전'})), $base, $kName, $appKey.Length, $mkt)

# ---------- 3. 토큰 ----------
try {
  $t = Invoke-Kiwoom "$base/oauth2/token" @{} @{ grant_type = 'client_credentials'; appkey = $appKey; secretkey = $secret }
  $token = "$($t.Json.token)"
  if (-not $token) { throw "return_code=$($t.Json.return_code) msg=$($t.Json.return_msg)" }
  Ok "토큰 발급 (만료: $($t.Json.expires_dt))"
} catch { Bad "토큰 발급 실패: $($_.Exception.Message)"; exit 1 }

# ---------- 4. 종목별 다운로드 ----------
$codeList = @(($Codes -join ',') -split '[,\s]+' | Where-Object { $_ -match '^[0-9A-Z]{6}$' })
$__raw = @(($Codes -join ',') -split '[,\s;]+' | Where-Object { $_ }); $__bad = @($__raw | Where-Object { $codeList -notcontains $_.Trim() }); if ($__bad.Count -gt 0) { Write-Host ('[제외] 종목코드 형식 불일치: ' + ($__bad -join ', ')) -ForegroundColor Yellow }  # [16_patch]
if ($codeList.Count -eq 0) { Bad '유효한 6자리 종목코드 없음 (-Codes "030530,184230")'; exit 1 }
$outDir = Join-Path $Root 'data\ticks'; $logDir = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $outDir, $logDir | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)
$failCount = 0

foreach ($code in $codeList) {
  Say "--- $code ---" 'Cyan'
  $stk = switch ($mkt) { 'KRX' { $code } 'NXT' { "${code}_NX" } 'AL' { "${code}_AL" } }
  $all = New-Object System.Collections.Generic.List[object]
  $target = $Date; $next = ''; $endReason = ''; $badRows = 0; $prevCount = 0
  try {
    for ($page = 1; $page -le $MaxPages; $page++) {
      $h = @{ 'authorization' = "Bearer $token"; 'api-id' = 'ka10079' }
      if ($page -gt 1) { $h['cont-yn'] = 'Y'; $h['next-key'] = $next }
      $r = Invoke-Kiwoom "$base/api/dostk/chart" $h @{ stk_cd = $stk; tic_scope = $Scope; upd_stkpc_tp = '1' }
      $rc = "$($r.Json.return_code)"
      if ($rc -ne '0') { throw "ka10079 return_code=$rc msg=$($r.Json.return_msg)" }
      $chunk = @(); if ($r.Json.stk_tic_chart_qry) { $chunk = @($r.Json.stk_tic_chart_qry) }
      if ($page -eq 1) {
        [IO.File]::WriteAllText((Join-Path $logDir "raw-$code-$Scope-p1.json"), $r.Text, $utf8)
        if ($chunk.Count -gt 0) { Say ("응답 필드: " + ($chunk[0].PSObject.Properties.Name -join ', ')) }
      }
      if ($chunk.Count -eq 0) { $endReason = '빈 응답'; break }
      foreach ($it in $chunk) { $row = ConvertTo-TickRow $it; if ($row) { $all.Add($row) } else { $badRows++ } }
      if (-not $target) { $target = ($all | ForEach-Object { $_.date } | Sort-Object -Descending | Select-Object -First 1) }
      $prevCount = @($all | Where-Object { $_.date -lt $target }).Count
      if ($prevCount -ge $WarmupBars) { $endReason = '워밍업 확보'; break }
      $cont = Get-Header $r.Headers 'cont-yn'; $next = Get-Header $r.Headers 'next-key'
      if ($cont -ne 'Y' -or -not $next) { $endReason = "연속조회 끝(cont-yn=$cont)"; break }
      Start-Sleep -Milliseconds $DelayMs
    }
    if (-not $endReason) { $endReason = "MaxPages($MaxPages) 도달" }
  } catch {
    Bad "$code 다운로드 실패: $($_.Exception.Message)"
    if ($Scope -in @('60', '120')) { Warn '공식 명세의 틱범위는 1/3/5/10/30 입니다. -Scope 30 으로 재시도해 보세요.' }
    if ($mkt -ne 'KRX') { Warn '-Market KRX 로도 재시도해 보세요 (모의서버는 _AL/_NX 미지원 가능).' }
    $failCount++; continue
  }

  # 응답은 최신→과거 순. 같은 초 안의 봉 순서를 보존하려고 정렬 대신 역순으로 뒤집는다.
  $arr = $all.ToArray(); [Array]::Reverse($arr)
  $prev = @($arr | Where-Object { $_.date -lt $target })
  $tgt  = @($arr | Where-Object { $_.date -eq $target })
  $keep = if ($prev.Count -gt $WarmupBars) { $prev[($prev.Count - $WarmupBars)..($prev.Count - 1)] } else { $prev }
  $out  = @($keep) + @($tgt)

  $nonMono = 0; $ohlcBad = 0; $sameTs = 0
  for ($i = 0; $i -lt $out.Count; $i++) {
    $b = $out[$i]
    if ($b.low -gt [math]::Min($b.open, $b.close) -or $b.high -lt [math]::Max($b.open, $b.close) -or $b.low -le 0) { $ohlcBad++ }
    if ($i -gt 0) { if ($b.ts -lt $out[$i - 1].ts) { $nonMono++ } elseif ($b.ts -eq $out[$i - 1].ts) { $sameTs++ } }
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('ts,date,time,open,high,low,close,volume,bar_amount,is_target')
  foreach ($b in $out) {
    $lines.Add(('{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}' -f $b.ts, $b.date, $b.time, (F $b.open), (F $b.high), (F $b.low), (F $b.close), (F $b.volume), (F $b.amount), $(if ($b.date -eq $target) { 1 } else { 0 })))
  }
  $csv = Join-Path $outDir ("{0}_{1}_{2}t_{3}.csv" -f $code, $mkt, $Scope, $target)
  [IO.File]::WriteAllLines($csv, $lines, $utf8)

  $taamt = ($tgt | Measure-Object -Property amount -Sum).Sum
  Say ("대상일 {0}: {1}봉 ({2}~{3}), 이전일 워밍업 {4}봉, 종료사유: {5}" -f $target, $tgt.Count,
       $(if ($tgt.Count) { $tgt[0].time } else { '-' }), $(if ($tgt.Count) { $tgt[-1].time } else { '-' }), $keep.Count, $endReason)
  Say ("당일 누적거래대금(taamt 계산값): {0:N0}원 / 같은 초 봉 {1}쌍(정보)" -f $taamt, $sameTs)

  $ok = $true
  if ($tgt.Count -eq 0) { Bad "대상일 $target 데이터 없음 (보관 기간 초과 가능)"; $ok = $false }
  if ($badRows -gt 0)   { Bad "파싱 실패 행 $badRows 개 (logs\raw-$code-$Scope-p1.json 확인)"; $ok = $false }
  if ($nonMono -gt 0)   { Bad "시간 역순 $nonMono 건"; $ok = $false }
  if ($ohlcBad -gt 0)   { Bad "OHLC 불일치 $ohlcBad 건"; $ok = $false }
  if ($prev.Count -eq 0) { Warn '이전 거래일 봉이 없음: 대상일 첫 봉이 장 시작인지 보장 못함 (partial)' }
  elseif ($keep.Count -lt $WarmupBars) { Warn "워밍업 $($keep.Count)/$WarmupBars 봉: Mom50 초반값이 HTS와 다를 수 있음" }
  if ($ok) { Ok "$code 저장: $csv" } else { $failCount++ }
  Start-Sleep -Milliseconds $DelayMs
}

$logFile = Join-Path $logDir ("fetch-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
[IO.File]::WriteAllLines($logFile, $Log, $utf8)
if ($failCount -eq 0) { Ok "전체 $($codeList.Count)종목 완료 / 로그: $logFile"; exit 0 }
Bad "$failCount / $($codeList.Count) 종목 실패 / 로그: $logFile"; exit 1
