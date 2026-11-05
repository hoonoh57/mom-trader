#requires -Version 5.1
# mom-trader : 틱 CSV -> 지표/필터 계산 -> 독립 HTML 차트 (영웅문 대조용)
param(
  [string]$Root = 'E:\parent\projects\rea\projects\mom-trader',
  [string]$Match = '_AL_',
  [int]$MomLen = 50, [double]$SafeTh = 100,
  [int]$P1 = 7, [int]$P2 = 14, [int]$P3 = 5,
  [double]$StrongA = 1000000000,
  [ValidateSet('abs','rel')][string]$BigMode = 'abs',
  [double]$BigTh = 50000000,
  [switch]$BigInclusive,
  [int]$RelWin = 20, [double]$RelK = 3,
  [int]$ArmSkip = 1,
  [ValidateSet('ema','sma')][string]$MaType = 'ema', [int]$MaLen = 200,
  [int]$StLen = 14, [double]$StMult = 1.5, [ValidateSet('rma','sma')][string]$StAtr = 'rma',
  [double]$TickAbs = 0, [double]$TickK = 1.0,
  [ValidateSet('off','block','pullback')][string]$LimMode = 'pullback',
  [double]$LimPct = 29, [double]$PbPct = 5,
  [double]$DispMax = 108, [string]$DispUntil = '1000',
  [switch]$NoEmaFilter, [switch]$NoTickFilter, [switch]$NoDispFilter,
  [string]$OpenMults = '1.03,1.097,1.15',
  [switch]$NoOpen
)
if ('한글'.Length -ne 2) { Write-Host 'ENCODING ERROR: save this .ps1 as UTF-8 with BOM' -ForegroundColor Red; exit 1 }
$ErrorActionPreference = 'Stop'
function Ok([string]$m)  { Write-Host "[성공] $m" -ForegroundColor Green }
function Bad([string]$m) { Write-Host "[실패] $m" -ForegroundColor Red }
if ($DispUntil -ne 'all' -and $DispUntil -notmatch '^\d{4}$') { Bad "-DispUntil 은 HHMM 또는 all (입력: $DispUntil)"; exit 1 }

$tickDir = Join-Path $Root 'data\ticks'; $dailyDir = Join-Path $Root 'data\daily'
$outDir = Join-Path $Root 'data\chart'; $toolDir = Join-Path $Root 'tools'
New-Item -ItemType Directory -Force -Path $outDir, $toolDir | Out-Null
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Bad 'node 를 찾을 수 없음'; exit 1 }

$js = @'
import fs from 'node:fs';
import path from 'node:path';

const A = Object.fromEntries(process.argv.slice(2).map(s => { const i = s.indexOf('='); return [s.slice(0, i), s.slice(i + 1)]; }));
const num = k => { const v = Number(A[k]); if (!Number.isFinite(v)) throw new Error('bad param ' + k + '=' + A[k]); return v; };
const toSec = t => (+t.slice(0, 2)) * 3600 + (+t.slice(2, 4)) * 60 + (+t.slice(4, 6));
const P = {
  p1: num('p1'), p2: num('p2'), p3: num('p3'), momLen: num('momLen'), safeTh: num('safeTh'), strongA: num('strongA'),
  bigMode: A.bigMode, bigTh: num('bigTh'), bigIncl: A.bigIncl === '1', relWin: num('relWin'), relK: num('relK'), armSkip: num('armSkip'),
  maType: A.maType, maLen: num('maLen'), stLen: num('stLen'), stMult: num('stMult'), stAtr: A.stAtr,
  tickAbs: num('tickAbs'), tickK: num('tickK'), useEma: A.useEma === '1', useTick: A.useTick === '1', useDisp: A.useDisp === '1',
  limMode: A.limMode, limPct: num('limPct'), pbPct: num('pbPct'), dispMax: num('dispMax'),
  dispUntil: A.dispUntil === 'all' ? -1 : toSec(A.dispUntil.padEnd(6, '0')),
  openMults: String(A.openMults || '').split(',').map(Number).filter(x => x > 0)
};
P.maName = P.maType.toUpperCase() + P.maLen;

