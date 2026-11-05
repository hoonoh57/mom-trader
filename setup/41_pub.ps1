param(
  [switch]$Commit,
  [switch]$Push,
  [string]$Message = '',
  [string]$Email = '',
  [string]$EnvPath = 'E:\parent\security\.env',
  [int]$MaxKB = 2048
)
# 41_pub.ps1 pub-2.0 : public mirror of mom-trader. ASCII only.
# allowlist = setup\pub_allow.txt ; hard excludes ($HX) cannot be overridden by the allowlist.
# order: collect -> secret scan (any hit = abort, mirror untouched) -> clean mirror -> copy -> PUB_INDEX -> commit/push
$ErrorActionPreference = 'Continue'
$VER = 'pub-2.0'
$root = Split-Path -Parent $PSScriptRoot
$pub = 'E:\parent\projects\mom-trader-pub'
$opus = Join-Path $root 'out\FOR_OPUS.txt'
$allowF = Join-Path $PSScriptRoot 'pub_allow.txt'
$enc = New-Object System.Text.UTF8Encoding $false
$L = New-Object System.Collections.Generic.List[string]
$F = New-Object System.Collections.Generic.List[string]
$keep = New-Object System.Collections.Generic.List[object]
$big = New-Object System.Collections.Generic.List[string]
$hits = New-Object System.Collections.Generic.List[string]
$nHx = 0; $nameSkip = 0; $codeSkip = 0; $scanned = 0; $head = ''
if ($Push) { $Commit = $true }
$mode = 'preview'; if ($Commit) { $mode = 'commit' }; if ($Push) { $mode = 'push' }
$HX = '(?i)(^|\\)(data|logs|node_modules|dist|\.git|security)(\\|$)|\.bak|(^|\\)\.env|\.(pem|key|pfx|p12)$|(^|\\)raw-[^\\]*\.json$|\.ps1\.txt$'
$TXT = '(?i)\.(txt|md|csv|json|cjs|mjs|js|ts|ps1|html|htm|svg|css|ya?ml)$'
$PX = '(?i)["'']?(access_token|token|appkey|app_key|secretkey|secret_key|secret|authorization|password|passwd)["'']?\s*[:=]\s*["'']?(bearer\s+)?([A-Za-z0-9_\-\.\/\+=]{20,})'
$PAIRS = @(@('strategies\engines\v1.cjs', 'tools\sz-engine.cjs'), @('strategies\engines\risk1.cjs', 'tools\sz-risk.cjs'), @('strategies\engines\v3.cjs', 'tools\sz-engine3.cjs'))

$task = ''
if (Test-Path $opus) { $task = [IO.File]::ReadAllText($opus, $enc) }
$task = [regex]::Replace($task, '(?s)=== PUB sync .*?=== PUB end ===\r?\n?', '').Trim()
$goal = @()
$ch = Join-Path $root 'research\CHARTER.md'
if (Test-Path $ch) { $goal = @([IO.File]::ReadAllLines($ch, $enc) | Where-Object { $_ -match 'GOAL-[12]' } | Select-Object -First 2 | ForEach-Object { ($_ -replace '^[#\-\*\s>]+', '').Trim() }) }
if ($goal.Count -lt 2) { $F.Add('GOAL lines not found in research\CHARTER.md') }

function ScanText([string]$name, [string]$t) {
  foreach ($v in $envVals) { if ($t.IndexOf($v, [StringComparison]::Ordinal) -ge 0) { $script:hits.Add($name + ' : contains .env value (len=' + $v.Length + ')') } }
  foreach ($m in [regex]::Matches($t, $PX)) {
    $val = $m.Groups[3].Value
    if ($val -cmatch '^[A-Z][A-Z0-9_]{19,}$') { $script:nameSkip++; continue }
    if (($val -notmatch '^eyJ') -and ($val -match '^[A-Za-z_$][\w$]*(\.[A-Za-z_$][\w$]*)+$')) { $script:codeSkip++; continue }
    $ln = [regex]::Matches($t.Substring(0, $m.Index), "`n").Count + 1
    $script:hits.Add($name + ':' + $ln + ' : ' + $m.Groups[1].Value + '=' + $val.Substring(0, [Math]::Min(4, $val.Length)) + '***(len=' + $val.Length + ')')
  }
}

