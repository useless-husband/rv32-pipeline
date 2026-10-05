#!/usr/bin/env python3
"""Turn a pipeline-occupancy recording (vsim_pipe --pipeview FILE) into a
static HTML page: one row per fetched instruction, one column per cycle,
the stage letter (F D X M W) in each cell.  A stage that repeats on the
next cycle is a stall; a row that ends before W was squashed (flushed).

The page is self-contained (inline CSS, JS and data; no external resources,
no file reading), so it opens in any browser, including Safari in Lockdown
Mode.

    python3 tools/pipeview.py build/pipeview.json -o build/pipeview.html [--title TEXT]
"""

import argparse
import html
import json

WHY = ["I-cache miss", "ID hazard (load-use or CSR drain)", "divider or FPU busy", "MEM stall (D-cache or FENCE.I)",
       "redirect from EX", "redirect from MEM"]


def build_rows(rec):
    cycles = rec["cycles"]
    first, last = cycles[0][0], cycles[-1][0]
    rows = {}            # seq -> row
    fetch = {}           # cycle -> (seq, pc)
    for c in cycles:
        cyc, f_seq, f_pc, d_v, d_seq, d_pc, dis, e_v, e_seq, m_v, m_seq, w_v, w_seq, why = c
        fetch[cyc] = (f_seq, f_pc)
        if d_v:
            r = rows.setdefault(d_seq, {"seq": d_seq, "pc": d_pc, "dis": dis, "st": {}})
            r["st"][cyc] = "D"
        for valid, seq, letter in ((e_v, e_seq, "X"), (m_v, m_seq, "M"), (w_v, w_seq, "W")):
            if valid and seq in rows:
                rows[seq]["st"][cyc] = letter
    out = []
    for r in sorted(rows.values(), key=lambda r: min(r["st"])):
        d0 = min(r["st"])
        c = d0 - 1
        while c >= first and fetch.get(c) == (r["seq"], r["pc"]):  # fetch cycles of this row
            r["st"][c] = "F"
            c -= 1
        stages = "".join(r["st"].values())
        end = max(r["st"])
        r["fate"] = "commit" if "W" in stages else ("flight" if end >= last - 1 else "squash")
        r["first"] = min(r["st"])
        r["cells"] = [[cyc - first, r["st"][cyc]] for cyc in sorted(r["st"])]
        del r["st"]
        out.append(r)
    why = [c[13] for c in cycles]
    return first, last, out, why


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pipeline view</title>
<style>
:root {
  --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --line: #e3e3e6; --head: #f5f5f7;
  --F: #c9dcf5; --D: #cfe8cf; --X: #f6e3b4; --M: #e9d2ee; --W: #b9e2df;
  --stall: #ffffff; --squash: #9a9aa0; --mark: #b42318;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #161618; --fg: #ececf0; --muted: #9a9aa2; --line: #2e2e33; --head: #202024;
    --F: #2f4a6b; --D: #2f5233; --X: #6a5524; --M: #523a5c; --W: #245955;
    --stall: #161618; --squash: #6b6b72; --mark: #ff7b72;
  }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg);
       font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }
h1 { font-size: 20px; margin: 0 0 4px; }
p { margin: 4px 0 12px; color: var(--muted); max-width: 880px; }
.stats { display: flex; flex-wrap: wrap; gap: 6px 20px; margin: 0 0 12px; }
.stats b { font-variant-numeric: tabular-nums; }
.legend { display: flex; flex-wrap: wrap; gap: 6px 14px; margin: 0 0 12px; font-size: 13px; }
.legend span.k { display: inline-block; width: 18px; height: 16px; border: 1px solid var(--line);
                 text-align: center; font: 11px/14px ui-monospace, Menlo, monospace; margin-right: 4px; }
.wrap { overflow: auto; border: 1px solid var(--line); max-height: 78vh; }
table { border-collapse: collapse; font: 12px/16px ui-monospace, SFMono-Regular, Menlo, monospace; }
th, td { padding: 0; height: 18px; }
thead th { position: sticky; top: 0; background: var(--head); z-index: 2; font-weight: normal;
           color: var(--muted); border-bottom: 1px solid var(--line); }
td.c, th.c { width: 18px; min-width: 18px; text-align: center; border-right: 1px solid var(--line); }
td.pc, td.dis, th.pc, th.dis { position: sticky; background: var(--bg); z-index: 1; text-align: left;
                               padding: 0 8px; white-space: nowrap; border-right: 1px solid var(--line); }
