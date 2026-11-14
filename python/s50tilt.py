#!/usr/bin/env python3
"""Corner contrast (field tilt) for Seestar S50 Pro FITS frames, using ASTAP's star detection.

For each FITS frame:
  1. copy it to a temporary folder (the original is only read),
  2. run `astap_cli -f COPY -extract 30`, which writes every detected star's x, y and HFD to a CSV,
  3. split the frame into a 3x3 grid and take the median HFD in each corner cell,
  4. corner contrast = (largest corner median - smallest corner median) / median HFD of all stars x 100.

Frames are grouped into capture runs: a new run starts whenever FOCUSPOS or EXPTIME changes, or two frames are more
than 5 minutes apart. Each run reports the median contrast over its frames, the softest corner per frame and a 3x3
grid of median star sizes.

Orientation: grid row 0 is low FITS y, which is the top of the image as the Seestar app shows it. Corner labels follow
ASTAP: 1A top-left, 1C top-right, 3A bottom-left, 3C bottom-right.

Usage:
  python s50tilt.py FOLDER [--astap PATH] [--newest N] [--json OUT.json]

  FOLDER   a folder of FITS frames, for example a Seestar "<target>_sub" folder
  --astap  path to ASTAP's command-line program (default: astap_cli on your PATH)
  --newest only use the newest N frames (handy for a quick check during a session)
  --json   also write the full results to OUT.json (refuses to overwrite)
"""
import argparse, csv, glob, json, os, shutil, subprocess, sys, tempfile
from datetime import datetime

import numpy as np
from astropy.io import fits

CORNERS = {"1A": (0, 0), "1C": (0, 2), "3A": (2, 0), "3C": (2, 2)}
CORNER_NAMES = {"1A": "top-left", "1C": "top-right", "3A": "bottom-left", "3C": "bottom-right"}
RUN_GAP_S = 300
MIN_STARS = 30


def astap_stars(path, astap, tmp):
    """Return an array of [y, x, hfd] (0-based pixels) from ASTAP, or None if ASTAP found too few stars."""
    copy = os.path.join(tmp, "frame.fit")
    table = os.path.join(tmp, "frame.csv")
    for p in (copy, table):
        if os.path.exists(p):
            os.remove(p)
    shutil.copyfile(path, copy)
    run = subprocess.run([astap, "-f", copy, "-extract", "30"], capture_output=True, text=True, timeout=300)
    if run.returncode != 0 or not os.path.exists(table):
        return None
    with open(table, newline="") as fh:
        rows = list(csv.DictReader(fh))
    if len(rows) < MIN_STARS:
        return None
    return np.array([[float(r["y"]) - 1, float(r["x"]) - 1, float(r["hfd"])] for r in rows])


