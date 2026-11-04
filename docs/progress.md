# mom-trader progress

Each step: what was built, how it was verified, what remains. Result file: out/FOR_OPUS.txt

| step | date | built | verified | remaining |
|---|---|---|---|---|
| S0 | 2026-11-04 | tools/ui/report.cjs, tools/ui/probe.cjs, setup/29_probe.ps1 | selftest 5/5, engine hashes v1/risk1/v3 match | - |
| S1 | 2026-11-04 | tools/ui/engines.cjs, server.cjs, s1.cjs, ui/index.html, setup/30_server.ps1 | 21 checks: 7 hashes, tamper reject (byte/params/missing), server status/static/traversal | browser screenshot via -Serve |

- 20261104-155203 S2 fetch-1.0 PASS: roundtrip ticks 10/10, daily 8/8 | tick parity 6/10 | daily parity 8/8

- 20261104-161107 S3 archive-1.0 run PASS: window 20260925~20261103 today=20261104 stockDays=1382 codes=735 days=25 alreadySaved=6 knownSkip=0 | parity MATCH (pages=2 end=warmup range=20261029~20261104) | run codes=5/734 pages=9 saved=3 warmShort=1 expired=8 noBars=0 trunc=0 err=0 elapsed=0.2m avg=2.0s/code remainingCodes=729 estRemaining=24m

- 20261104-163345 S3 archive-1.0 run PASS: window 20260925~20261103 today=20261104 stockDays=1382 codes=735 days=25 alreadySaved=9 knownSkip=8 | parity MATCH (pages=2 end=warmup range=20261029~20261104) | run codes=729/729 pages=1573 saved=1057 warmShort=749 expired=308 noBars=0 trunc=0 err=0 elapsed=22.0m avg=1.8s/code remainingCodes=0 estRemaining=0m

- S4-0 warmup (warmup-1.0) 20261104-201043: full=315 rec100=none rec99=400 report=E:\parent\projects\rea\projects\mom-trader\out\reports\S4.warmup_20261104-201043

- S4-1 period (period-1.0) 20261104-202920: eligible=476 S000=-295.86 C013=-318.87 report=E:\parent\projects\rea\projects\mom-trader\out\reports\S4.period_20261104-202920

- S4-2 target (target-1.0) 20261104-205949: eligible=476 top=none report=E:\parent\projects\rea\projects\mom-trader\out\reports\S4.target_20261104-205949
