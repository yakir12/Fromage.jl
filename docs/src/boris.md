# Runs coded in BORIS

If you mark your runs in [BORIS](https://github.com/olivierfriard/BORIS) — a START and a STOP for each stretch of a behaviour such as `Roll` — you can give Fromage BORIS's export instead of writing a [`runs.csv`](runs.md). Each START/STOP pair becomes one **segment**, and you say which pairs make up each run.

You do three things: export the observation from BORIS, add two columns to the export, and point Fromage at it.

## 1. Export from BORIS

In BORIS, export the observation's events as **Tabular events**, in **csv** format (not tsv, xlsx, or "Aggregated events"). One file per observation.

## 2. Add `run_id` and `rectification_id`

Open the file in a spreadsheet and add two columns: **`run_id`** and **`rectification_id`**. Leave every column BORIS wrote as it is.

- **Fill both on every START and STOP row** of the behaviour you track. Rows of other behaviours can stay blank.
- **Pairs that share a `run_id` are the segments of one run**, in the file's order. So a roll that was interrupted and coded as three pairs is one run if you give the three the same `run_id`.
- **A run's pairs must be next to each other**: no other pair of the behaviour you track may sit between them. Rows of other behaviours may, since they are set aside first, and that is exactly what an interrupted roll looks like. A run whose pairs are split is reported before any video is opened, along with the export rows of its other pairs.
- `rectification_id` must match a `rectification_id` in your [`rectifications.csv`](rectifications.md), exactly as in a `runs.csv`, and `run_id` follows the same rules too: it becomes the name of the run's track file (see [runs.csv](runs.md#Runs-made-of-several-segments)).

### A worked example

Here is a small export, trimmed to the columns that matter here. The *row* numbers are not a column of the file; they count the data rows from 1, the way Fromage numbers them when it reports an issue. The beetle `JK` rolls, stops, then rolls again; the second roll is interrupted by a dance:

| *row* | Subject | Behavior | Behavior type | Time | Media file name |
| --- | --- | --- | --- | --- | --- |
| *1* | JK | Roll | START | 12.400 | E:/coding/T1\_group1.MP4 |
| *2* | JK | Roll | STOP | 31.900 | E:/coding/T1\_group1.MP4 |
| *3* | JK | Roll | START | 45.000 | E:/coding/T1\_group1.MP4 |
| *4* | JK | Roll | STOP | 58.200 | E:/coding/T1\_group1.MP4 |
| *5* | JK | Dance | START | 58.900 | E:/coding/T1\_group1.MP4 |
| *6* | JK | Dance | STOP | 63.100 | E:/coding/T1\_group1.MP4 |
| *7* | JK | Roll | START | 63.500 | E:/coding/T1\_group1.MP4 |
| *8* | JK | Roll | STOP | 80.000 | E:/coding/T1\_group1.MP4 |

The same export once you have added the two columns:

| *row* | Subject | Behavior | Behavior type | Time | Media file name | run\_id | rectification\_id |
| --- | --- | --- | --- | --- | --- | --- | --- |
| *1* | JK | Roll | START | 12.400 | E:/coding/T1\_group1.MP4 | **run1** | **morning** |
| *2* | JK | Roll | STOP | 31.900 | E:/coding/T1\_group1.MP4 | **run1** | **morning** |
| *3* | JK | Roll | START | 45.000 | E:/coding/T1\_group1.MP4 | **run2** | **morning** |
| *4* | JK | Roll | STOP | 58.200 | E:/coding/T1\_group1.MP4 | **run2** | **morning** |
| *5* | JK | Dance | START | 58.900 | E:/coding/T1\_group1.MP4 | | |
| *6* | JK | Dance | STOP | 63.100 | E:/coding/T1\_group1.MP4 | | |
| *7* | JK | Roll | START | 63.500 | E:/coding/T1\_group1.MP4 | **run2** | **morning** |
| *8* | JK | Roll | STOP | 80.000 | E:/coding/T1\_group1.MP4 | **run2** | **morning** |

- **`run1`** is an ordinary run: one pair, rows 1 and 2, so one segment.
- **`run2`** is the interrupted roll: two `Roll` pairs, rows 3–4 and 7–8, share one `run_id`, so they are two segments of one run, tracked as one track file, `run2.csv`. The `Dance` rows between them stay blank, and they do not break the run up: only another `Roll` pair there would.
- Both the START and the STOP row of every `Roll` pair carry the two values.

The real export has more columns than shown — `Observation id`, `Source`, `Time offset (s)`, `Media duration (s)`, `FPS` and others. Leave them alone; Fromage reads what it needs from them.

!!! note "The whole file"
    This is the example in full, exactly as BORIS writes it plus the two added columns. Given the video `T1_group1.MP4` beside it and a `morning` rectification, `verify` reports nothing wrong and returns three segments: `run1` from 12.4 s to 31.9 s, and `run2` from 45.0 s to 58.2 s and from 63.5 s to 80.0 s.

    ```csv
    Observation id,Observation date,Description,Observation duration,Observation type,Source,Time offset (s),Media duration (s),FPS,Subject,Behavior,Behavioral category,Behavior type,Time,Media file name,Image index,Image file path,Comment,run_id,rectification_id
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Roll,,START,12.400,E:/coding/T1_group1.MP4,620,NA,,run1,morning
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Roll,,STOP,31.900,E:/coding/T1_group1.MP4,1595,NA,,run1,morning
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Roll,,START,45.000,E:/coding/T1_group1.MP4,2250,NA,,run2,morning
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Roll,,STOP,58.200,E:/coding/T1_group1.MP4,2910,NA,,run2,morning
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Dance,,START,58.900,E:/coding/T1_group1.MP4,2945,NA,,,
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Dance,,STOP,63.100,E:/coding/T1_group1.MP4,3155,NA,,,
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Roll,,START,63.500,E:/coding/T1_group1.MP4,3175,NA,,run2,morning
    T1_group1,2026-04-08 10:15:02.311,,85.0,Media file(s),player #1:E:/coding/T1_group1.MP4,0,90.000,50.000,JK,Roll,,STOP,80.000,E:/coding/T1_group1.MP4,4000,NA,,run2,morning
    ```

### Where the videos are

Fromage finds each pair's video in the export's `Source` list, by file name only — the folders BORIS recorded (`E:/coding/` above) are on the computer that did the coding. Put the videos beside the export, or say where they are with a `path` column, as in a [`runs.csv`](data-folder.md#Other-layouts).

`start` and `stop` come from BORIS's `Time`, less its `Time offset (s)`.

## 3. Point Fromage at the export

Put the file in your data folder and name it as the runs file:

```julia
main("/path/to/data"; runs_file = "T1_group1.csv")
verify("/path/to/data"; runs_file = "T1_group1.csv")   # to check it first
```

The behaviour tracked is `Roll` unless you say otherwise: `boris_behavior = "Dance"` tracks the `Dance` pairs instead. Every other behaviour's rows are ignored. Fromage recognises a BORIS export by its own column names, so a `runs.csv` is never mistaken for one.

## What else to know

- **A pair that crosses into the next video** (the camera split the recording) is split for you into one segment per video, all under the pair's `run_id`.
- **Every other `runs.csv` column works too.** Add `start_location`, `target_width`, `whole_run`, … as columns, exactly as in a [`runs.csv`](runs.md#Optional-columns). A pair's START and STOP rows must agree on them.
- **Your own columns are kept** in what `verify` returns, beside the export's `subject`, `behavior`, `observation_id` and `comment`. Where a pair's two rows differ, you see both values, START's first: `before | after`.
- **Checks.** Besides everything checked in a `runs.csv`, Fromage reports a START with no STOP (or a STOP with no START) within a subject, a POINT event of the tracked behaviour, a blank `run_id`, an observation that is live or made from images instead of video, more than one player, a `Time` outside the observation's videos (which is also how an observation coded with the video's creation date as its offset shows up), and a video whose frame rate is not the `FPS` BORIS used. Issues name the export's own rows — `rows 11 and 12` — so you can find them in the file you edit.
- Pairs of different subjects may share a `run_id`; Fromage does not check what your runs mean, only what it needs to track them.

## Next

- [rectifications.csv →](rectifications.md)
- [Your results →](results.md)