def cells(stars, height, width):
    row = (stars[:, 0] * 3 // height).astype(int).clip(0, 2)
    col = (stars[:, 1] * 3 // width).astype(int).clip(0, 2)
    return row, col


def corner_contrast(stars, height, width, min_per_corner=5):
    """(contrast %, softest corner label), or None if a corner has too few stars."""
    row, col = cells(stars, height, width)
    med = {}
    for label, (r, c) in CORNERS.items():
        m = (row == r) & (col == c)
        if m.sum() < min_per_corner:
            return None
        med[label] = np.median(stars[m, 2])
    contrast = 100 * (max(med.values()) - min(med.values())) / np.median(stars[:, 2])
    return float(contrast), max(med, key=med.get)


def grid(stars, height, width, min_per_cell=5):
    """3x3 median HFD, rows top to bottom of the app image."""
    row, col = cells(stars, height, width)
    g = np.full((3, 3), np.nan)
    for r in range(3):
        for c in range(3):
            m = (row == r) & (col == c)
            if m.sum() >= min_per_cell:
                g[r, c] = np.median(stars[m, 2])
    return g


def split_runs(files):
    """Time-ordered capture runs: list of (start time, (FOCUSPOS, EXPTIME), [files])."""
    rows = []
    for f in files:
        h = fits.getheader(f)
        rows.append((datetime.fromisoformat(str(h["DATE-OBS"])[:19]), (h.get("FOCUSPOS"), h.get("EXPTIME")), f))
    rows.sort()
    runs = []
    for i, (t, key, f) in enumerate(rows):
        if not runs or key != runs[-1][1] or (t - rows[i - 1][0]).total_seconds() > RUN_GAP_S:
            runs.append((t, key, []))
        runs[-1][2].append(f)
    return runs


def measure_run(files, astap, tmp):
    per = []
    for f in files:
        h = fits.getheader(f)
        height, width = h["NAXIS2"], h["NAXIS1"]
        stars = astap_stars(f, astap, tmp)
        if stars is None:
            continue
        cc = corner_contrast(stars, height, width)
        if cc is None:
            continue
        per.append({"file": os.path.basename(f), "contrast": round(cc[0], 2), "softest": cc[1], "stars": len(stars),
                    "median_hfd": round(float(np.median(stars[:, 2])), 3), "grid": grid(stars, height, width)})
    if not per:
        return {"frames": len(files), "measured": 0}
    c = np.array([p["contrast"] for p in per])
    softest = {}
    for p in per:
        softest[p["softest"]] = softest.get(p["softest"], 0) + 1
    g = np.nanmedian(np.array([p["grid"] for p in per]), axis=0)
    return {"frames": len(files), "measured": len(per),
            "contrast_median": round(float(np.median(c)), 1),
            "contrast_p10_p90": [round(float(np.percentile(c, 10)), 1), round(float(np.percentile(c, 90)), 1)],
            "softest_corner_counts": softest,
            "median_hfd": round(float(np.median([p["median_hfd"] for p in per])), 2),
            "grid_rows_top_to_bottom": [[None if np.isnan(v) else round(float(v), 2) for v in r] for r in g],
            "per_frame": [{k: v for k, v in p.items() if k != "grid"} for p in per]}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder")
    ap.add_argument("--astap", default=shutil.which("astap_cli") or "astap_cli")
    ap.add_argument("--newest", type=int, default=0)
    ap.add_argument("--json")
    a = ap.parse_args()
    if a.json and os.path.exists(a.json):
        sys.exit(f"refusing to overwrite {a.json}")
    files = sorted(glob.glob(os.path.join(a.folder, "*.fit")) + glob.glob(os.path.join(a.folder, "*.fits")))
    if not files:
        sys.exit(f"no FITS files in {a.folder}")
    if a.newest:
        files = sorted(files, key=lambda f: str(fits.getheader(f)["DATE-OBS"]))[-a.newest:]
    out = {"folder": os.path.abspath(a.folder), "method": "astap_cli -extract 30; corner contrast", "runs": []}
    with tempfile.TemporaryDirectory() as tmp:
        for start, (focus, exptime), fl in split_runs(files):
            r = measure_run(fl, a.astap, tmp)
            r.update({"start_utc": start.isoformat(), "focuspos": focus, "exptime": exptime})
            out["runs"].append(r)
            if r["measured"]:
                soft = max(r["softest_corner_counts"], key=r["softest_corner_counts"].get)
                print(f"{start:%Y-%m-%d %H:%M} UTC  focus {focus}  {exptime:g}s  frames {r['measured']}/{r['frames']}  "
                      f"contrast {r['contrast_median']}% [{r['contrast_p10_p90'][0]}-{r['contrast_p10_p90'][1]}]  "
                      f"softest {CORNER_NAMES[soft]} ({r['softest_corner_counts'][soft]}/{r['measured']})")
                for row in r["grid_rows_top_to_bottom"]:
                    print("      " + "  ".join("  -  " if v is None else f"{v:5.2f}" for v in row))
            else:
                print(f"{start:%Y-%m-%d %H:%M} UTC  focus {focus}  no frames with enough stars")
    if a.json:
        with open(a.json, "x") as fh:
            json.dump(out, fh, indent=1)


if __name__ == "__main__":
    main()
