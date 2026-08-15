# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The Dolby Vision route now checks its own claim.** `Verification` asked AVFoundation
  whether a file was playable, which says nothing about whether the RPU `dovi_tool`
  extracted actually landed back on the right frames — a misaligned re-injection still
  opens, enumerates and plays. For a file that went through the Dolby Vision route, ffprobe
  now reads the frame side data over a couple of seconds at the start of the file and again
  near the end, and the conversion fails if "Dolby Vision RPU" isn't there. Cheap by
  `-read_intervals`, which limits ffprobe to the seconds named rather than decoding
  everything in between; two points a feature apart rather than one, so a rebuild that only
  went wrong partway through doesn't pass on the strength of its first few frames.

### Changed

- **One audio track per language, not every track.** A remux carrying TrueHD Atmos
  alongside the AC-3 core it was struck from used to keep both — two near-identical 5.1
  tracks, the length of the film again in disk for nothing — and transcoded lossless
  multichannel to AAC, a codec Apple uses for stereo, not surround. Streams are now grouped
  by language, and each keeps one main track, chosen by what survives the trip without
  transcoding: E-AC-3 first, since it's the only one of these that can carry Atmos's JOC
  metadata, then AC-3, then whatever else MP4 already holds. Only when nothing in the
  language passes through does anything get transcoded, and multichannel now lands on
  E-AC-3 at 640 kbps rather than AAC — stereo still gets AAC at 256 kbps. Commentary and
  accessibility mixes (`comment`, `hearing_impaired`, `visual_impaired` in the source's
  disposition, or a title that says "commentary") are a different programme, not a
  duplicate, so they're kept alongside the main track rather than dropped or folded into it.
- **A forced subtitle track being dropped now says so specifically.** PGS and VobSub have
  nowhere to go in MP4 and always got dropped; the note used to just count them. A forced
  track among the dropped ones carries dialogue or on-screen text a viewer can't get any
  other way, and losing it changes what the film contains rather than merely trims a spare
  — so it now gets its own note: "a forced subtitle track was dropped — the film may need an
  external subtitle file". Text-based forced subtitles that do survive into `mov_text` keep
  their forced disposition in the output, which they weren't asked to before.
- **Audio and subtitle language tags are now written explicitly**, with
  `-metadata:s:a:N language=` and `-metadata:s:s:N language=`, rather than left to travel
  through ffmpeg's mapping implicitly. A file was observed coming out of the Dolby Vision
  route with `language: und` on every track — the intermediate ffmpeg builds for MP4Box to
  import carries the audio and subtitles alone, and nothing was asking it to keep the tag.
  Writing it explicitly onto that intermediate is what fixes it: MP4Box's default import
  already reads a track's language straight off the file it's given, so what matters is that
  the file it's given has the tag on it.

## [0.1.0] - 2026-08-13

The first tagged release. It converts what Immersive Cinema cannot open, and — since the
library dropped its own optimizer — it is now the only thing that re-encodes for it.

### Added

- **`HDRMetadata`**, which carries the mastering display and content light level across a
  re-encode. ffprobe reports both on the frames rather than the stream — asked for
  `-show_streams` on a Dolby Vision remux, the only side data that comes back is the DOVI
  configuration record — so they need a probe of their own. x265 drops them unless handed
  them, and Apple's specification asks for them (1.35); without them a re-encode tone maps
  differently from its source on any display that reads the metadata.
- **[`Docs/measurements.md`](Docs/measurements.md)**, the record of the 42 encodes the
  settings below came out of — including the six that measured nothing at all, and the two
  that reversed a confident expectation.
- **Immersive Companions**, a Mac app that rewraps video into MP4 that Immersive Cinema can
  open. AVFoundation has no Matroska demuxer — `AVURLAsset` won't open an MKV at all, even
  when the streams inside are H.264 and AAC — and the app can't optimize its way out,
  because its optimizer *is* an `AVAssetReader`. So the fix happens before import.
- **Streams are copied wherever possible** rather than re-encoded. A typical MKV is H.264
  or HEVC with AAC or AC-3, so the usual result is a stream copy: seconds, and byte-for-byte
  identical picture. Chapters, HDR colour tags, mastering-display metadata, track languages
  and every audio track come across with it.
