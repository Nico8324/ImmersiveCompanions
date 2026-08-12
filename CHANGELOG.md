# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Now an Xcode project.** The app was a single Swift file built by `build.sh`; it is now
  the `ImmersiveCompanions` target, and the shell script and the `CinemaConverter/` folder
  are gone. Two settings differ from Xcode's macOS template on purpose: the App Sandbox is
  off, because a sandboxed app can neither run the `ffmpeg` on your machine nor write beside
  the file you gave it, and `Support/Info.plist` supplies `CFBundleDocumentTypes`, which has
  no `INFOPLIST_KEY_` equivalent and without which Open With and Dock drops stop working.

### Added

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
