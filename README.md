# S50 tilt tools

Tools for measuring field tilt (one side of the frame softer than the other) on ZWO Seestar S50 Pro images. I wrote them while testing two S50 Pro units in October and November 2026. The results are at **https://www.evanshq.me**.

| Folder | What it is |
|---|---|
| `python/s50tilt.py` | Corner contrast for each capture run, from FITS frames, using ASTAP's star detection |
| `python/focus_sweep.py` | Best focus for each part of the frame, from runs at several focus positions |
| `ios/S50FocusCheck.swiftpm` | **S50 Focus Check**, an iPad/iPhone app (Swift Playgrounds) that estimates the same figure from the Seestar app's saved image or a FITS file, offline |
| `ios/harness` | Mac command-line test programs for the app's measuring code |

## The measurement

ASTAP reports each star's half-flux diameter (HFD): the width of the circle that holds half the star's light. A softer star has a larger HFD. For each frame:

1. Split the frame into a 3×3 grid and take the median HFD in each corner cell, using ASTAP's labels: 1A top-left, 1C top-right, 3A bottom-left and 3C bottom-right.
2. **Corner contrast = (largest corner median − smallest corner median) ÷ median HFD of all stars × 100.**

A run's figure is the median over its frames. Grid row 0 is low FITS y, which is the top of the image as the Seestar app shows it.

This is close to ASTAP's own Image Inspection tilt figure, but not identical. On six sample frames the two ranked the frames in the same order and agreed within 1.5 percentage points on five, and within 4.3 on the sixth.

The thresholds I used were my own screening rules, not ZWO's tolerances:
- **pass:** 15% or less at autofocus, and under 25% at 20 focus steps either side;
- **worth raising with the seller:** 25% or more, repeatably.

## Python tools

**You need:**
- Python 3 with `numpy` and `astropy`, plus `matplotlib` for the focus-sweep chart. Run `pip install -r python/requirements.txt`; those are the versions I tested.
- ASTAP's command-line program, `astap_cli`, from https://www.hnsky.org/astap.htm. I used version CLI-2026.09.01 on macOS. Either put it on your PATH or pass `--astap /path/to/astap_cli`.

**Getting frames:** in the Seestar app, turn on saving of individual frames. Connect the scope by USB and it appears as a drive; the frames are in `MyWorks/<target>_sub`. Copy them to your computer. The tools only read FITS files, and ASTAP works on a temporary copy of each one.

**Corner contrast:**

```
python python/s50tilt.py "path/to/NGC 869_sub"
python python/s50tilt.py "path/to/NGC 869_sub" --newest 20 --json results.json
```

Frames are grouped into capture runs: a new run starts when the focus position or exposure changes, or after a gap of more than 5 minutes. For each run it prints the median contrast with its 10th–90th percentile range, which corner was softest, and a 3×3 grid of median star sizes in pixels.

**Focus sweep:** take a few minutes at each of several focus positions, for example autofocus and then 20 and 40 steps either side, with autofocus turned off. Then run:

```
python python/focus_sweep.py "path/to/NGC 869_sub" --png sweep.png --json sweep.json
```

For each region it fits HFD² as a quadratic in focus position, and reports the fitted best focus with a 68% bootstrap range over runs. If the top and bottom rows peak at different positions, the surface of best focus is tilted relative to the sensor. This doesn't say what causes the tilt.

**Check:** on my Oct 7 sweep (NGC 869, Alt-Az, 99 frames), these tools reproduce my original analysis exactly:

| Focus | Frames | Corner contrast |
|---|---|---|
| 1000 | 12 | 51.6% |
| 1024 | 12 | 41.8% |
| 1040 (autofocus) | 33 | 17.5% |
| 1042 (autofocus) | 18 | 9.7% |
| 1064 | 12 | 32.2% |
| 1080 | 12 | 52.0% |

Fitted best focus: top row 1061, middle 1049, bottom 1029, so the bottom row came to focus 32 steps lower than the top.

## S50 Focus Check (iPad / iPhone)

A small app for use in the field, with no computer. It runs entirely on the device.

**Install:**
1. Install Swift Playgrounds (free, from Apple).
2. Copy `ios/S50FocusCheck.swiftpm` to the device, for example through iCloud Drive or AirDrop.
3. Open it in Swift Playgrounds and tap Run. It needs iOS/iPadOS 17 or later.

**Use:** shoot a star field (NGC 869 works well) for 2–3 minutes. Save the stack to Photos at full size (2160 × 3840), not the smaller share copy. Then pick it in the app. You can also pick a FITS frame or stack from Files. The app shows:
- an estimated corner contrast and its ASTAP class;
- the softest corner;
- a 3×3 star-size map;
- plain advice;
- a list of past checks.

**Validation against ASTAP** (my data from one S50 Pro, October 2026):

| Input | Result |
|---|---|
| Raw FITS frames (8 runs, 4 frames each) | median within about 4 points of ASTAP; correct softest corner in every run |
| FITS stacks (13 star fields) | rank correlation 0.99; same worst row in 12 of 13 |
| Full-size app image of the same stacks | rank correlation 0.98; same worst row in 12 of 13 |
| The app's smaller share copy (1125 × 2000) | not reliable (rank correlation 0.59) |
| Nebula and galaxy fields | not reliable |

Figures from the app's JPEG run lower than ASTAP's on the FITS, so the app multiplies them by 1.35. That factor is an empirical calibration from one unit's images, not a general equivalence. FITS results use no factor.

**Privacy:** the app reads pixels only. The Seestar's image records include the observing site's GPS position; the app never reads or shows it, and saved thumbnails carry no metadata. Nothing leaves the device.

**Mac test harness:** build with `swiftc -O ios/S50FocusCheck.swiftpm/FocusCore.swift ios/harness/main.swift -o focuscheck`, then run `./focuscheck FILE...` to print the figure for each image or FITS file.

## Limits

- Two units, one owner, one site and a handful of nights.
- The softness repeated on each unit, but these tools don't identify its physical cause.
- Focus, temperature and seeing all move the number, so compare repeated runs rather than single frames.
- Not affiliated with ZWO or with ASTAP. ASTAP is separate software with its own licence and isn't included here.
- Written with help from AI assistants, and checked against ASTAP and independent methods.

## Licence

MIT. See `LICENSE`.
