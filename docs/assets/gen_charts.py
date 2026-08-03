#!/usr/bin/env python3
"""Deterministic SVG benchmark charts for the README (light + dark variants).

Data sources (do not hand-edit numbers here without re-running the tests):
  - returns / drawdowns: test/backtest/BacktestReal.t.sol (the README per-cycle table);
  - pool add-on per cycle: test/backtest/ClosedPopulation.t.sol `*_percycle` tests
    (A45 paired runs: add-on = MTM(redeposit) - MTM(plain), per $100 deposited).

Regenerate:  python3 docs/assets/gen_charts.py
"""

import os

OUT = os.path.dirname(os.path.abspath(__file__))

# Fixed entity -> color mapping (categorical slots 1-4 of the validated reference
# palette; color follows the entity in every chart, never its rank).
SERIES = ["Mini", "B4", "Pro", "Pro Max"]
LIGHT = {
    "colors": ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"],
    "text": "#0b0b0b",
    "text2": "#52514e",
    "grid": "#e5e4e1",
    "axis": "#c9c8c4",
    "ref": "#8a8983",
}
DARK = {
    "colors": ["#3987e5", "#d95926", "#199e70", "#c98500"],
    "text": "#ffffff",
    "text2": "#c3c2b7",
    "grid": "#2e2e2c",
    "axis": "#44443f",
    "ref": "#7a7973",
}

CYCLES = ["Cycle 1\n2012–16", "Cycle 2\n2016–20", "Cycle 3\n2020–24", "Cycle 4*\n2024–now"]

# Realized per-cycle return multiples (README benchmark table, BacktestReal.t.sol).
HODL = [52.3, 13.6, 7.3, 1.01]
RETURNS = {
    "Mini": [50.8, 13.2, 7.1, 1.00],
    "B4": [137.2, 51.9, 28.6, 1.70],
    "Pro": [230.3, 73.1, 45.8, 2.35],
    "Pro Max": [660.0, 277.7, 253.0, 4.07],
}

# Worst mark-to-market drawdown per cycle, % (README benchmark table).
DRAWDOWN = {
    "Mini": [84.45, 83.44, 76.81, 53.33],
    "B4": [73.85, 64.04, 53.02, 28.15],
    "Pro": [73.85, 64.04, 53.02, 28.15],
    "Pro Max": [75.40, 71.86, 58.11, 48.86],
}

# Pool add-on per $100 deposited, per cycle, USD (ClosedPopulation `*_percycle`).
POOL = {
    "Mini": [11.57, 8.63, 4.88, 1.45],
    "B4": [32.86, 30.79, 13.76, 2.84],
    "Pro": [55.35, 46.52, 22.84, 3.58],
    "Pro Max": [87.09, 97.42, 58.39, 4.99],
}

W, H = 920, 440
ML, MR, MT, MB = 64, 20, 78, 56
PW, PH = W - ML - MR, H - MT - MB
BAR, GAP = 22, 3
FONT = "-apple-system,'Segoe UI',Helvetica,Arial,sans-serif"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def bar_path(x, y, w, h, r):
    """Bar with rounded top corners only, square at the baseline."""
    if h <= r:
        r = max(0.0, h / 2)
    return (
        f"M{x:.1f},{y + h:.1f} V{y + r:.1f} Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f} "
        f"H{x + w - r:.1f} Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f} V{y + h:.1f} Z"
    )