const TPL = String.raw`<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>__TITLE__</title>
<style>
html,body{margin:0;background:#111;color:#ddd;font:12px Consolas,'Malgun Gothic',monospace;overflow:hidden}
#bar{height:30px;display:flex;align-items:center;gap:8px;padding:0 8px;background:#1b1b1b;white-space:nowrap;overflow:hidden}
button{background:#333;color:#ddd;border:1px solid #555;padding:2px 8px;cursor:pointer}
#tip{position:absolute;left:8px;top:36px;background:rgba(0,0,0,.8);padding:4px 6px;white-space:pre;pointer-events:none;display:none}
canvas{display:block;cursor:crosshair}
.lg{color:#999}
</style></head><body>
<div id="bar"><b id="ttl"></b><button id="fit">당일</button><button id="all">전체</button><span id="info"></span>
<span class="lg">| <span style="color:#37e05a">●</span>1억 <span style="color:#ffd400">▲</span>ARM <span style="color:#ff4dff">▲</span>진입 <span style="color:#ff3030">×</span>상한가 <span style="color:#b070ff">×</span>이격 <span style="color:#aaa">×</span>EMA <span style="color:#ff9a30">×</span>체결</span></div>
<canvas id="c"></canvas><div id="tip"></div>
<script>
var D=__DATA__;
var B=D.bars,N=B.length,cv=document.getElementById('c'),g=cv.getContext('2d'),tip=document.getElementById('tip');
var T=0,DT=1,O=2,HI=3,LO=4,C=5,REF=6,MOM=7,NN=8,SG=9,AMT=10,TAA=11,FL=12,MA=13,ST=14,SD=15,R1=16,R5=17,DO=18,DSP=19;
var AX=78,XH=18,W=0,H=0,start=0,count=N,mx=-1,my=-1,drag=null,UP='#e34a4a',DN='#3f7fd6';
document.getElementById('ttl').textContent=D.title;document.getElementById('info').textContent=D.info;
function has(i,f){return (B[i][FL]&f)!==0;}
function sec(t){return (+t.slice(0,2))*3600+(+t.slice(2,4))*60+(+t.slice(4,6));}
var tStart=0;for(var k=0;k<N;k++){if(has(k,16)){tStart=k;break;}}
function clampView(){count=Math.max(20,Math.min(N,count));start=Math.max(0,Math.min(N-count,start));}
function fitDay(){start=tStart;count=N-tStart;draw();}
function fitAll(){start=0;count=N;draw();}
function resize(){var r=window.devicePixelRatio||1;W=window.innerWidth;H=window.innerHeight-30;cv.width=W*r;cv.height=H*r;cv.style.width=W+'px';cv.style.height=H+'px';g.setTransform(r,0,0,r,0,0);draw();}
function fmt(v,d){if(v===null||v===undefined)return '-';return Number(v).toLocaleString('en-US',{maximumFractionDigits:d});}
function hm(t){return t.slice(0,2)+':'+t.slice(2,4);}
function hms(t){return hm(t)+':'+t.slice(4,6);}
function range(cols,i0,i1,pad){var lo=Infinity,hi=-Infinity;for(var i=i0;i<i1;i++)for(var j=0;j<cols.length;j++){var v=B[i][cols[j]];if(v===null)continue;if(v<lo)lo=v;if(v>hi)hi=v;}if(lo===Infinity){lo=0;hi=1;}if(hi===lo){hi+=1;lo-=1;}var p=(hi-lo)*pad;return [lo-p,hi+p];}
function mk(top,h,lo,hi){return function(v){return top+h-(v-lo)/(hi-lo)*h;};}
function axis(top,h,lo,hi,d,name){g.strokeStyle='#262626';g.fillStyle='#888';g.textAlign='left';for(var k=0;k<=4;k++){var v=lo+(hi-lo)*k/4,y=top+h-h*k/4;g.beginPath();g.moveTo(0,y);g.lineTo(W-AX,y);g.stroke();g.fillText(fmt(v,d),W-AX+4,Math.min(top+h-2,Math.max(top+10,y+4)));}g.strokeStyle='#444';g.strokeRect(0,top,W-AX,h);g.fillStyle='#bbb';g.fillText(name,4,top+12);}
function hline(y,c){g.strokeStyle=c;g.setLineDash([4,3]);g.beginPath();g.moveTo(0,y);g.lineTo(W-AX,y);g.stroke();g.setLineDash([]);}
function clip(top,h){g.save();g.beginPath();g.rect(0,top,W-AX,h);g.clip();}
function series(i0,i1,get,X,Y,c,w,dash,brk){g.strokeStyle=c;g.lineWidth=w||1.2;if(dash)g.setLineDash(dash);g.beginPath();var pen=false;for(var i=i0;i<i1;i++){var v=get(i);if(v===null||v===undefined||!isFinite(v)){pen=false;continue;}if(brk&&pen&&B[i][DT]!==B[i-1][DT])pen=false;var x=X(i),y=Y(v);if(pen)g.lineTo(x,y);else{g.moveTo(x,y);pen=true;}}g.stroke();g.setLineDash([]);g.lineWidth=1;}
function col(c){return function(i){return B[i][c];};}
function tri(x,y,c,s){s=s||5;g.fillStyle=c;g.beginPath();g.moveTo(x,y);g.lineTo(x-s,y+s*1.6);g.lineTo(x+s,y+s*1.6);g.closePath();g.fill();}
function cross(x,y,c){g.strokeStyle=c;g.lineWidth=2;g.beginPath();g.moveTo(x-4,y-4);g.lineTo(x+4,y+4);g.moveTo(x+4,y-4);g.lineTo(x-4,y+4);g.stroke();g.lineWidth=1;}
function dot(x,y,c){g.fillStyle=c;g.beginPath();g.arc(x,y,2.5,0,6.283);g.fill();}
function draw(){
 if(!W)return;clampView();g.clearRect(0,0,W,H);
 var i0=start,i1=Math.min(N,start+count),pw=W-AX,bw=pw/count,ph=H-XH,cw=Math.max(1,bw*0.7),i,x,b,k;
 var X=function(j){return (j-start+0.5)*bw;};
 var hs=[0.40,0.13,0.15,0.16,0.16],tops=[],hh=[],acc=0;for(k=0;k<hs.length;k++){tops.push(acc);hh.push(ph*hs[k]);acc+=ph*hs[k];}
 var pr=range([HI,LO,MA,ST],i0,i1,0.04),Yp=mk(tops[0],hh[0],pr[0],pr[1]);
 var mr=range([MOM],i0,i1,0.08);if(mr[0]>D.p.safeTh-1)mr[0]=D.p.safeTh-1;if(mr[1]<D.p.safeTh+1)mr[1]=D.p.safeTh+1;var Ym=mk(tops[1],hh[1],mr[0],mr[1]);
 var nr=range([NN,SG],i0,i1,0.08),Yn=mk(tops[2],hh[2],nr[0],nr[1]);
 var tr=[0,range([R1,R5],i0,i1,0.05)[1]],Yt=mk(tops[3],hh[3],tr[0],tr[1]);
 var ar=[0,range([AMT],i0,i1,0.05)[1]],Ya=mk(tops[4],hh[4],ar[0],ar[1]);
 g.fillStyle='rgba(40,200,90,0.10)';
 for(i=i0;i<i1;i++){if(has(i,1)){x=X(i)-bw/2;g.fillRect(x,tops[0],bw+0.5,hh[0]);g.fillRect(x,tops[1],bw+0.5,hh[1]);}}
 g.fillStyle='rgba(255,48,48,0.35)';
 for(i=i0;i<i1;i++){if(has(i,4096)){g.fillRect(X(i)-bw/2,tops[0],bw+0.5,4);}}
 axis(tops[0],hh[0],pr[0],pr[1],0,'가격 / '+D.p.maName+'(회색) / ST('+D.p.stLen+','+D.p.stMult+') / 시가배수선 / 이격상한(보라)');
 axis(tops[1],hh[1],mr[0],mr[1],2,'Mom('+D.p.momLen+')');
 axis(tops[2],hh[2],nr[0],nr[1],3,'강도(빨강) / 시그널(파랑) / 차이(막대)');
 axis(tops[3],hh[3],tr[0],tr[1],0,'1분 체결건수 (녹색=통과)  기준선=max('+D.p.tickAbs+', 5분평균x'+D.p.tickK+')');
 axis(tops[4],hh[4],ar[0],ar[1],0,'봉당 거래대금 (빨강=기준 초과)');
 g.fillStyle='#888';g.textAlign='center';var lastLx=-1e9;
 for(i=i0;i<i1;i++){x=X(i);if(i>0&&B[i][DT]!==B[i-1][DT]){g.strokeStyle='#888';g.setLineDash([2,4]);g.beginPath();g.moveTo(x-bw/2,0);g.lineTo(x-bw/2,ph);g.stroke();g.setLineDash([]);if(x-lastLx>40){g.fillStyle='#ccc';g.fillText(B[i][DT].slice(4),x,ph+13);g.fillStyle='#888';lastLx=x;}continue;}if(x-lastLx>90){g.fillText(hm(B[i][T]),x,ph+13);lastLx=x;}}
 clip(tops[0],hh[0]);
 for(k=0;k<D.p.openMults.length;k++){(function(m){series(i0,i1,function(i){return B[i][DO]*m;},X,Yp,'#2bd36b',1,[6,4],true);})(D.p.openMults[k]);}
 if(D.p.useDisp)series(i0,i1,function(i){if(B[i][MA]===null)return null;if(D.p.dispUntil>=0&&sec(B[i][T])>=D.p.dispUntil)return null;return B[i][MA]*D.p.dispMax/100;},X,Yp,'#b070ff',1.2,[3,3],true);
 series(i0,i1,col(REF),X,Yp,'#555',1,[2,3]);
 for(i=i0;i<i1;i++){b=B[i];x=X(i);g.strokeStyle=g.fillStyle=(b[C]>=b[O])?UP:DN;g.beginPath();g.moveTo(x,Yp(b[HI]));g.lineTo(x,Yp(b[LO]));g.stroke();var y1=Yp(Math.max(b[O],b[C])),y2=Yp(Math.min(b[O],b[C]));g.fillRect(x-cw/2,y1,cw,Math.max(1,y2-y1));}
 series(i0,i1,col(MA),X,Yp,'#d0d0d0',1.8);
 g.lineWidth=1.6;
 for(i=Math.max(i0,1);i<i1;i++){if(B[i][ST]===null||B[i-1][ST]===null||B[i][SD]!==B[i-1][SD])continue;g.strokeStyle=B[i][SD]>0?'#ffb000':'#00b7ff';g.beginPath();g.moveTo(X(i-1),Yp(B[i-1][ST]));g.lineTo(X(i),Yp(B[i][ST]));g.stroke();}
 g.lineWidth=1;
 for(i=i0;i<i1;i++){x=X(i);var yl=Yp(B[i][LO]),yh=Yp(B[i][HI]);if(has(i,2))dot(x,yl+5,'#37e05a');if(has(i,4))tri(x,yl+10,'#ffd400');if(has(i,8))tri(x,yl+20,'#ff4dff',6);
  if(has(i,2048))cross(x,yh-8,'#ff3030');if(has(i,1024))cross(x,yh-8,'#b070ff');if(has(i,32))cross(x,yh-8,'#aaaaaa');if(has(i,64))cross(x,yh-8,'#ff9a30');}
 g.restore();
 clip(tops[1],hh[1]);hline(Ym(D.p.safeTh),'#2bd36b');series(i0,i1,col(MOM),X,Ym,'#f0f0f0');g.restore();
 clip(tops[2],hh[2]);hline(Yn(0),'#888');
 for(i=i0;i<i1;i++){if(B[i][NN]===null||B[i][SG]===null)continue;var dv=B[i][NN]-B[i][SG],y0=Yn(0),yv=Yn(dv);g.fillStyle=dv>=0?'rgba(227,74,74,.45)':'rgba(63,127,214,.45)';g.fillRect(X(i)-cw/2,Math.min(y0,yv),cw,Math.max(1,Math.abs(yv-y0)));}
 series(i0,i1,col(NN),X,Yn,UP);series(i0,i1,col(SG),X,Yn,DN);g.restore();
 clip(tops[3],hh[3]);
 for(i=i0;i<i1;i++){g.fillStyle=has(i,128)?'#3fbf6f':'#555';var yt=Yt(B[i][R1]);g.fillRect(X(i)-cw/2,yt,cw,tops[3]+hh[3]-yt);}
 series(i0,i1,function(i){return Math.max(D.p.tickAbs,B[i][R5]*D.p.tickK);},X,Yt,'#ffa040',1.4,null,true);g.restore();
 clip(tops[4],hh[4]);
 for(i=i0;i<i1;i++){g.fillStyle=has(i,256)?UP:'#555';var ya=Ya(B[i][AMT]);g.fillRect(X(i)-cw/2,ya,cw,tops[4]+hh[4]-ya);}
 g.restore();
 if(mx>=0&&mx<pw&&my>=0&&my<ph){var ci=Math.min(i1-1,start+Math.floor(mx/bw));x=X(ci);g.strokeStyle='#666';g.beginPath();g.moveTo(x,0);g.lineTo(x,ph);g.moveTo(0,my);g.lineTo(pw,my);g.stroke();b=B[ci];
  tip.style.display='block';
  tip.textContent=b[DT]+' '+hms(b[T])+'  #'+ci+'\nO '+fmt(b[O],0)+'  H '+fmt(b[HI],0)+'  L '+fmt(b[LO],0)+'  C '+fmt(b[C],0)
   +'\n'+D.p.maName+' '+fmt(b[MA],0)+(has(ci,512)?' (종가 위)':' (종가 아래)')+'  이격 '+fmt(b[DSP],2)+'%  ST '+fmt(b[ST],0)+(b[SD]>0?' 상승':' 하락')
   +'\nC['+D.p.momLen+'] '+fmt(b[REF],0)+'  Mom '+fmt(b[MOM],2)+(has(ci,1)?' (안심)':'')
   +'\n강도 '+fmt(b[NN],4)+'  시그널 '+fmt(b[SG],4)
   +'\n체결/분 1분 '+fmt(b[R1],0)+'  5분평균 '+fmt(b[R5],0)+(has(ci,128)?' (통과)':' (미달)')
   +'\n봉대금 '+fmt(b[AMT],0)+'  누적 '+fmt(b[TAA],0)
   +(has(ci,4096)?'\n전일 상한가: 진입 대기':'')
   +(has(ci,2)?'\n1억신호':'')+(has(ci,4)?'\nARM':'')+(has(ci,8)?'\n진입(미리보기)':'')
   +(has(ci,2048)?'\n상한가 차단':'')+(has(ci,1024)?'\n이격 탈락':'')+(has(ci,32)?'\nEMA 탈락':'')+(has(ci,64)?'\n체결속도 탈락':'');
 }else tip.style.display='none';
}
cv.addEventListener('mousemove',function(e){mx=e.offsetX;my=e.offsetY;if(drag){start=drag.s-Math.round((e.offsetX-drag.x)/((W-AX)/count));}draw();});
cv.addEventListener('mouseleave',function(){mx=-1;drag=null;draw();});
cv.addEventListener('mousedown',function(e){drag={x:e.offsetX,s:start};});
window.addEventListener('mouseup',function(){drag=null;});
cv.addEventListener('wheel',function(e){e.preventDefault();var ci=start+e.offsetX/((W-AX)/count);count=Math.round(count*(e.deltaY>0?1.2:1/1.2));count=Math.max(20,Math.min(N,count));start=Math.round(ci-e.offsetX/((W-AX)/count));draw();},{passive:false});
document.getElementById('fit').onclick=fitDay;document.getElementById('all').onclick=fitAll;
window.addEventListener('resize',resize);
start=tStart;count=N-tStart;resize();
</script></body></html>`;

