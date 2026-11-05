#requires -Version 5.1
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [string]$Date = '20261102',
  [int[]]$Minutes = @(5, 10, 15, 30),
  [int]$Tick = 120,
  [string]$EndHms = '153000'
)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
$files = @(Get-ChildItem (Join-Path $Root 'data\ticks') -Filter "*_AL_${Tick}t_$Date.csv")
if ($files.Count -eq 0) { Write-Host "[실패] 파일 없음: *_AL_${Tick}t_$Date.csv"; exit 1 }

function Find-Col($names, [string[]]$cands) {
  foreach ($c in $cands) { $m = $names | Where-Object { $_ -ieq $c } | Select-Object -First 1; if ($m) { return $m } }
  $null
}
function To-N($v) { [math]::Abs([double](($v -as [string]) -replace '[^\d\.\-]', '')) }

$data = @{}
foreach ($f in $files) {
  $code = $f.Name.Split('_')[0]
  $d = @(Import-Csv $f.FullName -Encoding UTF8)
  $h = $d[0].PSObject.Properties.Name
  $cT = Find-Col $h @('time','cntr_tm','ts','datetime','t')
  $cD = Find-Col $h @('date','tradingDate','trade_date','dt','day')
  $cO = Find-Col $h @('open','o','open_pric'); $cH = Find-Col $h @('high','h','high_pric')
  $cL = Find-Col $h @('low','l','low_pric');   $cC = Find-Col $h @('close','c','cur_prc')
  $cV = Find-Col $h @('volume','vol','v','trde_qty')
  if (-not ($cT -and $cC -and $cV)) { Write-Host "[실패] $code 열 인식 실패. 헤더: $($h -join ',')"; exit 1 }
  $bars = foreach ($r in $d) {
    $s = ($r.$cT -as [string]) -replace '\D', ''
    if ($s.Length -ge 14) { $dt = $s.Substring(0, 8); $hms = $s.Substring(8, 6) }
    elseif ($s.Length -eq 10 -and [double]$s -gt 1e9) {
      $k = [DateTimeOffset]::FromUnixTimeSeconds([long]$s).ToOffset([TimeSpan]::FromHours(9))
      $dt = $k.ToString('yyyyMMdd'); $hms = $k.ToString('HHmmss')
    }
    elseif ($cD) { $dt = (($r.$cD -as [string]) -replace '\D', '').Substring(0, 8); $hms = $s.PadLeft(6, '0').Substring(0, 6) }
    else { Write-Host "[실패] $code 시간 형식 인식 불가: '$($r.$cT)' 헤더: $($h -join ',')"; exit 1 }
    if ($dt -ne $Date -or $hms -lt '090000' -or $hms -gt $EndHms) { continue }
    $c = To-N $r.$cC
    $o = if ($cO) { To-N $r.$cO } else { $c }; $hi = if ($cH) { To-N $r.$cH } else { $c }; $lo = if ($cL) { To-N $r.$cL } else { $c }
    [pscustomobject]@{ hms = $hms; c = $c; h = $hi; amt = ($o + $hi + $lo + $c) / 4 * (To-N $r.$cV) }
  }
  $data[$code] = @($bars)
}

$hit1 = 0; $hit2 = 0; $n = 0
foreach ($k in $Minutes) {
  $cut = (Get-Date '09:00').AddMinutes($k).ToString('HHmmss')
  $rows = foreach ($code in $data.Keys) {
    $b = $data[$code]; $pre = @($b | Where-Object { $_.hms -lt $cut }); $post = @($b | Where-Object { $_.hms -ge $cut })
    if ($pre.Count -eq 0) { [pscustomobject]@{ code = $code; trades = 0; amt = 0; mfe = 0 }; continue }
    $px = $pre[-1].c
    $mx = if ($post.Count) { ($post | Measure-Object h -Maximum).Maximum } else { $px }
    [pscustomobject]@{ code = $code; trades = $pre.Count * $Tick; amt = [math]::Round(($pre | Measure-Object amt -Sum).Sum / 1e8, 1); mfe = [math]::Round(($mx / $px - 1) * 100, 2) }
  }
  $byT = @($rows | Sort-Object trades -Descending); $byM = @($rows | Sort-Object mfe -Descending)
  Write-Host ""; Write-Host "=== 09:00+${k}분 순위 (체결건수 기준) / 이후 MFE ===" -ForegroundColor Cyan
  $i = 0
  foreach ($r in $byT) { $i++; $mr = [array]::IndexOf(($byM | ForEach-Object code), $r.code) + 1
    Write-Host ("{0,2}. {1,-7} 체결 {2,7:N0}  대금 {3,7:N1}억  이후MFE {4,6:N2}%  (MFE순위 {5})" -f $i, $r.code, $r.trades, $r.amt, $r.mfe, $mr) }
  $n++
  if ($byT[0].code -eq $byM[0].code) { $hit1++ }
  if ($byT.Count -ge 2 -and (@($byT[0..1].code) | Where-Object { @($byM[0..1].code) -contains $_ }).Count -ge 1) { $hit2++ }
}
Write-Host ""
Write-Host "[요약] $Date 종목 $($data.Count) / 1위 적중 $hit1/$n 시점 / 상위2 중 MFE상위2 포함 $hit2/$n 시점"
Write-Host '[성공] 완료'
