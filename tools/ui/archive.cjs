'use strict';
// archive-1.0: screen CSV -> stock-day list -> one backward ka10079 fetch per code -> per-date files via kiwoom-fetch buildTick
const K = require('./kiwoom-fetch.cjs');
const VERSION = 'archive-1.0';
const ST_OK = '\uC815\uC0C1';
const asList = x => (Array.isArray(x) ? x : (x && typeof x === 'object' ? [x] : []));

function decode(buf) {
  if (buf.length >= 3 && buf[0] === 0xEF && buf[1] === 0xBB && buf[2] === 0xBF) return { text: buf.slice(3).toString('utf8'), enc: 'utf8-bom' };
  try { return { text: new TextDecoder('utf-8', { fatal: true }).decode(buf), enc: 'utf8' }; } catch (e) { /* not utf8 */ }
  return { text: new TextDecoder('euc-kr').decode(buf), enc: 'cp949' };
}

function splitCsvLine(s) {
  const out = []; let cur = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (q) { if (ch === '"') { if (s[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
    else if (ch === '"') q = true;
    else if (ch === ',') { out.push(cur); cur = ''; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

// columns by position: 1 time, 2 date, 3 code, 4 name, 7 status
function parseScreen(text) {
  const lines = text.split(/\r\n|\n|\r/);
  const header = splitCsvLine(lines[0] || '').map(s => s.trim());
  const ok = header.length >= 8 && header[3] === 'code' && header[4] === 'name';
  const st = { total: 0, byStatus: {}, badCode: 0, badDate: 0, minDate: '', maxDate: '' };
  const rows = [];
  if (!ok) return { ok, header, rows, st };
  for (let i = 1; i < lines.length; i++) {
    const s = lines[i];
    if (!s.trim()) continue;
    const c = splitCsvLine(s);
    st.total++;
    const date = (c[2] || '').trim(), status = (c[7] || '').trim();
    let code = (c[3] || '').trim();
    if (code.length === 7 && code[0] === 'A') code = code.slice(1);
    st.byStatus[status] = (st.byStatus[status] || 0) + 1;
    if (!/^\d{8}$/.test(date)) { st.badDate++; continue; }
    if (!/^[0-9A-Z]{6}$/.test(code)) { st.badCode++; continue; }
    if (!st.minDate || date < st.minDate) st.minDate = date;
    if (date > st.maxDate) st.maxDate = date;
    rows.push({ date, code, ok: status === ST_OK, time: (c[1] || '').trim() });
  }
  return { ok, header, rows, st };
}

function planItems(rows, since, until) {
  const m = new Map();
  for (const r of rows) {
    if (!r.ok || r.date < since || r.date > until) continue;
    if (!m.has(r.code)) m.set(r.code, new Set());
    m.get(r.code).add(r.date);
  }
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  return [...m].map(([code, s]) => ({ code, dates: [...s].sort() }))
    .sort((a, b) => cmp(a.dates[0], b.dates[0]) || cmp(a.code, b.code));
}

// same stop rule as 09 (prev bars before 'oldest' >= warmup), market AL, scope 120
async function fetchBack(cl, q) {
  const rows = [];
  let next = '', end = '', bad = 0, pages = 0, prevN = 0;
  for (let page = 1; page <= q.maxPages; page++) {
    pages = page;
    const r = await cl.chart('ka10079', { stk_cd: q.code + '_AL', tic_scope: '120', upd_stkpc_tp: '1' }, page > 1 ? next : '');
    const rc = String(r.json.return_code);
    if (rc !== '0') throw new Error('ka10079 return_code=' + rc + ' msg=' + r.json.return_msg);
    const chunk = asList(r.json.stk_tic_chart_qry);
    if (!chunk.length) { end = 'empty'; break; }
    for (const it of chunk) { const row = K.tickRow(it); if (row) { rows.push(row); if (row.date < q.oldest) prevN++; } else bad++; }
    if (prevN >= q.warmup) { end = 'warmup'; break; }
    const cont = r.headers.get('cont-yn') || '', nk = r.headers.get('next-key') || '';
    if (cont.toUpperCase() !== 'Y' || !nk) { end = 'cont_end(' + cont + ')'; break; }
    next = nk;
    await K.sleep(q.delayMs);
  }
  if (!end) end = 'max_pages(' + q.maxPages + ')';
  let minD = '', maxD = '';
  for (const x of rows) { if (!minD || x.date < minD) minD = x.date; if (x.date > maxD) maxD = x.date; }
  return { rows, pages, end, bad, minD, maxD };
}

function selftest() {
  const R = [];
  const t = (name, fn) => {
    try { const v = fn(); R.push({ name, ok: v === true, info: v === true ? '' : String(v) }); }
    catch (e) { R.push({ name, ok: false, info: 'threw ' + e.message }); }
  };
  const eq = (a, b) => (JSON.stringify(a) === JSON.stringify(b) ? true : 'expected ' + JSON.stringify(b) + ' got ' + JSON.stringify(a));
  t('decode', () => eq([decode(Buffer.from([0xEF, 0xBB, 0xBF, 0xED, 0x95, 0x9C])).text, decode(Buffer.from([0xED, 0x95, 0x9C])).enc,
    decode(Buffer.from([0xC7, 0xD1])).text, decode(Buffer.from([0xC7, 0xD1])).enc], ['\uD55C', 'utf8', '\uD55C', 'cp949']));
  t('splitCsvLine', () => eq(splitCsvLine('a,"12,640","x""y",,-'), ['a', '12,640', 'x"y', '', '-']));
  t('parseScreen', () => {
    const txt = 'h0,h1,h2,code,name,h5,h6,h7\r\n5%,09:05,20260506,A001500,n,"12,640","1,254.1",' + ST_OK + ',+0.47%\r\n' +
      '5%,09:05,20260506,A0011A0,n,-,-,X,-\r\n5%,09:05,2026050,A001500,n,1,1,' + ST_OK + '\r\n';
    const p = parseScreen(txt);
    return eq([p.ok, p.rows.length, p.rows[0].code, p.rows[0].ok, p.rows[1].code, p.rows[1].ok, p.st.badDate], [true, 2, '001500', true, '0011A0', false, 1]);
  });
  t('planItems', () => {
    const rows = [{ date: '20261007', code: 'B00000', ok: true }, { date: '20261006', code: 'A00000', ok: true }, { date: '20261006', code: 'A00000', ok: true },
      { date: '20261008', code: 'A00000', ok: true }, { date: '20261001', code: 'C00000', ok: true }, { date: '20261006', code: 'D00000', ok: false }];
    return eq(planItems(rows, '20261002', '20261031'), [{ code: 'A00000', dates: ['20261006', '20261008'] }, { code: 'B00000', dates: ['20261007'] }]);
  });
  t('multi-day slice equals single-day fetch', () => {
    const mk = (ts, p) => ({ ts, date: ts.slice(0, 8), time: ts.slice(8), o: p, h: p, l: p, c: p, v: 1, amt: p });
    const all = [mk('20261008090000', 9), mk('20261007090100', 8), mk('20261007090000', 7), mk('20261006090200', 6),
      mk('20261006090100', 5), mk('20261006090000', 4), mk('20261002090000', 3)];
    const a = K.buildTick(all, '20261007', 2).text, b = K.buildTick(all.slice(0, 5), '20261007', 2).text;
    return a === b ? true : 'differs';
  });
  return R;
}

module.exports = { VERSION, ST_OK, decode, splitCsvLine, parseScreen, planItems, fetchBack, selftest };