function ema(vals, p) { const a = 2 / (p + 1); let e = null; return vals.map(v => (e = e === null ? v : e + a * (v - e))); }
function sma(vals, p) { const out = []; let s = 0; for (let i = 0; i < vals.length; i++) { s += vals[i]; if (i >= p) s -= vals[i - p]; out.push(i >= p - 1 ? s / p : null); } return out; }
function median(a) { const s = a.slice().sort((x, y) => x - y), m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; }
const r = (v, d) => (v === null || !Number.isFinite(v)) ? null : Math.round(v * d) / d;

function supertrend(bars, len, mult, mode) {
  const n = bars.length, st = new Array(n).fill(null), dir = new Array(n).fill(0), trs = [];
  let atr = null, sumTr = 0, fu = null, fl = null, d = 1;
  for (let i = 0; i < n; i++) {
    const b = bars[i], pc = i > 0 ? bars[i - 1].c : null;
    const tr = pc === null ? b.h - b.l : Math.max(b.h - b.l, Math.abs(b.h - pc), Math.abs(b.l - pc));
    trs.push(tr);
    if (mode === 'sma') { sumTr += tr; if (i >= len) sumTr -= trs[i - len]; atr = i >= len - 1 ? sumTr / len : null; }
    else if (i < len) { sumTr += tr; atr = i === len - 1 ? sumTr / len : null; }
    else atr = (atr * (len - 1) + tr) / len;
    if (atr === null) continue;
    const hl2 = (b.h + b.l) / 2, ub = hl2 + mult * atr, lb = hl2 - mult * atr;
    if (fu === null) { fu = ub; fl = lb; d = b.c >= hl2 ? 1 : -1; }
    else {
      fu = (ub < fu || pc > fu) ? ub : fu;
      fl = (lb > fl || pc < fl) ? lb : fl;
      if (d === -1 && b.c > fu) d = 1; else if (d === 1 && b.c < fl) d = -1;
    }
    st[i] = d === 1 ? fl : fu; dir[i] = d;
  }
  return { st, dir };
}

