#requires -Version 5.1
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
$dir = 'E:\parent\projects\rea\projects\mom-trader\setup'
$enc = New-Object System.Text.UTF8Encoding($true)

# 형식 검사에서 빠진 코드를 알리는 줄 ($codeList 바로 다음에 삽입)
$warnLine = @'
$__raw = @(($Codes -join ',') -split '[,\s;]+' | Where-Object { $_ }); $__bad = @($__raw | Where-Object { $codeList -notcontains $_.Trim() }); if ($__bad.Count -gt 0) { Write-Host ('[제외] 종목코드 형식 불일치: ' + ($__bad -join ', ')) -ForegroundColor Yellow }  # [16_patch]
'@.Trim()

$allOk = $true
foreach ($name in '09_fetch_ticks.ps1', '12_fetch_daily.ps1') {
    $f = Join-Path $dir $name
    $src = [IO.File]::ReadAllText($f, $enc)
    if ($src.Contains('[16_patch]')) { Write-Host "[정보] $name 이미 패치됨"; continue }

    $lines = $src -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $hit = 0; $encFix = 0
    foreach ($l in $lines) {
        if ($l -match '^\s*\$codeList\s*=' -and $l -match '\\d\{6\}|\[0-9\]\{6\}') {
            $out.Add($l.Replace('\d{6}', '[0-9A-Z]{6}').Replace('[0-9]{6}', '[0-9A-Z]{6}'))
            $hit++
            # 줄이 파이프나 백틱으로 이어지면 삽입하지 않음
            if ($l.TrimEnd() -notmatch '[|`]$') { $out.Add($warnLine) }
            continue
        }
        if ($name -eq '09_fetch_ticks.ps1' -and $l -match 'OutputEncoding' -and $l -notmatch '^\s*#') {
            $out.Add('# [16_patch] ' + $l); $encFix++; continue
        }
        $out.Add($l)
    }
    if ($hit -ne 1) { Write-Host "[실패] $name : `$codeList 줄 $hit 개 발견(1개여야 함) - 수정 안 함" -ForegroundColor Red; $allOk = $false; continue }

    Copy-Item $f "$f.bak16" -Force
    [IO.File]::WriteAllText($f, ($out -join "`r`n"), $enc)

    # 문법 검사, 실패 시 복구
    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tok, [ref]$err)
    if ($err.Count -gt 0) {
        Copy-Item "$f.bak16" $f -Force
        Write-Host "[실패] $name 문법 오류 -> 원본 복구: $($err[0].Message) (줄 $($err[0].Extent.StartLineNumber))" -ForegroundColor Red
        $allOk = $false; continue
    }
    Write-Host "[성공] $name : 코드형식 1줄 수정, 인코딩줄 주석 $encFix 개 (백업 .bak16)"
}

# 정규식 자체 확인
$t = @('0011A0', '232680', '12345', 'ABCDEFG') | ForEach-Object { "$_=" + ($_ -match '^[0-9A-Z]{6}$') }
Write-Host ('[확인] ' + ($t -join '  '))   # 기대값: True True False False
if (-not $allOk) { exit 1 }
