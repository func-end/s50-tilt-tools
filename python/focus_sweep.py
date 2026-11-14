#!/usr/bin/env python3
"""Focus sweep: where in the frame does each region come to its best focus?

Take a few minutes of frames at each of several focus positions (for example autofocus, then 20 and 40 steps either
side). For every capture run this measures ASTAP star sizes in a 3x3 grid (see s50tilt.py). For each region (top,
middle and bottom rows, and the four corners) it then fits HFD^2 as a quadratic in FOCUSPOS across the runs, and
reports the fitted best-focus position with a 68% bootstrap range over runs.

If the top and bottom rows reach best focus at different positions, the surface of best focus is tilted relative to
the sensor. The difference is reported in focuser steps. It is a model estimate from a handful of runs, and it does not
by itself say what causes the tilt.

Usage:
  python focus_sweep.py FOLDER [--astap PATH] [--json OUT.json] [--png OUT.png]
"""
import argparse, glob, json, os, shutil, sys, tempfile

import numpy as np

import s50tilt

REGIONS = {"top row": ("row", 0), "middle row": ("row", 1), "bottom row": ("row", 2),
           "1A top-left": ("cell", (0, 0)), "1C top-right": ("cell", (0, 2)),
           "3A bottom-left": ("cell", (2, 0)), "3C bottom-right": ("cell", (2, 2))}
RNG = np.random.default_rng(20261007)


def best_focus(pos, hfd):
    a, b, c = np.polyfit(pos, np.asarray(hfd) ** 2, 2)
    return (-b / (2 * a)) if a > 0 else np.nan, (a, b, c)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder")
    ap.add_argument("--astap", default=shutil.which("astap_cli") or "astap_cli")
    ap.add_argument("--json")
    ap.add_argument("--png")
    a = ap.parse_args()
    for p in (a.json, a.png):
        if p and os.path.exists(p):
            sys.exit(f"refusing to overwrite {p}")
    files = sorted(glob.glob(os.path.join(a.folder, "*.fit")) + glob.glob(os.path.join(a.folder, "*.fits")))
    runs = []
    with tempfile.TemporaryDirectory() as tmp:
        for start, (focus, exptime), fl in s50tilt.split_runs(files):
            r = s50tilt.measure_run(fl, a.astap, tmp)
            r.pop("per_frame", None)
            r.update({"start_utc": start.isoformat(), "focuspos": focus, "exptime": exptime})
            runs.append(r)
            print(f"{start:%H:%M} UTC  focus {focus}  frames {r['measured']}/{r['frames']}  "
                  f"contrast {r.get('contrast_median')}%", flush=True)
    use = [r for r in runs if r["measured"] >= 3 and r["focuspos"] is not None]
    pos = np.array([r["focuspos"] for r in use], float)
    if len(set(pos)) < 3:
        sys.exit("need runs at three or more focus positions")
    regions = {}
    for name, (kind, idx) in REGIONS.items():
        g = [np.array(r["grid_rows_top_to_bottom"], float) for r in use]
        h = np.array([np.nanmean(x[idx]) if kind == "row" else x[idx] for x in g])
        p0, coef = best_focus(pos, h)
        boot = []
        for _ in range(500):
            i = RNG.integers(0, len(pos), len(pos))
            if len(set(pos[i])) >= 3:
                boot.append(best_focus(pos[i], h[i])[0])
        boot = np.array([b for b in boot if np.isfinite(b)])
        regions[name] = {"hfd_by_run": [round(float(v), 3) for v in h],
                         "best_focus": round(float(p0), 1) if np.isfinite(p0) else None,
                         "best_focus_p16_p84": [round(float(np.percentile(boot, 16)), 1),
                                                round(float(np.percentile(boot, 84)), 1)] if len(boot) else None,
                         "coef": [float(c) for c in coef]}
        print(f"{name:16s} best focus {regions[name]['best_focus']}  (68% bootstrap {regions[name]['best_focus_p16_p84']})")
    out = {"folder": os.path.abspath(a.folder), "runs": runs, "regions": regions}
    top, bottom = regions["top row"]["best_focus"], regions["bottom row"]["best_focus"]
    if top is not None and bottom is not None:
        out["bottom_minus_top_steps"] = round(bottom - top, 1)
        print(f"bottom row minus top row best focus: {out['bottom_minus_top_steps']} steps")
    if a.json:
        with open(a.json, "x") as fh:
            json.dump(out, fh, indent=1)
    if a.png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(9, 5.5), dpi=150)
        xs = np.linspace(pos.min() - 10, pos.max() + 10, 200)
        for name, colour, marker in (("top row", "#2a78d6", "o"), ("middle row", "#eda100", "s"), ("bottom row", "#e34948", "D")):
            h = np.array(regions[name]["hfd_by_run"]); qa, qb, qc = regions[name]["coef"]
            ax.scatter(pos, h, color=colour, marker=marker, s=40, zorder=3,
                       label=f"{name}  (best ≈ {regions[name]['best_focus']})")
            ax.plot(xs, np.sqrt(np.clip(qa * xs ** 2 + qb * xs + qc, 0, None)), color=colour, lw=2)
            if regions[name]["best_focus"]:
                ax.axvline(regions[name]["best_focus"], color=colour, lw=1, ls=":")
        ax.set_xlabel("Focus position (FOCUSPOS)")
        ax.set_ylabel("Median star HFD, px (ASTAP)")
        ax.set_title("Star size against focus, by part of the frame (app image orientation)", fontsize=10.5, loc="left")
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        ax.grid(axis="y", color="#e1e0d9", lw=0.8)
        ax.legend(frameon=False, fontsize=9)
        fig.tight_layout()
        fig.savefig(a.png)


if __name__ == "__main__":
    main()