function load(file) {
  const lines = fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const head = lines[0].split(',');
  const I = {};
  for (const k of ['date', 'time', 'open', 'high', 'low', 'close', 'volume', 'is_target']) {
    I[k] = head.indexOf(k); if (I[k] < 0) throw new Error('missing column: ' + k);
  }
  return lines.slice(1).map(l => { const c = l.split(',');
    return { date: c[I.date], time: c[I.time], o: +c[I.open], h: +c[I.high], l: +c[I.low], c: +c[I.close], v: +c[I.volume], target: c[I.is_target] === '1' }; });
}

function prevDayInfo(code, target) {
  const f = path.join(A.dailyDir, code + '.csv');
  if (!fs.existsSync(f)) return null;
  const lines = fs.readFileSync(f, 'utf8').replace(/^\uFEFF/, '').trim().split(/\r?\n/);
  const head = lines[0].split(','), di = head.indexOf('date'), ci = head.indexOf('close');
  if (di < 0 || ci < 0) throw new Error('daily csv columns: ' + head.join(','));
  const rows = lines.slice(1).map(l => l.split(',')).map(c => ({ date: c[di], c: +c[ci] })).filter(x => x.c > 0 && x.date < target);
  if (rows.length < 2) return null;
  const p = rows[rows.length - 1], pp = rows[rows.length - 2], chg = (p.c / pp.c - 1) * 100;
  return { date: p.date, chg, limUp: chg >= P.limPct };
}

