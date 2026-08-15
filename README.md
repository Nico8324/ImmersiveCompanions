# Immersive Companions

![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6.0-orange)
![Dolby Vision](https://img.shields.io/badge/Dolby%20Vision-profile%208.1-blueviolet)
![License](https://img.shields.io/badge/license-proprietary-red)

The Mac companion to [Immersive Cinema](https://github.com/Nico8324/Immersive-Cinema). It
rewraps video into MP4 the library can open — keeping Dolby Vision, HDR, one audio track
per language and every subtitle MP4 will carry, shaped the way Apple ships its own.

<p align="center">
  <img src="Docs/window.png" alt="Immersive Companions’ window, showing its drop target" width="680">
</p>

## Contents

- [Why it exists](#why-it-exists)
- [What it does to the file](#what-it-does-to-the-file)
- [Dolby Vision](#dolby-vision)
- [It checks its own work](#it-checks-its-own-work)
- [Requirements](#requirements)
- [Building](#building)
- [Using it](#using-it)
- [Known limits](#known-limits)

## Why it exists

Immersive Cinema is multiplatform — iOS, iPadOS, macOS, tvOS, visionOS — and that shapes
what it can be. It can't spawn a process on an Apple TV, so it can't lean on the
command-line tools that solve certain problems properly. Anything that needs them belongs
out here, on the Mac, where a library gets prepared before it's imported.

The problem that needs them: AVFoundation has no Matroska demuxer. Not "MKV plays badly" —
`AVURLAsset` refuses to open one at all:

```
load(.isPlayable, .duration)  FAILED: Cannot Open
loadTracks                    FAILED: Cannot Open
AVAssetReader                 FAILED: Cannot Open
```

That holds even when the streams inside are H.264 and AAC, which the same framework plays
perfectly out of an MP4, and it holds if you rename the file — AVFoundation reads the bytes,
finds an EBML header rather than ISO BMFF, and stops.

The consequence worth understanding: Immersive Cinema **can't optimize its way out of this**.
Its optimizer is `AVAssetReader` → `AVAssetWriter`, so the step that would fix the container
is the step that can't read it. The fix has to happen before the file reaches the library.

That's this app. It drives the `ffmpeg` already on your Mac, writes an MP4 beside the
original, and leaves the original alone.

## What it does to the file

As little as it can get away with. Immersive Cinema has its own optimizer, which knows
Apple's bit rate ladder and decides properly whether a file is worth re-encoding. Doing that
here as well would spend a generation of quality on a judgement this app isn't the one
making. So:

| Stream | Kept as-is | Re-encoded |
| --- | --- | --- |
| Video | H.264, HEVC | everything else → HEVC (VideoToolbox), at the source's own bit rate |
| Audio | AAC, AC-3, E-AC-3, ALAC, MP3 | everything else → E-AC-3, 640 kbps surround / AAC, 256 kbps stereo |
| Subtitles | SRT, ASS, WebVTT → `mov_text` | PGS and VobSub are dropped — MP4 has nowhere to put them |

A typical MKV is H.264 or HEVC with AAC or AC-3, so the usual result is a **stream copy**:
a couple of seconds, byte-for-byte identical picture, no quality lost. The row tells you
which you got — "Rewrapped, nothing re-encoded" or what was converted and why.

Also carried across: HDR colour tags, mastering-display and content-light metadata, and
per-track languages. Cover-art "video" streams are skipped, so a poster doesn't become the
film. **Chapters are dropped, on every route, on purpose** — Apple's own store encodes don't
carry them, so matching what Apple ships is the rule here, not a limitation to work around.

**Letterbox bars are cropped away, but only when Dolby Vision's own metadata says where they
are and the picture is already being re-encoded.** Apple's own store encodes carry no bars —
the frame *is* the active picture — and a Dolby Vision RPU's Level 5 metadata already
declares exactly where a studio put its own, so there's no bar-detection heuristic here, only
a read of what the source already says. A file without that metadata, or without a re-encode
happening anyway, keeps its bars: cropping needs a real pixel move, and the lossless
shortcuts — an SPS conformance window, MP4 clean aperture — both play back wrong through
AVPlayer. See [Dolby Vision](#dolby-vision) below.

### Audio: one main track per language

A film's audio is grouped by language rather than mapped track for track. A remux carrying
TrueHD Atmos alongside the AC-3 core it was struck from used to keep both — two
near-identical 5.1 tracks, the length of the film again in disk for nothing. Now each
language keeps one main track, chosen by what survives the trip without transcoding at all:

1. **E-AC-3**, copied — the only one of these that can carry Atmos's JOC metadata across
2. **AC-3**, copied
3. **AAC, ALAC or MP3**, copied
4. Otherwise, the richest remaining source — most channels wins — transcoded to **E-AC-3 at
   640 kbps** if it has more than two channels, **AAC at 256 kbps** if it doesn't

Commentary and accessibility mixes are a different programme, not a duplicate of the main
one, and survive alongside it regardless of language: anything the source's disposition
marks `comment`, `hearing_impaired` or `visual_impaired`, or whose title says "commentary",
is kept and — if it isn't already a format MP4 holds — transcoded by the same rule above.
The row's summary says what happened: "TRUEHD → E-AC-3", "2 duplicate audio tracks
dropped".

Every surviving track keeps the language tag it came in with, written explicitly rather
than left to travel through ffmpeg and, on the Dolby Vision route, GPAC implicitly — a file
was once observed coming out the far end with `und` on every track. ISO 639-2 *bibliographic*
codes (`chi`, `fre`, `ger`, and seventeen others) are rewritten to their *terminological*
pair (`zho`, `fra`, `deu`, …) on the way — GPAC's own import corrupts `chi` into `nor`
(Norwegian) on the Dolby Vision route, reproduced on the installed `MP4Box`, and every other
code in the pair passed the same import through untouched.

### Subtitles from a file beside the movie

A Blu-ray rip's major-language subtitles are usually PGS images, which have nowhere to go
in MP4 and get dropped — the row above. The remedy is supplying the text yourself: a plain
subtitle file named after the source, sitting in the same folder, is folded into the output
as a native `mov_text` track. It ends up **inside** the MP4, so the sidecar file can be
deleted once the conversion is done — this is the user-supplied equivalent of the text
files studios themselves hand Apple's own pipeline as iTT, and it's exactly the case PGS
subtitles exist for here.

Accepted extensions: `.srt`, `.ass`, `.ssa`, `.vtt`. The name has to start with the source's
own stem plus a dot — `Movie2.srt` is never mistaken for `Movie.mkv`'s subtitles — and can
carry dotted components in any order:

```
Movie.srt              no language tag written
Movie.eng.srt          language: eng
Movie.en.forced.srt    language: en, forced (auto-displays for foreign dialogue on Apple players)
Movie.fre.sdh.srt      language: fra, hearing-impaired
```

A 2- or 3-letter component is taken as an ISO 639 language tag and passed straight through —
there's no mapping table of our own beyond the ISO 639-2 bibliographic-to-terminological
normalisation every language tag in this app goes through (see above), so `Movie.fre.srt`
is written as `fra`. Otherwise whatever ffmpeg and MP4 accept is what gets written. `forced`
and `sdh` set their dispositions, and a file can carry both. An unrecognised component is
ignored rather than disqualifying the file.

Each file is checked before it's trusted with anything: unreadable or empty files are
skipped, and one whose last cue runs more than about ten minutes past the probed duration is
treated as belonging to a different cut of the film and skipped too — either way, the row's
summary says so rather than muxing in subtitles that quietly lie about where the film ends.
**The file has to be UTF-8** — ffmpeg expects it, and no charset conversion is attempted, so
a file in another encoding fails to mux the same way it fails to read here.

### When it does re-encode

This is the only place a re-encode happens for the library. Immersive Cinema used to carry
its own optimizer and no longer does — through `AVAssetWriter` it could reach only
VideoToolbox, which needs 1.87× the bit rate for the same picture, and it could not carry
Dolby Vision across at all. So what comes out of here is what gets kept, with nothing
downstream to correct it.

- **HEVC** via **x265**, tagged `hvc1`, at preset `ultrafast` with `signhide=1`
- **Bit rate** = `min(Apple's rung for the frame, what the source was already spending × a
  codec ratio)`. Rungs from the HLS Authoring Specification, chosen by pixel count rather
  than height, less 20% for 24 fps content as the specification asks, then **×1.5 — because
  Apple does not ship the top of their own published tables**. The codec ratio is 0.65 from
  H.264, 0.95 from VP9, **1.3 from AV1** — AV1 does more with its bits than HEVC can
- **Key frames** every 2 seconds, closed
- **Peak held to twice the average**, which is what the specification asks of VOD (1.30)
- **Main 10 / 10-bit / Rec. 2020** for HDR, **8-bit / Rec. 709** for SDR, with the mastering
  display and content light level carried across (1.35) and the colour description written
  into the bitstream as well
- **Never resized.** The frame that goes in is the frame that comes out

Two worked examples. A 1.8 Mbps VP9 file re-encodes at 1.66 Mbps, not Apple's rung for
1080p — detail a file has already thrown away doesn't come back when you spend more bits on
it. A 74 GB 4K Dolby Vision remux comes out at 22.9 GB, a 3.25× reduction, scoring **VMAF
96.8** against its own source with the Dolby Vision intact.

Every number above was measured rather than assumed, across 42 encodes.
**[The measurements are written up in `Docs/measurements.md`](Docs/measurements.md)** —
including the several that contradicted what this code used to do.

## Dolby Vision

Apple plays profiles 5 and 8.1. A Blu-ray rip is **profile 7** — base layer, enhancement
layer and an RPU — which decodes on no Apple device. The metadata is right there in the
file, though, and 8.1 is the profile it was always going to become. So if `dovi_tool` and
`MP4Box` are installed, the track is rebuilt rather than flattened:

| Source | What happens |
| --- | --- |
| Profile 7 | converted to 8.1, enhancement layer discarded (~10% smaller) |
| Profile 5 | converted to 8.1 — otherwise it's *unwatchable*, its base being IPT-graded |
| Profile 8 | signalling rewritten so it survives the trip into MP4 |
| No DV | untouched |

Three steps, because no single tool does all of it. ffmpeg demuxes but can't rewrite an
RPU; `dovi_tool` rewrites the RPU but doesn't mux; and ffmpeg's MP4 muxer **cannot write
the `dvvC` box** that marks a track as Dolby Vision — only GPAC will. So the video goes out
to a raw stream, through `dovi_tool`, and back in through `MP4Box`, while audio and
subtitles take the ordinary route and are added at the end. This route is also why
chapters are dropped everywhere, not just here: MP4Box's whole-file import of the
audio-and-subtitles intermediate used to turn ffmpeg's own chapter track into a phantom
`bin_data` stream once that intermediate also carried subtitle tracks, and excluding
chapters unconditionally removed that alongside matching what Apple's own encodes do.

It's written as `dvp=8.hdr10` — profile 8 with the HDR10 compatibility ID — so a player
that knows Dolby Vision gets Dolby Vision, and one that doesn't still sees correct HDR10.

Verified on a 4K profile 7 Blu-ray rip:

```
video: hevc tag=hvc1 3840x2160 yuv420p10le smpte2084
  Dolby Vision: profile 8.1  EL=0  RPU=1
```

### Optimizing without losing it

Immersive Cinema's optimizer rebuilds the picture through `AVAssetWriter`, and nothing
public puts an RPU back afterwards — so optimizing a Dolby Vision file *there* costs you the
Dolby Vision. That leaves a real choice between a fat file that keeps it and a lean one that
doesn't.

`dovi_tool` can do both halves, so with **Optimize Dolby Vision** switched on the round trip
happens here instead: the RPU comes out of the source, the base layer is re-encoded at the
library's own target, and the RPU goes back in between the slices. Every frame is where it
was — the encode changes neither frame count nor rate — so every RPU lands on the frame it
describes.

```
66.5 Mbps  →  22 Mbps        Dolby Vision: profile 8.1  RPU=1
```

Off by default. Converting is the job; re-encoding costs a generation of quality and real
time, and should be asked for. It applies only to Dolby Vision, because that's the only case
the library can't handle for itself.

**Letterbox bars come off on this route too, when Dolby Vision says where they are.** A
Dolby Vision RPU can carry Level 5 active-area metadata — the studio's own declaration of
where the bars sit, not a guess this app makes. Before the re-encode, three short samples
near the start, middle and end of the source are read back through `dovi_tool` and compared;
only when all three agree exactly, the offsets survive 4:2:0 subsampling, and what's left is
still a real picture does the crop go ahead. A film whose framing genuinely changes partway
through — an IMAX sequence opening into open matte — disagrees between samples and correctly
keeps its bars rather than being cropped to whichever one was read first.

```
3840×2160  →  crop=3840:1608:0:276        letterbox removed, Dolby Vision: profile 8.1
```

The bit rate is chosen for the cropped frame, not the padded one — `PlaybackTarget` already
picks its rung by pixel count for exactly this reason, a 2.39:1 feature without its bars
being three-quarters of a 4K frame rather than a full one. `dovi_tool`'s own `--crop` flag
zeroes the RPU's Level 5 offsets on the way through, so the metadata stops declaring bars
that the picture no longer has.

This is the one place the app ever resizes a frame, and it's still true that it never
resamples one: frame count and frame rate are untouched, which is what keeps every RPU
landing on the frame it was written for. Only the dead border goes, and only as a real crop
of real pixels — not the SPS conformance window or MP4 clean aperture that would be simpler
to write but don't play back correctly through AVPlayer.

A crop only ever happens alongside a re-encode: the plain rewrap route, and any file without
Dolby Vision Level 5 metadata, keep their bars.

## It checks its own work

ffmpeg exiting zero does not mean the file plays. A conversion can finish, produce an MP4
AVFoundation opens, enumerates and reads through `AVAssetReader` — and still get
`isPlayable == false`. That is exactly what happens when an HEVC track is tagged `hev1`
rather than `hvc1`, which is how HEVC arrives out of Matroska. ffmpeg has no opinion on it;
only the framework doing the playing does.

So the framework is asked, before the file is called done: `AVURLAsset` is loaded, the
video track and duration checked, and an `AVAssetReader` constructed — the same thing
Immersive Cinema's optimizer does first. A file that fails is deleted rather than left
looking importable.

For a file that went through the Dolby Vision route, that isn't enough — a misaligned
`inject-rpu` still opens, enumerates and plays; it just isn't Dolby Vision any more, and
AVFoundation has no opinion on that either. So ffprobe is asked directly for the one thing
that says so: RPU side data on the frames themselves, sampled over a couple of seconds at
the start of the file and again near the end, cheaply, with `-read_intervals` rather than
by decoding the whole thing. Missing it fails the conversion the same as an unplayable file.

It also refuses to start when the disk can't hold the result, rather than filling it and
failing an hour in.

## Requirements

| | |
| --- | --- |
| Build | Xcode 16 or later |
| Required | [ffmpeg](https://ffmpeg.org) |
| Optional | `dovi_tool` and `gpac`, for Dolby Vision |

```bash
brew install ffmpeg          # required
brew install dovi_tool gpac  # for Dolby Vision
```

Nothing is bundled, on purpose. ffmpeg is LGPL, and shipping a copy inside an app carries
obligations — notices, the right to relink — that a personal tool has no business taking on.
Invoking it as a separate process keeps that boundary clean. The app looks in
`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`, and says so plainly
if it finds nothing.

Without `dovi_tool` and `MP4Box` the file still converts — it just arrives as its HDR10
base layer, which beats refusing the job.

## Building

Open `ImmersiveCompanions.xcodeproj` and run, or:

```bash
xcodebuild -project ImmersiveCompanions.xcodeproj -scheme ImmersiveCompanions build
```

## Using it

Drop files on the window, use the **+** button, drop them on the Dock icon, or Open With
from Finder. Conversions run one at a time — the encoder is fixed-function hardware, so a
second one alongside the first finishes no sooner and just competes for disk.

Each row reads what the conversion read: codec, frame size, dynamic range or Dolby Vision
profile, how many audio and subtitle tracks, and how long the film runs — so you can see it
picked the picture and not the cover art before it spends an hour on it. While it converts
you get the percentage and roughly how much longer; when it's done, the size before and
after. Right-click a row to show it in Finder, try it again, or take it out of the list.

<p align="center">
  <img src="Docs/list.png" alt="Three files in the list, each with a still from the film" width="680">
</p>

The still beside each row is a frame from the file, chosen the way Immersive Cinema chooses
artwork on import: sampled from the opening, skipping anything essentially black, so a fade
in or a distributor card doesn't become the picture. It has to be decoded with `ffmpeg`
rather than `AVAssetImageGenerator` for the same reason the app exists at all — AVFoundation
won't open the file yet. While a file converts, how far through it is runs across the
bottom of its still, which is where the library draws it on a film you're partway through.

Then import the MP4 into Immersive Cinema and let its optimizer decide about bit rate —
unless you converted with **Optimize Dolby Vision**, in which case it's already done, and
the app knows to leave Dolby Vision alone.

## Known limits

- **Atmos in TrueHD can't survive unless an E-AC-3 track sits alongside it.** MP4 has no
  mapping for TrueHD, and no free encoder produces E-AC-3 with JOC — Dolby's own engine is
  licensed. **Atmos already carried as E-AC-3 is copied, and survives intact.** Without one,
  the language's main track falls back to a plain AC-3 core if the disc offers one, or the
  discrete channels transcoded to E-AC-3 (without JOC) otherwise — either way you lose the
  object-based mix, not the surround channels under it.
- **PGS and VobSub subtitles are dropped.** MP4 has nowhere to put them. A dropped *forced*
  track gets its own warning, since losing one changes what the film contains rather than
  merely trims a spare — but check before relying on it regardless. A file named after the
  source and sitting beside it can supply the text yourself; see
  [Subtitles from a file beside the movie](#subtitles-from-a-file-beside-the-movie).
- **Sidecar subtitle files must be UTF-8.** No charset conversion is attempted — ffmpeg
  expects UTF-8, and a file in another encoding fails to mux the same way it fails to read
  here. Discovery and the duration sanity check are verified against synthetic SRT files;
  ASS/SSA and VTT parse the same shapes on paper but haven't been run against real files
  from either format, and the whole feature hasn't yet been run against a real Blu-ray
  remux's own subtitle files.
- **Variable frame rate** isn't handled on the Dolby Vision route: a raw stream carries no
  timing, so GPAC is given one rate. Films are constant rate; camera footage may not be.
- **HDR stills are converted, not tone mapped.** A frame from a PQ or HLG file is labelled
  with the colour space it was graded in and redrawn into sRGB, which puts the midtones and
  shadows where they belong but has no highlight roll-off, so specular detail above the SDR
  white point clips. Proper tone mapping needs ffmpeg's `zscale`, and Homebrew's bottle is
  built without libzimg. It affects the thumbnail in the list, never the file.
- **Untested paths.** Profile 7 is verified thoroughly on real 4K Blu-ray content. Profiles
  5 and 8 are written from spec and have not been run against real files. The re-encode
  branch for non-HEVC sources *has* now been run end to end — a VP9 and Opus file arrived as
  HEVC tagged `hvc1`, key frames exactly every 2 seconds, Rec. 709 fully tagged, at 1.65
  Mbps against a source asking 1.8 — but only on synthetic footage, and only in SDR.
  The one-track-per-language audio selection and the Dolby Vision RPU spot check are new
  and verified against synthetic multi-track files built for the purpose, not yet against a
  real multi-language, multi-commentary disc remux. **Letterbox cropping is also new and
  unverified against a real Dolby Vision file** — the Level 5 JSON shape it parses was
  confirmed against `dovi_tool`'s own bundled test RPU, and the crop and bit-rate logic
  against the code, but not yet run start to finish against a real disc remux with bars.

## Licence

Proprietary. See [LICENSE](LICENSE).
