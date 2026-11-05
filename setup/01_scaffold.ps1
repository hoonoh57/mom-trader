. (Join-Path $PSScriptRoot '_lib.ps1')
Assert-ScriptEncoding '한글' '01_scaffold.ps1'
Write-Info "01_scaffold: 프로젝트 골격 생성 → $Root"

foreach ($d in 'src\core', 'src\indicators', 'tests', 'logs') {
  New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null
}

$c = @'
{
  "name": "mom-trader",
  "version": "0.1.0",
  "private": true,
  "description": "조건검색 포착 종목 × 멀티차트 × Momentum 안심구간 자동매매 (kiwoom-desk 파생 프로젝트)",
  "type": "module",
  "engines": { "node": ">=18" },
  "scripts": {
    "typecheck": "tsc -p tsconfig.json --noEmit",
    "build": "tsc -p tsconfig.json",
    "test": "npm run build && node dist/tests/run.js"
  },
  "devDependencies": {
    "@types/node": "^20.14.0",
    "typescript": "^5.6.3"
  }
}
'@
Write-ProjectFile 'package.json' $c

$c = @'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "lib": ["ES2022"],
    "types": ["node"],
    "strict": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "forceConsistentCasingInFileNames": true,
    "skipLibCheck": true,
    "outDir": "dist",
    "rootDir": ".",
    "sourceMap": true,
    "newLine": "lf"
  },
  "include": ["src/**/*.ts", "tests/**/*.ts"]
}
'@
Write-ProjectFile 'tsconfig.json' $c

$c = @'
node_modules/
dist/
logs/
*.log
'@
Write-ProjectFile '.gitignore' $c

$c = @'
* text=auto eol=lf
*.ps1 text eol=crlf
'@
Write-ProjectFile '.gitattributes' $c

$c = @'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 2

[*.ps1]
charset = utf-8-bom
end_of_line = crlf
'@
Write-ProjectFile '.editorconfig' $c

$c = @'
# mom-trader

kiwoom-desk(표준 Workbench)의 파생 프로젝트.
조건검색 포착 종목을 멀티차트로 띄우고 120틱 Momentum(50) 안심구간 로직으로 자동매매한다.

## 단계
- [x] 1단계: 지표 4종 + reset/append/replace parity 테스트
  - Momentum(L) = C / C[L] × 100 (refPrice, spanSec, slope)
  - 강도 = (EMA(C,P1) − EMA(C,P2)) / C × 100, 강도시그널 = EMA(강도, P3)
  - 1억 신호 = (O+H+L+C)/4 × V ≥ 1억 (봉당)
  - 당일 누적거래대금 taamt, 강세패턴 = taamt > a
- [ ] 2단계: FeatureEngine + Scorer
- [ ] 3단계: SafeZoneStrategy (signal)
- [ ] 이후: 기록기, 슬롯 오케스트레이터, paper, broker

## 명령
- npm test         : 빌드 + 테스트
- npm run typecheck: 타입 검사
- setup\08_verify.ps1 : 전체 검증 (인코딩/파일/타입/테스트)

## 인코딩 규칙
- 소스(.ts/.json/.md): UTF-8 (BOM 없음), LF
- setup\*.ps1: UTF-8 with BOM, CRLF (Windows PowerShell 5.1 한글 호환)
'@
Write-ProjectFile 'README.md' $c

Complete-Step '01_scaffold'
