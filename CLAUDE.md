# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**Immersive Companions** — the Mac companion app to
[Immersive Cinema](https://github.com/Nico8324/Immersive-Cinema), a multiplatform media app
(iOS/iPadOS/macOS/tvOS/visionOS). Immersive Cinema can't spawn processes on an Apple TV, so
anything that needs a command-line tool lives here instead, as a step that runs on a Mac
before a file is imported into the library.

What it does: rewraps MKV — and anything else AVFoundation has no demuxer for — into MP4,
and rebuilds Dolby Vision as profile 8.1 so Apple devices actually get it. The app was
previously called Cinema Converter and built by a shell script; it is now this Xcode
project, and the two names refer to the same thing. The source kept its old name —
`ImmersiveCompanions/CinemaConverter.swift`.

## Build

```bash
xcodebuild -project ImmersiveCompanions.xcodeproj -scheme ImmersiveCompanions build
```

macOS only (`SDKROOT = macosx`). Pass `CODE_SIGNING_ALLOWED=NO` if you aren't signing.
There are test targets (`ImmersiveCompanionsTests`, `ImmersiveCompanionsUITests`) but no
meaningful tests in them — verification is done by running the app against real media, and
there is no lint step.

The project uses **file-system synchronized groups** (`objectVersion 77`): a file added to
the `ImmersiveCompanions/` folder joins the target with no project-file edit, so a stray
scratch file gets compiled into the app.

Two build settings are load-bearing and were changed from Xcode's template defaults:

- **`ENABLE_APP_SANDBOX = NO`.** A sandboxed app cannot execute `/opt/homebrew/bin/ffmpeg`
  and cannot write the MP4 beside the original. Turning the sandbox back on breaks the app
  entirely, not partially.
- **`INFOPLIST_FILE = Support/Info.plist`**, alongside `GENERATE_INFOPLIST_FILE = YES` —
  Xcode merges the generated keys into that file. It exists because `CFBundleDocumentTypes`
  is an array of dictionaries and there is no `INFOPLIST_KEY_` for it. Without it, Open
  With, Dock-icon drops and `open -a` stop reaching the app. It lives in `Support/` rather
  than `ImmersiveCompanions/` so the synchronized group doesn't also copy it in as a
  resource.

The app requires `ffmpeg`/`ffprobe` on the machine to do anything, and `dovi_tool`/`MP4Box`
for the Dolby Vision route:

```bash
brew install ffmpeg dovi_tool gpac
```

## Architecture

One Swift file, divided by `// MARK:` sections. SwiftUI, `@Observable`, Swift 6.

The pipeline for one file: `Probe.read` (ffprobe → JSON) → `Plan.init` (decides copy vs
re-encode, builds ffmpeg arguments) → either the plain ffmpeg run or `runDolbyVision`'s
three-tool route → `Verification.check` → the row updates in the UI.

`ConversionQueue` owns the queue and runs jobs **one at a time** — the encoder is
fixed-function hardware, so a second conversion alongside the first finishes no sooner and
just competes for disk. It holds the running `Process` so `cancelAll` can terminate it; a
process that ends by signal rather than exit is reported as `CancellationError`, and the
half-written output is deleted. Jobs are updated **by identity, never by index** — the list
can have rows removed underneath a running conversion.

The scene is a `Window`, not a `WindowGroup`. The app declares itself a viewer of movie
files, and a `WindowGroup` opens a fresh window for every Open With, Dock drop and `open -a`
— all onto the same queue, which produced several identical lists stacked on each other.

### Load-bearing decisions

These are the things that will look arbitrary and aren't. Read the doc comments at each site
before changing them.

**Copy, don't re-encode.** The bias throughout `Plan` is toward a stream copy. Immersive
Cinema has its own optimizer that knows Apple's bit-rate ladder and decides properly whether
a file is worth re-encoding; doing that here as well spends a generation of quality on a
judgement this app isn't making. Don't add re-encode decisions the library could make after
import.

**HEVC must be tagged `hvc1`, never `hev1`.** Copied straight out of Matroska it lands as
`hev1`, and the file then opens, enumerates its tracks and reads through `AVAssetReader`
while reporting `isPlayable == false`. Every path that produces HEVC carries `-tag:v hvc1`.

**The colour description has to be written into the bitstream.** `hevc_videotoolbox` writes
the matrix coefficients and silently drops the transfer characteristic and the primaries, so
`-color_trc`/`-color_primaries` alone produce `color_transfer=unknown,
color_primaries=unknown`. `DynamicRange.bitstreamColourArguments` stamps them in with the
`hevc_metadata` bitstream filter. For HDR this is the whole game — a PQ picture with no
transfer characteristic is the washed-out grey one.

**`PlaybackTarget` is a transcription, not an approximation.** It is Immersive Cinema's own
encode target copied across — the ladder, the codec ratios (AV1 needs 1.3× its own rate in
HEVC), the 2s key frame interval, the HDR uplift. Deliberately duplicated rather than shared
so this app stands alone; if the library's ladder changes, change this with it. `Layout` and
`Thumbnail`'s sampling rule are transcriptions of the same kind, from `Constants` and
`MediaLibrary.thumbnailData`.

**Dolby Vision needs all three tools.** ffmpeg demuxes but can't rewrite an RPU; `dovi_tool`
rewrites the RPU but doesn't mux; ffmpeg's MP4 muxer can't write the `dvvC` box that marks a
track as Dolby Vision — only GPAC will. Hence video out to a raw Annex B stream, through
`dovi_tool`, back in through `MP4Box`, with audio and subtitles muxed in at the end. The
output is `dvp=8.hdr10` (profile 8.1) so a player that doesn't know Dolby Vision still sees
correct HDR10. Without `dovi_tool` and `MP4Box` the file still converts, as its HDR10 base
layer — never refuse the job over a missing optional tool.

**Never resize or resample.** The RPU re-injection in the Optimize path only lines up
because the encode changes neither frame count nor frame rate.

**Verify before calling it done.** ffmpeg exiting zero does not mean the file plays —
`Verification` asks AVFoundation the same questions the library's optimizer asks first. A
file that fails is deleted rather than left looking importable.

**No `+faststart`.** It front-loads the index for HTTP playback, which is worth nothing for
a local library, and costs a rewrite proportional to the whole file (~11% on a 543 MB
sample).

**Stills are decoded by ffmpeg, converted by ColorSync.** `AVAssetImageGenerator` is exactly
what this app exists because you can't do — the file isn't converted yet. And ffmpeg's
`zscale`, which would tone map, needs libzimg that Homebrew's bottle doesn't build. So an
HDR frame comes over untouched as 16-bit PNG, is labelled with the colour space it was
graded in, and is redrawn into sRGB. Colorimetric, not a true tone map.

### Progress reporting

Three mechanisms in `extension Process`, because the tools differ. `Process.run` parses
`-progress pipe:1`'s `out_time_us`, which measures the timeline and stays honest whether
streams are copied or encoded. `runPiped` and `runWatchingOutput` watch the output file grow
instead, because `dovi_tool` and `MP4Box` say nothing useful. The fraction weights in
`runDolbyVision` (0.05 / 0.65 / 0.10 / 0.05 / 0.15) reflect how long each step actually
takes, not an even split.

## Third-party tools are invoked, never bundled

Do not vendor `ffmpeg` or link against it. It is LGPL, and shipping a copy inside an app
carries obligations — notices, the right to relink — that a personal tool has no business
taking on. Calling a program the user installed is an ordinary use of it, not a
distribution. `Tools` locates binaries in `/opt/homebrew/bin`, `/usr/local/bin`,
`/opt/local/bin`, `/usr/bin`. See [NOTICE.md](NOTICE.md).

Assume the stock Homebrew bottle: it has no `libzimg` and no `libplacebo`, so anything built
on `zscale` will fail on a plain `brew install ffmpeg`.

## Documentation and comment style

This repo carries far more prose than its size suggests, and it is part of the work. Doc
comments explain *why* a decision was made and what breaks otherwise, in full sentences and
British spelling ("optimize" is US-spelled to match the API, "colour"/"licence" are not).
Match that register rather than adding bare `// what this line does` comments.

Every behavioural change should land in [CHANGELOG.md](CHANGELOG.md) under `[Unreleased]`
(Keep a Changelog format; nothing has been tagged yet), and in [README.md](README.md) if it
changes what the app does to a file. The README documents known limits honestly — untested
paths are labelled as untested — and that honesty should be preserved.

Licence is proprietary. See [LICENSE](LICENSE).