function compute(bars, scope, limUp) {
  const cl = bars.map(b => b.c), e1 = ema(cl, P.p1), e2 = ema(cl, P.p2);
  const n = bars.map((b, i) => (e1[i] - e2[i]) / b.c * 100), sig = ema(n, P.p3);
  const ma = P.maType === 'sma' ? sma(cl, P.maLen) : ema(cl, P.maLen);
  const { st, dir } = supertrend(bars, P.stLen, P.stMult, P.stAtr);
  const secs = bars.map(b => toSec(b.time));
  const rows = [], amts = [], entries = [];
  let day = null, taamt = 0, sbi = 0, armed = false, dayOpen = 0, dayStart = 0, w1 = 0, w5 = 0, firstTarget = -1, dayHigh = 0, pbOk = false, pbTime = null;
  const S = { tgt: 0, safe: 0, big: 0, arm: 0, entry: 0, bLim: 0, bDisp: 0, bEma: 0, bTick: 0, taamt: 0 };
  for (let i = 0; i < bars.length; i++) {
    const b = bars[i], newDay = b.date !== day, sec = secs[i];
    if (newDay) { day = b.date; taamt = 0; sbi = 0; armed = false; dayOpen = b.o; dayStart = sec; w1 = i; w5 = i; dayHigh = b.h; pbOk = false; }
    else { sbi++; dayHigh = Math.max(dayHigh, b.h); }
    if (!pbOk && (dayHigh - b.l) / dayHigh * 100 >= P.pbPct) { pbOk = true; if (b.target) pbTime = b.time; }
    while (secs[w1] <= sec - 60) w1++;
    while (secs[w5] <= sec - 300) w5++;
    const tr1 = (i - w1 + 1) * scope;
    const span5 = Math.min(300, Math.max(60, sec - dayStart));
    const tr5 = (i - w5 + 1) * scope / (span5 / 60);
    const tickOk = tr1 >= P.tickAbs && tr1 >= tr5 * P.tickK;
    const amt = (b.o + b.h + b.l + b.c) / 4 * b.v; taamt += amt;
    const ref = i >= P.momLen ? bars[i - P.momLen].c : null;
    const mom = ref ? b.c / ref * 100 : null;
    const safe = mom !== null && mom >= P.safeTh;
    const th = P.bigMode === 'rel' ? (amts.length >= P.relWin ? median(amts.slice(-P.relWin)) * P.relK : Infinity) : P.bigTh;
    amts.push(amt);
    const amtHit = P.bigIncl ? amt >= th : amt > th;
    const bigSig = amtHit && b.c > b.o && st[i] !== null && b.c > st[i] && mom !== null && mom > P.safeTh;
    const strong = taamt > P.strongA;
    const crossUp = !newDay && n[i - 1] <= 0 && n[i] > 0;
    const emaOk = ma[i] !== null && b.c > ma[i];
    const disp = ma[i] !== null ? b.c / ma[i] * 100 : null;
    const dispBlock = disp !== null && disp > P.dispMax && (P.dispUntil < 0 || sec < P.dispUntil);
    const limBlock = b.target && limUp && (P.limMode === 'block' || (P.limMode === 'pullback' && !pbOk));
    let arm = false, entry = false, bLim = false, bDisp = false, bEma = false, bTick = false;
    if (armed && !safe) armed = false;
    if (!armed) { if (safe && strong && crossUp && sbi >= P.armSkip) { armed = true; arm = true; } }
    else if (bigSig) {
      if (limBlock) bLim = true;
      else if (P.useDisp && dispBlock) bDisp = true;
      else if (P.useEma && !emaOk) bEma = true;
      else if (P.useTick && !tickOk) bTick = true;
      else { entry = true; armed = false; }
    }
    const flags = (safe ? 1 : 0) | (bigSig ? 2 : 0) | (arm ? 4 : 0) | (entry ? 8 : 0) | (b.target ? 16 : 0)
                | (bEma ? 32 : 0) | (bTick ? 64 : 0) | (tickOk ? 128 : 0) | (amtHit ? 256 : 0) | (emaOk ? 512 : 0)
                | (bDisp ? 1024 : 0) | (bLim ? 2048 : 0) | (limBlock ? 4096 : 0);
    if (b.target) {
      if (firstTarget < 0) firstTarget = i;
      S.tgt++; if (safe) S.safe++; if (bigSig) S.big++; if (arm) S.arm++;
      if (bLim) S.bLim++; if (bDisp) S.bDisp++; if (bEma) S.bEma++; if (bTick) S.bTick++;
      if (entry) { S.entry++; entries.push(b.time); }
      S.taamt = taamt;
    }
    rows.push([b.time, b.date, b.o, b.h, b.l, b.c, ref, r(mom, 1e4), r(n[i], 1e6), r(sig[i], 1e6), Math.round(amt), Math.round(taamt),
               flags, r(ma[i], 100), r(st[i], 100), dir[i], tr1, r(tr5, 10), dayOpen, r(disp, 100)]);
  }
  return { rows, S, entries, warm: firstTarget, pbTime };
}