try {
  if (-not (Test-Path (Join-Path $pub '.git'))) { throw ('mirror .git missing: ' + $pub) }
  $remote = "$(& git -C $pub remote get-url origin 2>&1)".Trim()
  if ($remote -notmatch 'hoonoh57/mom-trader(\.git)?$') { throw ('unexpected mirror remote: ' + $remote) }
  if (-not (Test-Path $allowF)) { throw ('allowlist missing: ' + $allowF) }
  $rules = @()
  foreach ($ln in [IO.File]::ReadAllLines($allowF)) {
    $t = $ln.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
    $pp = $t.Split([char[]]@('|'), 2)
    $rx = ''; if ($pp.Count -gt 1) { $rx = $pp[1].Trim() }
    $rules += [pscustomobject]@{ p = $pp[0].Trim().TrimEnd('\'); rx = $rx; dir = ($pp.Count -gt 1) }
  }
  $sel = @{}
  foreach ($r in $rules) {
    $abs = Join-Path $root $r.p
    if ($r.dir) {
      if (-not (Test-Path $abs -PathType Container)) { $L.Add('[skip] no dir ' + $r.p); continue }
      foreach ($fi in (Get-ChildItem $abs -Recurse -File -Force)) {
        if ($r.rx -and ($fi.Name -notmatch $r.rx)) { continue }
        $sel[$fi.FullName.Substring($root.Length + 1)] = $fi
      }
    } else {
      if (Test-Path $abs -PathType Leaf) { $sel[$r.p] = Get-Item $abs } else { $L.Add('[skip] no file ' + $r.p) }
    }
  }
  foreach ($k in ($sel.Keys | Sort-Object)) {
    if ($k -match $HX) { $nHx++; continue }
    if ($k -ieq 'out\FOR_OPUS.txt') { continue }
    $fi = $sel[$k]
    if ($fi.Length -gt ($MaxKB * 1KB)) { $big.Add($k + ' ' + $fi.Length); continue }
    $keep.Add([pscustomobject]@{ rel = $k; full = $fi.FullName; len = $fi.Length })
  }

  $envVals = @()
  if (-not (Test-Path $EnvPath)) { throw ('env file missing, secret scan impossible: ' + $EnvPath) }
  foreach ($ln in [IO.File]::ReadAllLines($EnvPath)) {
    if ($ln -match '^\s*(export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*)$') {
      $v = $Matches[2].Trim().Trim('"').Trim("'"); if ($v.Length -ge 8) { $envVals += $v }
    }
  }
  foreach ($k in $keep) { if ($k.rel -match $TXT) { $scanned++; ScanText $k.rel ([IO.File]::ReadAllText($k.full, $enc)) } }
  ScanText 'out\FOR_OPUS.txt' $task
  $L.Add('env secret values checked: ' + $envVals.Count)
  $L.Add('secret scan: ' + $hits.Count + ' hits / ' + $scanned + ' text files, env-name skipped: ' + $nameSkip + ', code-ref skipped: ' + $codeSkip)
  if ($hits.Count -gt 0) { foreach ($h in $hits) { $F.Add('[secret] ' + $h) }; throw 'secret scan hit - mirror untouched, nothing committed' }

  foreach ($pr in $PAIRS) {
    $a = Join-Path $root $pr[0]; $b = Join-Path $root $pr[1]
    if ((Test-Path $a) -and (Test-Path $b)) {
      $ha = (Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash.ToLower(); $hb = (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash.ToLower()
      $L.Add('[engine] ' + $pr[0] + ' ' + $ha.Substring(0, 12) + $(if ($ha -eq $hb) { ' == ' } else { ' != ' }) + $pr[1])
    }
  }

  if ($mode -eq 'preview') { $L.Add('[preview] mirror not modified') }
  else {
    if ((Split-Path $pub -Leaf) -ne 'mom-trader-pub') { throw 'mirror path guard' }
    Get-ChildItem -LiteralPath $pub -Force | Where-Object { $_.Name -ne '.git' } | Remove-Item -Recurse -Force
    foreach ($k in $keep) {
      $dst = Join-Path $pub $k.rel; $dd = Split-Path $dst -Parent
      if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
      Copy-Item -LiteralPath $k.full -Destination $dst -Force
    }
    $od = Join-Path $pub 'out'; if (-not (Test-Path $od)) { New-Item -ItemType Directory -Force -Path $od | Out-Null }
    [IO.File]::WriteAllText((Join-Path $od 'FOR_OPUS.txt'), $task + "`r`n", $enc)
    [IO.File]::WriteAllText((Join-Path $pub '.gitattributes'), "* -text`n", $enc)
    $IX = New-Object System.Collections.Generic.List[string]
    $IX.Add('# PUB_INDEX ' + $VER + ' source=' + $root + ' time=' + (Get-Date -Format s) + ' files=' + ($keep.Count + 1))
    $IX.Add('# sha256_12  bytes  lines  path')
    $all = @($keep | ForEach-Object { $_.rel }) + @('out\FOR_OPUS.txt')
    foreach ($rel in ($all | Sort-Object)) {
      $p = Join-Path $pub $rel; $fi = Get-Item -LiteralPath $p
      $hs = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower().Substring(0, 12)
      $lc = '-'
      if ($rel -match $TXT) { $t = [IO.File]::ReadAllText($p); $n = $t.Length - $t.Replace("`n", '').Length; if ($t.Length -gt 0 -and -not $t.EndsWith("`n")) { $n++ }; $lc = [string]$n }
      $IX.Add($hs + '  ' + $fi.Length + '  ' + $lc + '  ' + ($rel -replace '\\', '/'))
    }
    [IO.File]::WriteAllLines((Join-Path $pub 'PUB_INDEX.txt'), $IX, $enc)

    $cur = "$(& git -C $pub config user.email 2>&1)".Trim()
    if ($Email) { & git -C $pub config user.email $Email 2>&1 | Out-Null; $cur = $Email }
    $nm = "$(& git -C $pub config user.name 2>&1)".Trim(); if (-not $nm) { & git -C $pub config user.name 'hoonoh57' 2>&1 | Out-Null }
    $L.Add('user.email=' + $cur)
    & git -C $pub add -A 2>&1 | Out-Null
    $st = @(& git -C $pub status --porcelain 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ })
    $L.Add('changes: ' + $st.Count)
    $st | Select-Object -First 80 | ForEach-Object { $L.Add('  ' + $_) }
    if ($st.Count -gt 80) { $L.Add('  ... +' + ($st.Count - 80) + ' more (see PUB_INDEX.txt)') }
    if ($st.Count -gt 0) {
      if ($cur -notmatch 'users\.noreply\.github\.com$') { throw ('user.email is not GitHub noreply: ' + $cur) }
      if (-not $Message) { $Message = 'sync ' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
      $co = @(& git -C $pub commit -q -m $Message 2>&1 | ForEach-Object { "$_" })
      if ($LASTEXITCODE -ne 0) { throw ('commit failed: ' + ($co -join ' | ')) }
      $L.Add('commit: ' + $Message)
    } else { $L.Add('commit: nothing to commit') }
    if ($Push) {
      $po = @(& git -C $pub push -u origin main 2>&1 | ForEach-Object { "$_" })
      $ec = $LASTEXITCODE
      $po | ForEach-Object { $L.Add('push: ' + $_) }
      if ($ec -ne 0) { throw 'push failed' }
    }
    $head = "$(& git -C $pub rev-parse HEAD 2>&1)".Trim()
  }
} catch { $F.Add('error: ' + $_.Exception.Message) }

$ok = ($F.Count -eq 0)
$H = New-Object System.Collections.Generic.List[string]
$goal | ForEach-Object { $H.Add($_) }
$H.Add('=== PUB sync ' + $VER + ' mode=' + $mode + ' result=' + $(if ($ok) { 'PASS' } else { 'FAIL' }) + ' time=' + (Get-Date -Format s) + ' ===')
$H.Add('files: ' + $keep.Count + ' (+out/FOR_OPUS.txt), ' + [Math]::Round((($keep | Measure-Object len -Sum).Sum) / 1KB, 1) + ' KB, hard-excluded: ' + $nHx + ', over ' + $MaxKB + 'KB: ' + $big.Count)
$big | ForEach-Object { $H.Add('  [big-skip] ' + $_) }
$L | ForEach-Object { $H.Add($_) }
$F | ForEach-Object { $H.Add('[FAIL] ' + $_) }
if ($head -match '^[0-9a-f]{40}$') {
  $H.Add('HEAD=' + $head)
  $H.Add('RAW=https://raw.githubusercontent.com/hoonoh57/mom-trader/' + $head + '/')
  $H.Add('TASK=https://raw.githubusercontent.com/hoonoh57/mom-trader/' + $head + '/out/FOR_OPUS.txt')
}
$H.Add('=== PUB end ===')
$out = ($H -join "`r`n") + "`r`n"
if ($task) { $out += "`r`n" + $task + "`r`n" }
[IO.File]::WriteAllText($opus, $out, $enc)
Write-Host ($(if ($ok) { 'PASS' } else { 'FAIL' }) + ' PUB ' + $VER + ' -> ' + $opus + $(if ($head) { '  HEAD=' + $head } else { '' }))