# The data folder

Fromage works on one folder that holds your videos and two spreadsheet files: `calibs.csv` (your calibration videos) and `runs.csv` (your run videos). This page covers how to lay that folder out, and the writing rules that both csv files share.

## The simplest layout

Everything in one folder:

```
my experiment/
├── calibs.csv
├── runs.csv
├── calib_morning.mp4
├── calib_afternoon.mp4
├── beetle01.mp4
├── beetle02.mp4
└── ...
```

and then:

```julia
main("path/to/my experiment")
```

## Other layouts

The csv files can be named differently or live in subfolders:

```julia
main("path/to/my experiment"; calibs_file = "meta/my_calibs.csv", runs_file = "meta/my_runs.csv")
```

And the video files can live in other folders via the `path` column in either csv file. Paths are relative to the folder the csv file itself is in; absolute paths work too.

## Editing csv files

A csv file is just a table saved as plain text — you can edit it in Excel, Google Sheets, LibreOffice, or any text editor. Just make sure it's saved as **.csv**, not .xlsx. Template files to copy from live in [`examples/`](https://github.com/yakir12/Fromage.jl/tree/main/examples).

## Rules both csv files share

- Column **order doesn't matter**, and optional columns may be left out entirely.
- A **blank cell** in an optional column means "use the default" — so a column can be filled in for some rows and left blank for others.
- **Unrecognized column names are an error.** This protects you from typos (a misspelled column would otherwise be silently ignored). Both files accept a free-text `comment` column, which is ignored — put your notes there.

### Writing timestamps

Timestamps (`start`, `stop`, `extrinsic`) are either a number of seconds (e.g. `12.345`) or a clock time `HH:MM:SS.mmm` (e.g. `00:02:09.123`; milliseconds optional).

!!! danger "The most common timestamp mistake"
    Always write all three clock parts: `01:30` means **1 hour 30 minutes**, *not* 1 minute 30 seconds. If in doubt, use plain seconds.

### Writing pixel coordinates

Pixel coordinates (`start_location`, `center`, `north`) are written `"(x, y)"` — **including the quotes**, since the cell contains a comma. `x` is the distance in pixels from the *left* edge of the frame and `y` from the *top* edge, exactly as an image viewer (GIMP, Photoshop, etc.) reports them when you hover over a paused frame.

!!! tip "How to find a pixel coordinate"
    Pause the video on a good frame, take a screenshot (or export the frame), open it in an image viewer, and hover the mouse over the point you want — the viewer shows the `(x, y)` position of the cursor.

## Next

- [runs.csv →](runs.md)
- [calibs.csv →](calibs.md)