const files = fs.readdirSync(A.tickDir).filter(f => f.endsWith('.csv') && (!A.match || f.includes(A.match)));
if (!files.length) { console.log('[FAIL] no csv in ' + A.tickDir + ' matching "' + A.match + '"'); process.exit(1); }
let failed = 0; const links = [];
const hms = t => t.slice(0, 2) + ':' + t.slice(2, 4) + ':' + t.slice(4, 6);
for (const f of files) {
  try {
    const m = f.match(/_(\d+)t_/), scope = m ? +m[1] : 120;
    const code = f.slice(0, 6);
    const bars = load(path.join(A.tickDir, f));
    const tb = bars.find(b => b.target);
    if (!tb) throw new Error('no target-day bars');
    const pd = prevDayInfo(code, tb.date);
    const limUp = !!(pd && pd.limUp) && P.limMode !== 'off';
    const { rows, S, entries, warm, pbTime } = compute(bars, scope, limUp);
    if (rows.some(x => x[8] === null || x[9] === null)) throw new Error('non-finite n/sig');
    if (rows.filter(x => x[14] !== null).length === 0) throw new Error('supertrend never computed');
    const title = f.replace(/\.csv$/, '');
    const pdStr = pd ? `전일 ${pd.chg >= 0 ? '+' : ''}${pd.chg.toFixed(1)}%${pd.limUp ? ' 상한가(' + P.limMode + (P.limMode === 'pullback' ? ', 해제 ' + (pbTime ? hms(pbTime) : '없음') : '') + ')' : ''}` : '전일 미확인';
    const info = `${pdStr} | 안심 ${(S.safe / S.tgt * 100).toFixed(1)}% | 1억 ${S.big} | ARM ${S.arm} | 진입 ${S.entry} | 상한가 ${S.bLim} 이격 ${S.bDisp} EMA ${S.bEma} 체결 ${S.bTick} | 누적 ${(S.taamt / 1e8).toFixed(1)}억`;
    const p = { momLen: P.momLen, safeTh: P.safeTh, maName: P.maName, stLen: P.stLen, stMult: P.stMult, tickK: P.tickK, tickAbs: P.tickAbs,
                openMults: P.openMults, useDisp: P.useDisp, dispMax: P.dispMax, dispUntil: P.dispUntil };
    const json = JSON.stringify({ title, info, p, bars: rows });
    if (JSON.parse(json).bars.length !== bars.length) throw new Error('json bar count mismatch');
    const html = TPL.split('__DATA__').join(json).split('__TITLE__').join(title);
    const out = path.join(A.outDir, title + '.html');
    fs.writeFileSync(out, html, 'utf8');
    if (fs.readFileSync(out, 'utf8') !== html) throw new Error('re-read mismatch');
    console.log(`[OK] ${title} (${scope}t): ${info}`);
    console.log(`     진입: ${entries.slice(0, 12).map(hms).join(', ') || '-'}${entries.length > 12 ? ' ...' : ''}`);
    if (!pd) console.log(`[WARN] ${title}: 일봉 없음 -> 상한가 필터 미적용 (12_fetch_daily.ps1 -Codes "${code}" 실행)`);
    if (P.maType === 'ema' && warm < P.maLen * 3) console.log(`[WARN] ${title}: 이전 봉 ${warm}개 < ${P.maLen * 3} -> ${P.maName}/이격 초반값이 HTS와 다를 수 있음`);
    links.push(`<li><a href="${title}.html">${title}</a> - ${info}</li>`);
  } catch (e) { failed++; console.log(`[FAIL] ${f}: ${e.message}`); }
}
fs.writeFileSync(path.join(A.outDir, 'index.html'),
  `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>mom-trader charts</title><style>a{color:#6cf}</style></head>` +
  `<body style="background:#111;color:#ddd;font:14px 'Malgun Gothic'"><h3>mom-trader 틱 차트</h3><ul>${links.join('')}</ul></body></html>`, 'utf8');