th.pc, th.dis { background: var(--head); z-index: 3; }
td.pc, th.pc { left: 0; width: 82px; min-width: 82px; color: var(--muted); }
td.dis, th.dis { left: 82px; width: 230px; min-width: 230px; }
tr.squash td.dis, tr.squash td.pc { color: var(--squash); text-decoration: line-through; }
td.F { background: var(--F); } td.D { background: var(--D); } td.X { background: var(--X); }
td.M { background: var(--M); } td.W { background: var(--W); }
td.s { opacity: 0.5; }
td.x { color: var(--squash); }
tr.why td.c { color: var(--mark); font-size: 10px; }
.controls { margin: 0 0 10px; display: flex; gap: 14px; flex-wrap: wrap; align-items: center; }
</style>
</head>
<body>
<h1>Pipeline view</h1>
<p>__TITLE__ Each row is one fetched instruction, each column one clock cycle (cycle numbers on top).
F fetch, D decode, X execute, M memory, W write-back. A lower-case letter is the same stage held for another
cycle (a stall); a struck-through row was fetched on a wrong path and squashed (×). The bottom row marks why
the pipeline did not advance that cycle; hover a cell for details.</p>
<div class="stats" id="stats"></div>
<div class="legend" id="legend"></div>
<div class="controls"><label><input type="checkbox" id="hide"> hide squashed instructions</label></div>
<div class="wrap"><table id="grid"></table></div>
<script>
const DATA = __DATA__;
const WHY = __WHY__;
const NAMES = {F: "fetch", D: "decode", X: "execute", M: "memory", W: "write-back"};
function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text; return e; }
function whyText(bits) { return WHY.filter((_, i) => bits >> i & 1).join(", "); }
function render() {
  const hide = document.getElementById("hide").checked;
  const n = DATA.last - DATA.first + 1;
  const t = document.getElementById("grid");
  t.textContent = "";
  const thead = el("thead"), hr = el("tr");
  hr.append(el("th", "pc", "pc"), el("th", "dis", "instruction"));
  for (let i = 0; i < n; i++) hr.append(el("th", "c", (DATA.first + i) % 5 === 0 ? String((DATA.first + i) % 1000) : ""));
  thead.append(hr); t.append(thead);
  const tb = el("tbody");
  for (const r of DATA.rows) {
    if (hide && r.fate === "squash") continue;
    const tr = el("tr", r.fate);
    tr.append(el("td", "pc", r.pc), el("td", "dis", r.dis));
    const cells = new Array(n).fill(null);
    let prev = null;
    for (const [i, s] of r.cells) { cells[i] = [s, s === prev]; prev = s; }
    let lastIdx = r.cells.length ? r.cells[r.cells.length - 1][0] : -1;
    for (let i = 0; i < n; i++) {
      const c = cells[i];
      let td;
      if (c) {
        td = el("td", "c " + c[0] + (c[1] ? " s" : ""), c[1] ? c[0].toLowerCase() : c[0]);
        td.title = `cycle ${DATA.first + i}: ${NAMES[c[0]]}${c[1] ? " (stalled)" : ""}` +
                   (DATA.why[i] ? ` - ${whyText(DATA.why[i])}` : "");
      } else if (r.fate === "squash" && i === lastIdx + 1) {
        td = el("td", "c x", "\\u00d7"); td.title = `cycle ${DATA.first + i}: squashed`;
      } else td = el("td", "c");
      tr.append(td);
    }
    tb.append(tr);
  }
  const wr = el("tr", "why");
  wr.append(el("td", "pc", ""), el("td", "dis", "stall / flush"));
  for (let i = 0; i < n; i++) {
    const b = DATA.why[i], td = el("td", "c", b ? "!" : "");
    if (b) td.title = `cycle ${DATA.first + i}: ${whyText(b)}`;
    wr.append(td);
  }
  tb.append(wr);
  t.append(tb);
}
const counts = {commit: 0, squash: 0, flight: 0};
DATA.rows.forEach(r => counts[r.fate]++);
const stalls = WHY.map((_, i) => DATA.why.filter(b => b >> i & 1).length);
const st = document.getElementById("stats");
const n = DATA.last - DATA.first + 1;
[["cycles", n], ["committed", counts.commit], ["squashed", counts.squash],
 ["IPC in window", (counts.commit / n).toFixed(2)]].forEach(([k, v]) => {
  const s = el("span"); s.append(k + " "); s.append(el("b", "", String(v))); st.append(s); });
const lg = document.getElementById("legend");
for (const k of ["F", "D", "X", "M", "W"]) { const s = el("span"); const key = el("span", "k " + k, k);
  key.style.background = `var(--${k})`; s.append(key, NAMES[k]); lg.append(s); }
WHY.forEach((w, i) => { if (stalls[i]) lg.append(el("span", "", `${w}: ${stalls[i]} cycles`)); });
document.getElementById("hide").addEventListener("change", render);
render();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("recording")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--title", default="")
    a = ap.parse_args()
    with open(a.recording) as f:
        rec = json.load(f)
    if not rec["cycles"]:
        raise SystemExit("pipeview: the recording is empty (is --pv-from past the end of the run?)")
    first, last, rows, why = build_rows(rec)
    data = {"first": first, "last": last, "rows": rows, "why": why}
    page = (PAGE.replace("__DATA__", json.dumps(data, separators=(",", ":")).replace("</", "<\\/"))
                .replace("__WHY__", json.dumps(WHY))
                .replace("__TITLE__", html.escape(a.title)))
    with open(a.output, "w") as f:
        f.write(page)
    print(f"pipeview: {len(rows)} instructions over {last - first + 1} cycles -> {a.output}")


if __name__ == "__main__":
    main()