def chart(theme, title, subtitle, data, ymax, yticks, fmt, tick_fmt, refline=None, ref_label=""):
    t = theme
    s = []
    s.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'viewBox="0 0 {W} {H}" font-family="{FONT}">'
    )
    s.append(
        f'<text x="{ML}" y="26" font-size="16" font-weight="600" fill="{t["text"]}">'
        f"{esc(title)}</text>"
    )
    s.append(
        f'<text x="{ML}" y="45" font-size="12" fill="{t["text2"]}">{esc(subtitle)}</text>'
    )
    # legend (always present for >=2 series)
    lx = ML
    for i, name in enumerate(SERIES):
        s.append(
            f'<rect x="{lx}" y="56" width="11" height="11" rx="3" fill="{t["colors"][i]}"/>'
        )
        s.append(
            f'<text x="{lx + 15}" y="65.5" font-size="12" fill="{t["text"]}">{esc(name)}</text>'
        )
        lx += 15 + 8 * len(name) + 22
    # grid + y ticks
    for v in yticks:
        y = MT + PH - PH * v / ymax
        s.append(
            f'<line x1="{ML}" y1="{y:.1f}" x2="{W - MR}" y2="{y:.1f}" '
            f'stroke="{t["grid"]}" stroke-width="1"/>'
        )
        s.append(
            f'<text x="{ML - 8}" y="{y + 4:.1f}" font-size="11" text-anchor="end" '
            f'fill="{t["text2"]}">{tick_fmt(v)}</text>'
        )
    # baseline
    s.append(
        f'<line x1="{ML}" y1="{MT + PH}" x2="{W - MR}" y2="{MT + PH}" '
        f'stroke="{t["axis"]}" stroke-width="1"/>'
    )
    # reference line, labeled in the left gutter (no free space above the plot's right edge)
    if refline is not None:
        y = MT + PH - PH * refline / ymax
        s.append(
            f'<line x1="{ML}" y1="{y:.1f}" x2="{W - MR}" y2="{y:.1f}" '
            f'stroke="{t["ref"]}" stroke-width="1"/>'
        )
        s.append(
            f'<text x="{ML - 8}" y="{y + 4:.1f}" font-size="11" text-anchor="end" '
            f'fill="{t["text2"]}">{esc(ref_label)}</text>'
        )
    # grouped bars with per-group label de-collision (adjacent equal-height bars would
    # otherwise print overlapping values — cycle 4 has three near-equal tops)
    n = len(SERIES)
    cluster = n * BAR + (n - 1) * GAP
    slot = PW / len(CYCLES)
    for g, cyc in enumerate(CYCLES):
        x0 = ML + g * slot + (slot - cluster) / 2
        labels = []
        for i, name in enumerate(SERIES):
            v = data[name][g]
            h = PH * v / ymax
            x = x0 + i * (BAR + GAP)
            y = MT + PH - h
            s.append(f'<path d="{bar_path(x, y, BAR, h, 4)}" fill="{t["colors"][i]}"/>')
            labels.append([x + BAR / 2, y - 5, fmt(v)])
        for j in range(1, len(labels)):
            prev, cur = labels[j - 1], labels[j]
            if cur[0] - prev[0] < 34 and abs(cur[1] - prev[1]) < 12:
                cur[1] = prev[1] - 12
        for cx, cy, txt in labels:
            s.append(
                f'<text x="{cx:.1f}" y="{cy:.1f}" font-size="10.5" '
                f'text-anchor="middle" fill="{t["text2"]}">{txt}</text>'
            )
        lines = cyc.split("\n")
        s.append(
            f'<text x="{x0 + cluster / 2:.1f}" y="{MT + PH + 18}" font-size="12" '
            f'text-anchor="middle" fill="{t["text"]}">{esc(lines[0])}</text>'
        )
        s.append(
            f'<text x="{x0 + cluster / 2:.1f}" y="{MT + PH + 34}" font-size="11" '
            f'text-anchor="middle" fill="{t["text2"]}">{esc(lines[1])}</text>'
        )
    s.append("</svg>")
    return "\n".join(s)


def write(name, **kw):
    for suffix, theme in (("light", LIGHT), ("dark", DARK)):
        path = os.path.join(OUT, f"{name}-{suffix}.svg")
        # UTF-8 + LF + trailing newline, so regeneration is byte-stable across platforms.
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(chart(theme, **kw) + "\n")
        print("wrote", path)


def main():
    vs_hodl = {
        name: [RETURNS[name][c] / HODL[c] for c in range(4)] for name in SERIES
    }
    write(
        "benchmark-returns",
        title="Per-cycle realized return, relative to buy-and-hold",
        subtitle="BacktestReal.t.sol — real contracts, cranked daily; cycle 4 in progress (unrealized)",
        data=vs_hodl,
        ymax=38,
        yticks=[0, 10, 20, 30],
        fmt=lambda v: f"{v:.1f}×" if v >= 2.95 else f"{v:.2g}×",
        tick_fmt=lambda v: f"{v:.0f}×",
        refline=1.0,
        ref_label="HODL 1×",
    )
    write(
        "benchmark-drawdown",
        title="Worst drawdown per cycle (lower is better)",
        subtitle="Mark-to-market equity, includes unrealized perp PnL; Mini tracks raw HODL",
        data=DRAWDOWN,
        ymax=100,
        yticks=[0, 25, 50, 75, 100],
        fmt=lambda v: f"{v:.1f}%",
        tick_fmt=lambda v: f"{v:.0f}%",
    )
    write(
        "benchmark-pool",
        title="Penalty-pool add-on per $100 deposited, per cycle",
        subtitle="ClosedPopulation.t.sol per-cycle pairs — claims redeposited (A45), r = 20% churn",
        data=POOL,
        ymax=112,
        yticks=[0, 25, 50, 75, 100],
        fmt=lambda v: f"${v:.2f}",
        tick_fmt=lambda v: f"${v:g}",
    )


if __name__ == "__main__":
    main()
