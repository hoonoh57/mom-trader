#requires -Version 5.1
param([string]$Root = 'E:\parent\projects\rea\projects\mom-trader')
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM'; exit 1 }
$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "[성공] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[실패] $m" -ForegroundColor Red }
$enc = New-Object System.Text.UTF8Encoding($false)

function Patch([string]$rel, [object[]]$pairs, [string]$doneMark) {
  $p = Join-Path $Root $rel
  if (-not (Test-Path $p)) { Fail "파일 없음: $p (20_risk.ps1 먼저 실행)"; exit 1 }
  $t = [IO.File]::ReadAllText($p, $enc)
  if ($t.Contains($doneMark)) { Write-Host "[정보] 이미 수정됨: $rel"; return }
  foreach ($pr in $pairs) {
    $n = [regex]::Matches($t, [regex]::Escape($pr[0])).Count
    if ($n -ne 1) { Fail "$rel : 기준 문자열 $n 개 발견 (1개여야 함) -> $($pr[0])"; exit 1 }
    $t = $t.Replace($pr[0], $pr[1])
  }
  Copy-Item $p "$p.bak20a" -Force
  [IO.File]::WriteAllText($p, $t, $enc)
  if ([IO.File]::ReadAllText($p, $enc) -ne $t) { Fail "재읽기 불일치: $rel"; exit 1 }
  Ok "$rel 수정 ($($pairs.Count)곳, 백업 .bak20a)"
}

Write-Host '=== 리스크 모듈 수정: 일일손익 기준값(base) ==='

Patch 'tools\sz-risk.cjs' @(
  ,@("const VERSION = 'risk-1';", "const VERSION = 'risk-1.1';")
  ,@('st.sold.clear(); st.consec = 0; st.pauseUntil = -1; st.halt = null;',
     'st.sold.clear(); st.consec = 0; st.pauseUntil = -1; st.halt = null; for (const v of st.open.values()) v.base = v.ret;')
  ,@('for (const v of st.open.values()) e += v.w * v.ret; return e;',
     'for (const v of st.open.values()) e += v.w * (v.ret - v.base); return e;')
  ,@('st.open.set(q.code, { w: q.w != null ? q.w : 1, ret: 0 });',
     'st.open.set(q.code, { w: q.w != null ? q.w : 1, ret: 0, base: 0 });')
  ,@('st.realized += wPart * retPct;',
     'st.realized += wPart * (retPct - v.base);')
  ,@('st.realized += v.w * q.retPct;',
     'st.realized += v.w * (q.retPct - v.base);')
) 'v.base'

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
$anchor = "t('daily loss flatten', () => {"
Patch 'tools\sz-risk-selftest.cjs' @(
  ,@($anchor, ($newTest -replace "`r`n", "`n") + $anchor)
) 'daily loss baseline at day roll'

$ErrorActionPreference = 'Continue'
$out = & node (Join-Path $Root 'tools\sz-risk-selftest.cjs') (Join-Path $Root 'strategies\risk') 2>&1
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$out | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0) { Fail "자가검증 실패 (exit $code) - FAIL 줄을 붙여 주세요. 복구: .bak20a"; exit 1 }
Ok '리스크 자가검증 통과'

$ErrorActionPreference = 'Continue'
$pr = & node (Join-Path $Root 'tools\sz-probe.cjs') $Root 2>&1
$ErrorActionPreference = 'Stop'
$pr | ForEach-Object { Write-Host "  $_" }
Ok '완료'
