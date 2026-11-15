"""Draws docs/architecture.svg (plain SVG, no dependencies)."""
import pathlib
W, H = 1280, 640
o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="system-ui,Arial,sans-serif">',
     '<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0,0L10,5L0,10z" fill="#52514e"/></marker></defs>',
     f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
     '<text x="32" y="40" font-size="20" font-weight="650" fill="#0b0b0b">Collections analytics: production architecture</text>',
     '<text x="32" y="62" font-size="13" fill="#52514e">Daily run at 02:00 IST. Each run reprocesses the last 7 days, so late events and status changes are absorbed. Raw is never altered.</text>']

def box(x, y, w, h, title, lines, fill="#f4f3ef", stroke="#c9c8c1"):
    o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}"/>')
    o.append(f'<text x="{x+w/2}" y="{y+22}" text-anchor="middle" font-size="13.5" font-weight="650" fill="#0b0b0b">{title}</text>')
    for i, l in enumerate(lines):
        o.append(f'<text x="{x+w/2}" y="{y+42+i*16}" text-anchor="middle" font-size="11" fill="#52514e">{l}</text>')

def arrow(x1, y1, x2, y2, dash=False, label=None, lx=6):
    o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#52514e" stroke-width="1.5" marker-end="url(#a)"' + (' stroke-dasharray="5 4"' if dash else '') + '/>')
    if label:
        o.append(f'<text x="{(x1+x2)/2+lx}" y="{(y1+y2)/2+4}" font-size="11" fill="#52514e">{label}</text>')

o.append('<text x="32" y="104" font-size="12" letter-spacing="1" fill="#7b7a74">SOURCE SYSTEMS</text>')
for i, s in enumerate(["Core lending: accounts, borrowers", "Dialler + telephony vendors", "WhatsApp + SMS providers", "Field app", "Payment gateways", "HR: agents"]):
    y = 116 + i * 46
    o.append(f'<rect x="32" y="{y}" width="200" height="36" rx="6" fill="#ffffff" stroke="#c9c8c1"/><text x="132" y="{y+22}" text-anchor="middle" font-size="12" fill="#0b0b0b">{s}</text>')
o.append('<path d="M232,134H250V364H232" fill="none" stroke="#52514e" stroke-width="1.5"/>')
arrow(250, 248, 274, 248)

o.append('<text x="278" y="104" font-size="12" letter-spacing="1" fill="#7b7a74">WAREHOUSE LAYERS</text>')
layers = [("RAW", ["append-only,", "as delivered", "+ load time, file"]), ("STAGING", ["typed columns", "1 row per raw row", "no business logic"]),
          ("CLEAN", ["deduplicated", "timestamps in IST", "codes mapped, flags"]), ("GOLDEN", ["dims with history", "facts: payment, call,", "touch, promise", "account x day grid"]),
          ("FEATURE", ["point-in-time", "account features", "(no look-ahead)"]), ("METRICS", ["one SQL definition", "per KPI, per day", "and per month"])]
xs = [278 + i * 140 for i in range(6)]
for (t, l), x in zip(layers, xs):
    box(x, 186, 124, 124, t, l, "#e7f0fc", "#2a78d6")
for i in range(5):
    arrow(xs[i] + 124, 248, xs[i + 1], 248)
box(xs[1] + 30, 352, 204, 70, "Data-quality gate", ["contracts, keys, freshness,", "reconciliation to settlement file"], "#fdf3dc", "#d9a520")
arrow(xs[1] + 132, 352, xs[1] + 132, 254, dash=True, label="pass", lx=-32)
box(xs[1] + 30, 460, 204, 52, "Quarantine", ["failed batch held, owner alerted"], "#fbe9e7", "#d03b3b")
arrow(xs[1] + 132, 422, xs[1] + 132, 460, label="fail")
o.append(f'<path d="M{xs[3]+62},186V160H{xs[5]+62}V180" fill="none" stroke="#52514e" stroke-width="1.5" marker-end="url(#a)"/>')
box(1126, 186, 124, 124, "DASHBOARD", ["one screen", "per-day default", "last 3 days marked", "provisional"], "#eaf6ea", "#0c8a0c")
arrow(xs[5] + 124, 248, 1126, 248)
box(xs[3] - 10, 352, 144, 70, "Experiment registry", ["hold-out assignment", "logged before treatment"])
arrow(xs[3] + 62, 352, xs[3] + 62, 312)
box(xs[5] - 76, 352, 184, 86, "Monitoring + alerts", ["anomaly: 3 robust SD vs", "same weekday, 8 weeks;", "level shift, mix drift"])
arrow(xs[5] + 62, 310, xs[5] + 62, 352)
box(1122, 352, 128, 86, "Late events", ["older than 7 days:", "targeted rebuild", "+ restatement log"])
for y, t in ((548, "Orchestrator: idempotent daily runs, merge on primary key, backfill by date range from RAW, code version recorded per run"),
             (588, "Lineage + run log: rows in, rejected by rule, rows out, per table and run (golden.audit_cleaning)")):
    o.append(f'<rect x="278" y="{y}" width="972" height="30" rx="6" fill="#f4f3ef" stroke="#c9c8c1"/><text x="764" y="{y+20}" text-anchor="middle" font-size="12.5" fill="#0b0b0b">{t}</text>')
o.append('</svg>')
out = pathlib.Path(__file__).resolve().parents[1] / "docs" / "architecture.svg"
out.write_text("\n".join(o)); print("wrote", out)
