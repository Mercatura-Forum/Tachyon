#!/usr/bin/env python3
"""offering_screen.py: the screen of an initial public offering on the venue, a self-contained page built from the
battery's own dump.

The flagship offering's book (the demand at each price against the institutional tranche, the clearing price and the
price chosen), its allocation by tranche, its hand-off to the listing and the register; the three other offerings
(one failed at pricing, one taken up by its underwriter, one withdrawn at the listing gate); the refusals by name.
Every figure is a row the offering register wrote in `custody/test/Offering.test.mo`, every one re-derived by the
twin (custody/integration/offering_twin.py).

Usage: offering_screen.py [--artifact] <Offering battery log> <out.html>

Attribution: Thebes Core Team.
"""
import json
import sys

STATES = {1: "open", 2: "priced", 3: "allocated", 4: "listed", 5: "withdrawn"}


def build(path):
    offers, ladders, priced, rows, handoffs, custody, refusals, orders = {}, {}, {}, {}, {}, {}, [], {}
    for line in open(path, encoding="utf-8"):
        f = line.rstrip("\n").split("|")
        if f[0] == "offer":
            v = list(map(int, f[3].split(",")))
            offers[int(f[1])] = {"code": f[2], "offered": v[0], "outstanding": v[1], "low": v[2], "high": v[3], "tick": v[4], "lot": v[5], "retailBps": v[6], "cornerBps": v[7], "uwBps": v[8], "firm": v[9], "minSold": v[10], "minFloat": v[11], "minHolders": v[12]}
        elif f[0] == "ladder":
            ladders[int(f[1])] = [list(map(int, x.split(":"))) for x in f[2].split(";") if x]
        elif f[0] == "priced":
            priced[int(f[1])] = list(map(int, f[2].split(",")))
        elif f[0] == "offering":
            v = list(map(int, f[2].split(",")))
            rows[int(f[1])] = {"state": v[0], "price": v[1], "corner": v[2], "retailDemand": v[3], "retailPaid": v[4], "bidDemand": v[5], "bidsAlloc": v[6], "retailAlloc": v[7], "unsold": v[8], "uwLots": v[9], "allocated": v[10], "holders": v[11], "cashDue": v[12], "refunds": v[13], "chain": f[3]}
        elif f[0] == "handoff":
            handoffs[int(f[1])] = list(map(int, f[2].split(",")))
        elif f[0] == "custody":
            custody[int(f[1])] = list(map(int, f[2].split(",")))
        elif f[0] == "refusal":
            refusals.append({"what": f[1], "rule": f[2]})
        elif f[0] == "order":
            v = list(map(int, f[5].split(",")))
            orders.setdefault(int(f[2]), []).append({"kind": int(f[3]), "lots": v[1], "live": v[3], "alloc": v[4], "price": v[0]})
    o, r, t = offers[1], rows[1], priced[1]
    inst_lots = o["offered"] // o["lot"] - o["offered"] // o["lot"] * o["retailBps"] // 10_000
    cum, curve, clearing = r["corner"], [], None
    for p, l in ladders[1]:
        cum += l
        curve.append([p, cum])
        if clearing is None and cum >= inst_lots:
            clearing = p
    bids = [x for x in orders[1] if x["kind"] == 2]
    retail = [x for x in orders[1] if x["kind"] == 3]
    corners = [x for x in orders[1] if x["kind"] == 1]
    small = [x for x in retail if x["lots"] <= 20]
    others = []
    for off in (2, 3, 4):
        oo, rr, pp = offers[off], rows[off], priced[off]
        others.append({"code": oo["code"], "state": STATES[rr["state"]], "firm": oo["firm"] == 1, "offerLots": oo["offered"] // oo["lot"], "instDemand": pp[2], "retailDemand": pp[3], "inst": pp[4], "retail": pp[5], "uw": pp[6], "unsold": pp[7], "failed": pp[8] == 1,
                       "price": rr["price"], "holders": rr["holders"], "minHolders": oo["minHolders"], "minSold": oo["minSold"], "refunds": rr["refunds"], "handoff": handoffs.get(off), "custody": custody.get(off), "lot": oo["lot"], "retailLots": oo["offered"] // oo["lot"] * oo["retailBps"] // 10_000})
    return {
        "o": o, "row": r, "priced": t, "curve": curve, "clearing": clearing, "instLots": inst_lots, "handoff": handoffs[1], "custody": custody[1],
        "bids": {"n": len(bids), "withdrawn": sum(1 for x in bids if not x["live"]), "eligible": sum(1 for x in bids if x["live"] and x["price"] >= r["price"]), "allotted": sum(1 for x in bids if x["alloc"] > 0)},
        "retail": {"n": len(retail), "allotted": sum(1 for x in retail if x["alloc"] > 0), "small": len(small), "smallAllotted": sum(1 for x in small if x["alloc"] > 0)},
        "corners": [x["lots"] for x in corners],
        "others": others, "refusals": refusals,
    }


HEAD = """<title>Nile Valley Logistics IPO</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Libre+Franklin:wght@400;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root { --bg:#f2f3f6; --ink:#181b24; --muted:#5a6072; --card:#ffffff; --line:#d5d8e1; --grid:#e7e9ef; --demand:#23407a; --tranche:#b3462e; --price:#1f7a5a; --retail:#b48a1f; --corner:#6b4fa0; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { color-scheme: dark; --bg:#11131a; --ink:#e3e5ec; --muted:#9aa0b2; --card:#191c25; --line:#2b2f3b; --grid:#232733; --demand:#7fa2e8; --tranche:#ec8a70; --price:#5cc79d; --retail:#e3bd5a; --corner:#a98de0; } }
:root[data-theme="dark"] { color-scheme: dark; --bg:#11131a; --ink:#e3e5ec; --muted:#9aa0b2; --card:#191c25; --line:#2b2f3b; --grid:#232733; --demand:#7fa2e8; --tranche:#ec8a70; --price:#5cc79d; --retail:#e3bd5a; --corner:#a98de0; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.55 "Libre Franklin", -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width:1080px; margin:0 auto; padding-block:24px 64px; padding-inline:16px; }
h1 { font-size:25px; margin:0 0 4px; text-wrap:balance; } h2 { font-size:19px; margin:30px 0 4px; text-wrap:balance; } h3 { font-size:15px; margin:0 0 8px; }
.sub { color:var(--muted); margin:0 0 14px; max-width:780px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:16px; }
.two { display:grid; grid-template-columns:3fr 2fr; gap:16px; } @media (max-width:800px) { .two { grid-template-columns:1fr; } } .two > * { min-width:0; }
.three { display:grid; grid-template-columns:repeat(3, 1fr); gap:16px; } @media (max-width:800px) { .three { grid-template-columns:1fr; } } .three > * { min-width:0; }
.num, td.n { font-family:"IBM Plex Mono", ui-monospace, Menlo, monospace; font-variant-numeric:tabular-nums; }
.meta { color:var(--muted); font-size:13px; }
.scroll { overflow-x:auto; }
dl.kv { display:grid; grid-template-columns:auto 1fr; gap:4px 14px; margin:0; font-size:14px; } dl.kv dt { color:var(--muted); } dl.kv dd { margin:0; text-align:right; font-family:"IBM Plex Mono", monospace; font-variant-numeric:tabular-nums; }
table { width:100%; border-collapse:collapse; font-size:14px; } th { text-align:left; font-weight:600; color:var(--muted); font-size:12px; letter-spacing:.03em; text-transform:uppercase; padding:6px 10px 6px 0; border-bottom:1px solid var(--line); white-space:nowrap; }
td { padding:5px 10px 5px 0; border-bottom:1px solid var(--grid); } td.n, th.n { text-align:right; white-space:nowrap; }
.tag { display:inline-block; font-size:12px; padding:1px 8px; border-radius:10px; border:1px solid var(--line); color:var(--muted); }
.legend { display:flex; flex-wrap:wrap; gap:14px; font-size:13px; color:var(--muted); margin-top:6px; } .legend i { display:inline-block; width:14px; height:3px; margin-right:6px; vertical-align:3px; }
svg { display:block; width:100%; height:auto; }
ul.refusals { columns:2 320px; margin:0; padding-left:18px; font-size:14px; } ul.refusals li { break-inside:avoid; margin-bottom:4px; } ul.refusals code { font-family:"IBM Plex Mono", monospace; font-size:12px; color:var(--muted); }
footer { color:var(--muted); font-size:12px; margin-top:28px; }
</style>
"""

BODY = """<main>
<h1>Nile Valley Logistics goes public</h1>
<p class="sub" id="lede"></p>

<h2>The book</h2>
<div class="two"><div class="card"><h3>Institutional demand at each price</h3>
<svg id="curve" viewBox="0 0 600 300" role="img" aria-label="Cumulative institutional demand by price against the institutional tranche"></svg>
<div class="legend"><span><i style="background:var(--demand)"></i>demand at or above the price, cornerstones included</span><span><i style="background:var(--tranche)"></i>the institutional tranche</span><span><i style="background:var(--price)"></i>the offer price</span></div></div>
<div class="card"><h3>How the price was set</h3><dl class="kv" id="pricing"></dl><p class="meta" id="pricingNote"></p></div></div>

<h2>The allocation</h2>
<p class="sub" id="allocSub"></p>
<div class="three" id="tranches"></div>

<h2>The hand-off to the listing</h2>
<div class="two"><div class="card"><h3>The listing gate and the proceeds</h3><dl class="kv" id="handoff"></dl></div>
<div class="card"><h3>The register at listing</h3><dl class="kv" id="register"></dl><p class="meta">Each allotment reached the custody register as an issuance receipt from the issuer. The register was then reconciled to the ledger's balances, with no breaks.</p></div></div>

<h2>Three other offerings</h2>
<p class="sub">The same register, with the rules that decide when an offering does not simply list.</p>
<div class="card"><div class="scroll"><table id="others"></table></div></div>

<h2>What the register refused</h2>
<p class="sub" id="refSub"></p>
<div class="card"><ul class="refusals" id="refusals"></ul></div>
<footer>The issuers, the investors and the figures are illustrative. Tranches, the cornerstone cap, the underwriting commitment and the listing gate are the offering's declared terms. Every figure is a row of the offering register in Tachyon, recomputed independently from the log, and its allocation file is certified by a hash chain. Thebes Core Team.</footer>
</main>
<script>
const D = __DATA__;
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const egp = p => (p / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const n = x => x.toLocaleString('en-US');
const O = D.o, R = D.row, P = D.priced, H = D.handoff, C = D.custody;
const retailLots = O.offered / O.lot * O.retailBps / 10000;
document.getElementById('lede').textContent = `The company offers ${n(O.offered)} new shares, ${(O.offered / O.outstanding * 100).toFixed(0)}% of the ${n(O.outstanding)} it will have, in lots of ${O.lot}. The price range is EGP ${egp(O.low)} to ${egp(O.high)}. ${O.retailBps / 100}% goes to the public, paid in full at the top of the range, and the rest to institutions through a book of bids. The underwriter commits to take up anything unsold, for a fee of ${O.uwBps / 100}% of the proceeds.`;
(function () {
  const W = 600, Hh = 300, L = 64, Rm = 12, T = 12, B = 34;
  const pts = D.curve, lo = O.low, hi = O.high, most = Math.max(pts[pts.length - 1][1], D.instLots) * 1.05;
  const X = v => L + (W - L - Rm) * v / most, Y = p => T + (Hh - T - B) * (hi - p) / (hi - lo);
  let g = '';
  for (let k = 0; k <= 4; k++) { const p = lo + (hi - lo) * k / 4; g += `<line x1="${L}" x2="${W - Rm}" y1="${Y(p)}" y2="${Y(p)}" stroke="var(--grid)"/><text x="${L - 6}" y="${Y(p) + 4}" text-anchor="end" font-size="11" fill="var(--muted)">${egp(p)}</text>`; }
  const step = Math.pow(10, Math.floor(Math.log10(most / 4))), unit = Math.ceil(most / 4 / step) * step;
  for (let v = 0; v <= most; v += unit) g += `<text x="${X(v)}" y="${Hh - 14}" text-anchor="middle" font-size="11" fill="var(--muted)">${n(v / 1000)}k</text>`;
  g += `<text x="${W - Rm}" y="${Hh - 1}" text-anchor="end" font-size="11" fill="var(--muted)">lots</text>`;
  let d = `M${X(R.corner)},${Y(hi)}`;
  pts.forEach(([p, c]) => { d += ` L${X(c)},${Y(p)}`; });
  d += ` L${X(pts[pts.length - 1][1])},${Y(lo)}`;
  g += `<path d="${d}" fill="none" stroke="var(--demand)" stroke-width="2.5"/>`;
  g += `<line x1="${X(D.instLots)}" x2="${X(D.instLots)}" y1="${T}" y2="${Hh - B}" stroke="var(--tranche)" stroke-width="2" stroke-dasharray="5 4"/>`;
  g += `<line x1="${L}" x2="${W - Rm}" y1="${Y(R.price)}" y2="${Y(R.price)}" stroke="var(--price)" stroke-width="2"/>`;
  g += `<text x="${W - Rm - 4}" y="${Y(R.price) - 6}" text-anchor="end" font-size="12" fill="var(--price)">offer price EGP ${egp(R.price)}</text>`;
  g += `<text x="${X(D.instLots) + 6}" y="${Hh - B - 8}" font-size="12" fill="var(--tranche)">tranche ${n(D.instLots)} lots</text>`;
  document.getElementById('curve').innerHTML = g;
})();
document.getElementById('pricing').innerHTML = [
  ['Cornerstones, before the book', n(R.corner) + ' lots'], ['Bids received', n(D.bids.n)], ['Withdrawn to be revised', n(D.bids.withdrawn)],
  ['Clearing price', 'EGP ' + egp(D.clearing)], ['Offer price', 'EGP ' + egp(R.price)], ['Institutional demand at the price', n(P[2]) + ' lots'],
  ['Institutional cover', (P[2] / D.instLots).toFixed(2) + '×'], ['Retail applications', n(D.retail.n)], ['Retail cover', (R.retailDemand / retailLots).toFixed(2) + '×'],
].map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('');
document.getElementById('pricingNote').textContent = `The clearing price is the highest at which the cornerstones and the bids at or above it cover the institutional tranche. The issuer and the underwriter priced one tick below it. A price above it is refused.`;
document.getElementById('allocSub').textContent = `Allocated in slices over ${n(D.bids.n + D.retail.n + D.corners.length)} orders. Cornerstones get their commitment in full. Bids at or above the price and the retail applications are allocated pro rata by cumulative rounding: each order is within one lot of its exact share, and every tranche's lots are allocated exactly.`;
document.getElementById('tranches').innerHTML = [
  ['Cornerstones', 'var(--corner)', [['Investors', n(D.corners.length)], ['Committed and allocated', n(R.corner) + ' lots'], ['Lock-up', 'not free float']]],
  ['Institutional book', 'var(--demand)', [['Bids at or above the price', n(D.bids.eligible)], ['Demand', n(R.bidDemand) + ' lots'], ['Allocated', n(R.bidsAlloc) + ' lots'], ['Fill', (R.bidsAlloc / R.bidDemand * 100).toFixed(1) + '%']]],
  ['Retail', 'var(--retail)', [['Applications', n(D.retail.n)], ['Demand', n(R.retailDemand) + ' lots'], ['Allocated', n(R.retailAlloc) + ' lots'], ['Applicants of 20 lots or less allotted', n(D.retail.smallAllotted) + ' of ' + n(D.retail.small)], ['Refunded', 'EGP ' + egp(R.refunds)]]],
].map(([h, c, kv]) => `<div class="card" style="border-top:3px solid ${c}"><h3>${esc(h)}</h3><dl class="kv">${kv.map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl></div>`).join('');
document.getElementById('handoff').innerHTML = [
  ['Free float', (H[4] / 100).toFixed(2) + '% (at least ' + (O.minFloat / 100).toFixed(2) + '%)'], ['Holders', n(H[5]) + ' (at least ' + n(O.minHolders) + ')'],
  ['Gross proceeds', 'EGP ' + egp(H[1])], ['Underwriting fee', 'EGP ' + egp(H[2])], ['To the issuer', 'EGP ' + egp(H[3])], ['Reference price for the first auction', 'EGP ' + egp(H[7])],
].map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('');
document.getElementById('register').innerHTML = [
  ['Shares in issue', n(C[0])], ['Delivered to allottees', n(C[1])], ['Kept by the issuer', n(C[2])], ['Holders reconciled', n(C[3])], ['Allocation file', R.chain.slice(0, 16) + '…'],
].map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('');
document.getElementById('others').innerHTML = '<tr><th>Offering</th><th>Commitment</th><th class="n">Offered</th><th class="n">Inst. demand</th><th class="n">Retail demand</th><th class="n">Underwriter</th><th class="n">Holders</th><th>Outcome</th></tr>' +
  D.others.map(x => {
    const out = x.failed ? `failed at pricing: sold ${((x.inst + x.retail) / x.offerLots * 100).toFixed(1)}%, below its ${x.minSold / 100}% minimum; EGP ${egp(x.refunds)} refunded`
      : x.state === 'listed' ? `listed at EGP ${egp(x.price)}; the retail tranche took ${n(x.retail - x.retailLots)} unfilled institutional lots and the underwriter the other ${n(x.uw)}`
      : `withdrawn at the listing gate: ${x.holders} holders of ${x.minHolders} needed; EGP ${egp(x.refunds)} refunded`;
    return `<tr><td><b>${esc(x.code)}</b></td><td>${x.firm ? 'firm' : 'best efforts'}</td><td class="n">${n(x.offerLots)}</td><td class="n">${n(x.instDemand)}</td><td class="n">${n(x.retailDemand)}</td><td class="n">${x.uw ? n(x.uw) : ''}</td><td class="n">${x.failed ? '' : n(x.holders)}</td><td>${esc(out)}</td></tr>`;
  }).join('');
document.getElementById('refSub').textContent = `${D.refusals.length} named refusals, each leaving the register's fingerprint unchanged:`;
document.getElementById('refusals').innerHTML = D.refusals.map(r => `<li>${esc(r.what)} <code>${esc(r.rule)}</code></li>`).join('');
</script>
"""


def main():
    args = [x for x in sys.argv[1:] if x != "--artifact"]
    data = build(args[0])
    body = BODY.replace("__DATA__", json.dumps(data, separators=(",", ":")))
    html = HEAD + body if "--artifact" in sys.argv[1:] else '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n' + HEAD + "</head>\n<body>\n" + body + "</body>\n</html>\n"
    open(args[1], "w", encoding="utf-8").write(html)


if __name__ == "__main__":
    main()
