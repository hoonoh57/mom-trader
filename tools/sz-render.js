(function () {
  'use strict';
  var D = window.SZDATA;
  var cv = document.getElementById('cv'), g = cv.getContext('2d'), tip = document.getElementById('tip');
  var N = D.c.length, v0 = 0, v1 = N, cur = -1, drag = null;
  var PAN = [['price', 40], ['mom', 13], ['macd', 15], ['amt', 14], ['tick', 14]];
  var LM = 8, RM = 72, TOP = 6, BOT = 20, GAP = 8, W = 0, H = 0, lay = {};
  var REJ = { time: '#ffffff', count: '#888888', lim: '#c08040', ema: '#9a9a9a', disp: '#b070ff', tick: '#ff9900' };
  var hist = D.n.map(function (x, i) { return x == null || D.sig[i] == null ? null : x - D.sig[i]; });
  function step() { return (W - LM - RM) / (v1 - v0); }
  function X(i) { return LM + (i - v0 + 0.5) * step(); }
  function I(x) { return Math.floor(v0 + (x - LM) / step()); }
  function rng(arrs, extra, padK) {
    var mn = Infinity, mx = -Infinity;
    arrs.forEach(function (a) { for (var i = v0; i < v1; i++) { var x = a[i]; if (x == null || !isFinite(x)) continue; if (x < mn) mn = x; if (x > mx) mx = x; } });
    (extra || []).forEach(function (x) { if (x < mn) mn = x; if (x > mx) mx = x; });
    if (!isFinite(mn)) { mn = 0; mx = 1; }
    if (mx === mn) { mx += 1; mn -= 1; }
    var pd = (mx - mn) * (padK || 0.06); return [mn - pd, mx + pd];
  }
  function ym(p, r) { return function (v) { return p.y + p.h - (v - r[0]) / (r[1] - r[0]) * p.h; }; }
  function clip(p, fn) { g.save(); g.beginPath(); g.rect(LM, p.y, W - LM - RM, p.h); g.clip(); fn(); g.restore(); }
  function line(a, col, y, w) {
    g.strokeStyle = col; g.lineWidth = w || 1; g.beginPath(); var pen = false;
    for (var i = v0; i < v1; i++) { var x = a[i]; if (x == null || !isFinite(x)) { pen = false; continue; } if (!pen) { g.moveTo(X(i), y(x)); pen = true; } else g.lineTo(X(i), y(x)); }
    g.stroke(); g.lineWidth = 1;
  }
  function hl(y, v, col, dash) { g.strokeStyle = col; g.setLineDash(dash || []); g.beginPath(); g.moveTo(LM, y(v)); g.lineTo(W - RM, y(v)); g.stroke(); g.setLineDash([]); }
  function bars(a, colFn, y, base) {
    var bw = Math.max(1, step() * 0.7), z = y(base);
    for (var i = v0; i < v1; i++) { var x = a[i]; if (x == null || !isFinite(x)) continue; var yy = y(x); g.fillStyle = colFn(i, x); g.fillRect(X(i) - bw / 2, Math.min(z, yy), bw, Math.max(1, Math.abs(yy - z))); }
  }
  function axis(p, r, y, fmt) {
    g.strokeStyle = '#333'; g.strokeRect(LM, p.y, W - LM - RM, p.h);
    g.fillStyle = '#999'; g.font = '11px sans-serif'; g.textAlign = 'left';
    for (var k = 0; k < 4; k++) { var v = r[0] + (r[1] - r[0]) * (k + 0.5) / 4; g.fillText(fmt(v), W - RM + 4, y(v) + 4); }
  }
  function title(p, s) { g.fillStyle = '#ccc'; g.font = '12px "Malgun Gothic",sans-serif'; g.textAlign = 'left'; g.fillText(s, LM + 4, p.y + 13); }
  function tri(x, y, s, col, up) {
    g.fillStyle = col; g.beginPath();
    if (up) { g.moveTo(x, y - s); g.lineTo(x - s, y + s); g.lineTo(x + s, y + s); }
    else { g.moveTo(x, y + s); g.lineTo(x - s, y - s); g.lineTo(x + s, y - s); }
    g.closePath(); g.fill();
  }
  function cross(x, y, s, col) { g.strokeStyle = col; g.lineWidth = 1.5; g.beginPath(); g.moveTo(x - s, y - s); g.lineTo(x + s, y + s); g.moveTo(x + s, y - s); g.lineTo(x - s, y + s); g.stroke(); g.lineWidth = 1; }
  function draw() {
    g.fillStyle = '#111'; g.fillRect(0, 0, W, H);
    var s = step(), bw = Math.max(1, s * 0.7), i;
    var p = lay.price, r = rng([D.h, D.l], null, 0.10), y = ym(p, r);
    clip(p, function () {
      g.fillStyle = 'rgba(0,170,90,0.12)';
      for (var i = v0; i < v1; i++) if (D.safe[i]) g.fillRect(X(i) - s / 2, p.y, s + 0.5, p.h);
      for (i = v0; i < v1; i++) {
        var upc = D.c[i] >= D.o[i], col = upc ? '#ff4d4d' : '#4d8dff', x = X(i);
        g.strokeStyle = col; g.beginPath(); g.moveTo(x, y(D.h[i])); g.lineTo(x, y(D.l[i])); g.stroke();
        var t = y(Math.max(D.o[i], D.c[i])), b = y(Math.min(D.o[i], D.c[i]));
        g.fillStyle = col; g.fillRect(x - bw / 2, t, bw, Math.max(1, b - t));
      }
      line(D.ema, '#bbbbbb', y, 2);
      g.lineWidth = 1.5;
      for (i = Math.max(v0 + 1, 1); i < v1; i++) {
        if (D.st[i] == null || D.st[i - 1] == null || D.stDir[i] !== D.stDir[i - 1]) continue;
        g.strokeStyle = D.stDir[i] === 1 ? '#ff9933' : '#66ccff';
        g.beginPath(); g.moveTo(X(i - 1), y(D.st[i - 1])); g.lineTo(X(i), y(D.st[i])); g.stroke();
      }
      g.lineWidth = 1;
      D.trades.forEach(function (t) {
        g.strokeStyle = t.ret > 0 ? 'rgba(255,90,90,.9)' : 'rgba(90,200,255,.9)'; g.setLineDash([4, 3]);
        g.beginPath(); g.moveTo(X(t.inI), y(t.inPx)); g.lineTo(X(t.outI), y(t.outPx)); g.stroke(); g.setLineDash([]);
      });
      D.marks.forEach(function (m) {
        if (m.i < v0 || m.i >= v1) return;
        var x = X(m.i);
        if (m.k === 'arm') tri(x, y(D.l[m.i]) + 6, 4, '#ffdd00', true);
        else if (m.k === 'entry') tri(x, y(D.l[m.i]) + 16, 7, '#ff66cc', true);
        else if (m.k === 'exit') {
          tri(x, y(D.h[m.i]) - 14, 7, m.ret > 0 ? '#ff4040' : '#33bbff', false);
          g.fillStyle = '#eee'; g.font = '11px sans-serif'; g.textAlign = 'center';
          g.fillText((m.ret > 0 ? '+' : '') + m.ret.toFixed(2) + '%', x, y(D.h[m.i]) - 24);
        }
        else if (m.k === 'rej') cross(x, y(D.h[m.i]) - 8, 4, REJ[m.why] || '#fff');
      });
    });
    axis(p, r, y, function (v) { return Math.round(v).toLocaleString(); });
    title(p, '가격 · EMA' + D.emaLen + '(회색) · ST(주황↑/하늘↓) · 녹색음영=안심구간');
    p = lay.mom; r = rng([D.mom], [D.safeTh]); y = ym(p, r);
    clip(p, function () { hl(y, D.safeTh, '#888', [4, 3]); line(D.mom, '#ffcc33', y, 1.2); });
    axis(p, r, y, function (v) { return v.toFixed(1); }); title(p, 'Mom(' + D.momLen + ') · ' + D.safeTh + '선');
    p = lay.macd; r = rng([D.n, D.sig, hist], [0]); y = ym(p, r);
    clip(p, function () {
      bars(hist, function (i, x) { return x >= 0 ? 'rgba(255,90,90,.5)' : 'rgba(90,140,255,.5)'; }, y, 0);
      hl(y, 0, '#888', [4, 3]); line(D.n, '#ff5555', y, 1.2); line(D.sig, '#55aaff', y, 1.2);
    });
    axis(p, r, y, function (v) { return v.toFixed(3); }); title(p, '강도(빨강) · 강도시그널(파랑) · 막대=차이');
    p = lay.amt; r = rng([D.amt], [0]); r[0] = 0; y = ym(p, r);
    clip(p, function () { bars(D.amt, function (i) { return D.big[i] ? '#ff66cc' : '#555a66'; }, y, 0); });
    axis(p, r, y, function (v) { return (v / 1e8).toFixed(1) + '억'; }); title(p, '봉당 거래대금 · 분홍=대량봉(' + D.bigMode + ')');
    p = lay.tick; r = rng([D.cnt1, D.thr], [0]); r[0] = 0; y = ym(p, r);
    clip(p, function () { bars(D.cnt1, function (i) { return D.tickOk[i] ? '#33aa55' : '#555555'; }, y, 0); line(D.thr, '#ffdd00', y, 1); });
    axis(p, r, y, function (v) { return Math.round(v).toLocaleString(); }); title(p, '1분 체결건수 · 노랑=기준(5분평균×' + D.tickK + ')');
    g.fillStyle = '#999'; g.font = '11px sans-serif'; g.textAlign = 'center';
    var last = -1e9;
    for (i = v0; i < v1; i++) { var x = X(i); if (x - last < 80) continue; var hh = String(D.hms[i]).padStart(6, '0'); g.fillText(hh.slice(0, 2) + ':' + hh.slice(2, 4), x, H - 6); last = x; }
    if (cur >= v0 && cur < v1) { g.strokeStyle = 'rgba(255,255,255,.25)'; g.beginPath(); g.moveTo(X(cur), TOP); g.lineTo(X(cur), H - BOT); g.stroke(); }
  }
  function f(x, k) { return x == null || !isFinite(x) ? '-' : Number(x).toFixed(k); }
  function showTip(e) {
    if (cur < 0 || cur >= N) { tip.style.display = 'none'; return; }
    var i = cur, hh = String(D.hms[i]).padStart(6, '0');
    tip.innerHTML = hh.slice(0, 2) + ':' + hh.slice(2, 4) + ':' + hh.slice(4) +
      '<br>O ' + D.o[i] + ' H ' + D.h[i] + ' L ' + D.l[i] + ' C ' + D.c[i] +
      '<br>Mom ' + f(D.mom[i], 2) + (D.safe[i] ? ' (안심)' : '') +
      '<br>강도 ' + f(D.n[i], 4) + ' / 시그널 ' + f(D.sig[i], 4) +
      '<br>EMA ' + f(D.ema[i], 0) + ' · 이격 ' + f(D.disp[i], 1) + '%' +
      '<br>봉대금 ' + f(D.amt[i] / 1e8, 2) + '억' + (D.big[i] ? ' ★' : '') +
      '<br>누적 ' + f(D.taamt[i] / 1e8, 1) + '억' +
      '<br>1분체결 ' + D.cnt1[i] + ' / 기준 ' + f(D.thr[i], 0);
    tip.style.display = 'block';
    tip.style.left = (e.clientX > window.innerWidth - 280 ? e.pageX - 250 : e.pageX + 16) + 'px';
    tip.style.top = (e.pageY + 12) + 'px';
  }
  function resize() {
    var dpr = window.devicePixelRatio || 1;
    W = cv.clientWidth; H = cv.clientHeight;
    cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    var tot = PAN.reduce(function (s, p) { return s + p[1]; }, 0), avail = H - TOP - BOT - GAP * (PAN.length - 1), y = TOP;
    PAN.forEach(function (p) { var h = avail * p[1] / tot; lay[p[0]] = { y: y, h: h }; y += h + GAP; });
    draw();
  }
  cv.addEventListener('wheel', function (e) {
    e.preventDefault();
    var span = v1 - v0, c = Math.min(N - 1, Math.max(0, I(e.offsetX)));
    var ns = Math.round(span * (e.deltaY > 0 ? 1.25 : 0.8)); ns = Math.min(N, Math.max(20, ns));
    var a = Math.round(c - (c - v0) / span * ns); a = Math.max(0, Math.min(N - ns, a));
    v0 = a; v1 = a + ns; draw();
  }, { passive: false });
  cv.addEventListener('mousedown', function (e) { drag = { x: e.offsetX, a: v0, span: v1 - v0 }; });
  window.addEventListener('mouseup', function () { drag = null; });
  cv.addEventListener('mousemove', function (e) {
    if (drag) {
      var sp = (W - LM - RM) / drag.span, d = Math.round((drag.x - e.offsetX) / sp);
      var a = Math.max(0, Math.min(N - drag.span, drag.a + d)); v0 = a; v1 = a + drag.span;
    }
    cur = I(e.offsetX); if (cur < v0 || cur >= v1) cur = -1;
    draw(); showTip(e);
  });
  cv.addEventListener('mouseleave', function () { cur = -1; tip.style.display = 'none'; draw(); });
  cv.addEventListener('dblclick', function () { v0 = 0; v1 = N; draw(); });
  window.addEventListener('resize', resize);
  resize();
})();