- **Dolby Vision rebuilt as profile 8.1.** A Blu-ray rip is profile 7, which decodes on no
  Apple device, so it used to be flattened to its HDR10 base. `dovi_tool` rewrites the RPU
  and GPAC writes the `dvvC` box that ffmpeg's MP4 muxer cannot. Profile 5 is converted too,
  where the gain is larger — its base is IPT-graded and isn't watchable as HDR10 at all.
- **Optimizing Dolby Vision without losing it.** Immersive Cinema's optimizer rebuilds the
  picture through `AVAssetWriter`, and nothing public puts an RPU back afterwards. Here the
  RPU is extracted, the base layer re-encoded at the library's own target, and the RPU
  threaded back between the slices. Verified at 66.5 Mbps in, 22 Mbps out, profile 8.1
  intact. Off by default.
- **The output is verified before it's called done.** `AVURLAsset` is loaded, the video
  track and duration checked, and an `AVAssetReader` constructed — the same thing the
  library does first. A file that fails is deleted rather than left looking importable.
- **A preflight disk-space check**, so a job that can't fit fails immediately rather than an
  hour in.

- **Each row says what's in the file.** Codec, frame size, dynamic range or Dolby Vision
  profile, how many audio and subtitle tracks, and how long it runs — read from the same
  probe the conversion is planned from, so what you see is what it decided on. Alongside it:
  the size waiting, per cent and time remaining while it converts, and size in → size out
  when it's done.
- **A still from the film beside each row**, read as soon as the file is queued rather than
  when its turn comes. Which frame to take is Immersive Cinema's own rule, transcribed —
  sampled from the opening, skipping anything essentially black, so a fade in or a
  distributor card doesn't become the picture. How to take it can't be: the library uses
  `AVAssetImageGenerator`, which is exactly what this app exists because you can't do, so
  `ffmpeg` decodes the frame and only the choosing is shared. While a file converts, how far
  through it is runs across the bottom of its still — white over a dimmed track, where the
  library draws it on a film you're partway through.
- **HDR stills are converted before they're shown.** A frame comes out of ffmpeg still
  encoded the way it was graded — PQ or HLG, in Rec. 2020 — and carrying no profile to say
  so, which is what a washed-out, grey-blacked thumbnail is. It's now labelled with the
  colour space it was actually encoded in and redrawn into sRGB, handing the conversion to
  ColorSync. Deliberately not ffmpeg's `zscale`, which needs libzimg that Homebrew's bottle
  doesn't build. Colorimetric rather than a true tone map: no highlight roll-off.
- **A context menu on each row** — show in Finder, try again, and remove. Removing the file
  being converted stops it; the rest of the queue carries on.
- **A status bar** under the list, counting what's converted and what failed, and saying so
  when Dolby Vision is being optimized.
- **Retry** on a row that failed or was stopped, for the failures that are worth another go
  without changing anything — a disk since emptied, a tool since installed.
- **The empty window says whether Dolby Vision can be rebuilt**, rather than leaving a
  missing toggle to look like a missing feature.
- **Files can be dropped once the list has replaced the drop zone.**

### Changed

- **x265 instead of VideoToolbox**, at both encode sites, preset `ultrafast` with
  `signhide=1`. Measured on a 4K Dolby Vision feature against its own 74 Mbps source:
  **VideoToolbox needs 1.87× the bit rate for the same picture** — it reaches VMAF 93.74 at
  30 Mbps where x265 is already there at 16. The output is both better and smaller; the cost
  is time, about three hours for a feature against fifty minutes, paid once for a file kept
  for good. The preset sounds wrong and isn't: across five presets the whole spread was 0.44
  VMAF and none of it came from search effort — it was two switches, SAO and adaptive
  quantisation, which x265 turns on from `veryfast` up and which each cost about 0.19 on
  dark grainy film.