process.exit(failed ? 1 : 0);
'@

$utf8 = New-Object Text.UTF8Encoding($false)
$jsPath = Join-Path $toolDir 'chart_build.mjs'
[IO.File]::WriteAllText($jsPath, $js, $utf8)
if ([IO.File]::ReadAllText($jsPath, $utf8) -ne $js) { Bad "파일 재읽기 불일치: $jsPath"; exit 1 }

$useEma  = if ($NoEmaFilter)  { 0 } else { 1 }
$useTick = if ($NoTickFilter) { 0 } else { 1 }
$useDisp = if ($NoDispFilter) { 0 } else { 1 }
$incl    = if ($BigInclusive) { 1 } else { 0 }
& node $jsPath "tickDir=$tickDir" "dailyDir=$dailyDir" "outDir=$outDir" "match=$Match" "momLen=$MomLen" "safeTh=$SafeTh" `
  "p1=$P1" "p2=$P2" "p3=$P3" "strongA=$StrongA" "bigMode=$BigMode" "bigTh=$BigTh" "bigIncl=$incl" `
  "relWin=$RelWin" "relK=$RelK" "armSkip=$ArmSkip" "maType=$MaType" "maLen=$MaLen" `
  "stLen=$StLen" "stMult=$StMult" "stAtr=$StAtr" "tickAbs=$TickAbs" "tickK=$TickK" `
  "useEma=$useEma" "useTick=$useTick" "useDisp=$useDisp" "limMode=$LimMode" "limPct=$LimPct" "pbPct=$PbPct" `
  "dispMax=$DispMax" "dispUntil=$DispUntil" "openMults=$OpenMults"
if ($LASTEXITCODE -ne 0) { Bad "차트 생성 실패 (exit $LASTEXITCODE) - 위 [FAIL] 줄 확인"; exit 1 }
$index = Join-Path $outDir 'index.html'
Ok "차트 생성: $index"
if (-not $NoOpen) { Start-Process $index }
