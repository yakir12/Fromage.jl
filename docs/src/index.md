```@raw html
---
layout: home

hero:
  name: "Fromage 🧀"
  text: "From videos to tracks"
  tagline: Organise, calibrate, and track your experiment videos — and get real-world coordinates out.
  image:
    src: /logo.png
    alt: Fromage
  actions:
    - theme: brand
      text: Get started
      link: /get-started
    - theme: alt
      text: Prepare your data
      link: /data-folder
    - theme: alt
      text: View on GitHub
      link: https://github.com/yakir12/Fromage.jl

features:
  - icon: 🎥
    title: You film, Fromage tracks
    details: Point it at a folder with your videos and two small spreadsheet files, run one command, and every animal in every run is tracked automatically.
  - icon: 📏
    title: Real-world coordinates
    details: Film a checkerboard once per setup and your tracks come out in centimetres on the arena floor — not pixels — with lens distortion and perspective corrected.
  - icon: 🔎
    title: Catches your mistakes first
    details: Before anything runs, every row of your spreadsheets is checked — missing files, impossible timestamps, undetectable checkerboards — and all problems are reported at once.
  - icon: 🍿
    title: A video you can check
    details: Every analysis ends with one diagnostic video showing all your runs with the track drawn on top, so you can immediately see whether the tracker followed the right thing.
---
```

## What is Fromage?

Fromage is the Dacke lab's tool for turning experiment videos into usable tracks.

You have video recordings of **runs** — an animal (or any other target) moving through an arena — and video recordings of **calibrations** — a checkerboard filmed in that same arena. Fromage tracks the target in every run, pairs each run with its calibration, and converts the tracked pixel coordinates into real-world coordinates (e.g. cm on the arena floor). It also produces a diagnostic video so you can quickly check, run by run, that the tracker followed the right thing.

You don't need to be a programmer to use it. If you can organise your videos in a folder and fill in a spreadsheet, you can use Fromage — the only Julia you'll type is two lines:

```julia
using Fromage
runs = main("the/path/to/your/data/folder")
```

Ready? [Get started →](get-started.md)