- **The ladder targets what Apple ships, not what they publish.** Their tables are
  explicitly "one possible set of bit rate variants", and their own reference stream runs
  24.33 Mbps at 4K where the table gives 20 — their *second* rung is the table figure less
  the 24 fps reduction, and their top rung is half again above it. Hence
  `appleTopRungMultiplier`, which reproduces their 4K and 1080p rungs to within 3%. It
  arrives now because it is only honest with an encoder good enough to earn it.
- **`referenceBitrate` is one function.** The test for "is this worth re-encoding" and the
  rate it is encoded to were separate calculations that happened to agree, and the
  multiplier broke that: a 22 Mbps source passed a gate measured against 16 Mbps and came
  out at 24, larger than it went in.
- **Split into layers** — `App/`, `Model/`, `ViewModel/`, `Services/`, `Views/`. The
  2,181-line `CinemaConverter.swift` is now fourteen files, divided along the `// MARK:`
  boundaries that were already there. `Job` and its `Status` move out of `ConversionQueue`:
  the queue owns the work, `Job` owns what a row has to say about a file.

- **Now an Xcode project.** The app was a single Swift file built by `build.sh`; it is now
  the `ImmersiveCompanions` target, and the shell script and the `CinemaConverter/` folder
  are gone. Two settings differ from Xcode's macOS template on purpose: the App Sandbox is
  off, because a sandboxed app can neither run the `ffmpeg` on your machine nor write beside
  the file you gave it, and `Support/Info.plist` supplies `CFBundleDocumentTypes`, which has
  no `INFOPLIST_KEY_` equivalent and without which Open With and Dock drops stop working.

### Fixed

- **A re-encoded picture lost its colour description.** `hevc_videotoolbox` writes the
  matrix coefficients into the bitstream and silently drops the transfer characteristic and
  the primaries, so a file encoded with all three asked for came out of ffprobe as
  `color_space=bt2020nc, color_transfer=unknown, color_primaries=unknown`. ffmpeg records
  what it was told at the stream level; VideoToolbox never puts it in the stream. For HDR
  that was the whole problem — a PQ picture with no transfer characteristic is the washed
  out grey one, which is exactly what the code's own comment warned about. The values are
  now stamped into the VUI with the `hevc_metadata` bitstream filter. Affects both the plain
  re-encode and the Dolby Vision base layer.
- **Every file opened from outside made another window.** The scene was a `WindowGroup` —
  the multi-window one — and the app declares itself a viewer of movie files, so each Open
  With, Dock drop and `open -a` arriving while it ran opened a fresh window onto the same
  queue: several identical lists, stacked. There is one queue because there is one encoder,
  so there is one window now.
- **The queue stopped after the first file.** `runNext` called itself when a job finished,
  from inside the scope that still held `isRunning`, so the call turned back at its own
  guard and everything behind it waited for a conversion that had already ended. Adding
  another file unstuck it, which is why it looked intermittent. It's a loop now.
- **Progress could be written to the wrong row.** The running job held its position in the
  array rather than its identity, so clearing finished rows above it during a conversion
  moved the row it was updating — or moved it off the end. Jobs are found by identity now.
- **HEVC copied out of Matroska was tagged `hev1`**, which Apple doesn't accept. The file
  opened, enumerated its tracks and read through `AVAssetReader` while reporting
  `isPlayable == false` — so the library would have imported it and then refused to play it.
  Retagging as `hvc1` is a relabel, not a re-encode.
- **The re-encode path ignored the library's own targets**, encoding at the source's raw bit
  rate with no ceiling, no codec ratio, no key frame interval and no colour tags on SDR.
  `PlaybackTarget` is now transcribed rather than approximated — notably AV1 needs 1.3× its
  own rate in HEVC, not the same.
- **Dolby Vision was discarded silently.** What happens to it is now reported, including the
  case where a profile 5 base would look wrong rather than merely lose its metadata.

### Removed

- `+faststart`. It front-loads the index for players reading over HTTP, which is worth
  nothing for a local library, and costs a rewrite proportional to the whole file.

[Unreleased]: https://github.com/Nico8324/ImmersiveCompanions/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Nico8324/ImmersiveCompanions/releases/tag/v0.1.0
