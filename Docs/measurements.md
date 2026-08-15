# Why the encoder settings are what they are

Every figure in this app's `PlaybackTarget` came out of the same exercise: 42 encodes of a
4K Dolby Vision feature, scored against the film's own 74 Mbps Blu-ray remux. This is the
record of it, kept because several results contradicted what the code did beforehand, and
because roughly half the effort went into discovering that measurements were lying rather
than into the measurements themselves.

## Method

- **Source.** *Ballerina*, 3840×2160, 23.976 fps, HEVC Main 10, Dolby Vision profile 7
  dual-layer, 74.4 Mbps video, 2h04m39s. A disc remux sitting at the disc's ceiling — the
  60-second windows run 72 Mbps median against a 76.5 Mbps maximum, so it is essentially
  flat and its own bit rate says nothing about which scenes are hard.
- **Clips.** Five 60-second cuts, ranked by what they cost at a fixed CRF. Settings were
  tuned on one and then validated on two others they had never seen.
- **Metric.** VMAF, 4K model, every third frame. PSNR and a shadow-detail measure alongside
  it, because VMAF is least sensitive to this content's actual failure mode.
- **Crop.** **`crop=3840:1600:0:280` — scoring the active picture only.** The film is scope
  letterboxed into 16:9, and the bars are pure zero: free to encode and identical to the
  reference. Left in, a quarter of every frame scores perfectly and flatters every candidate
  equally. This one decision mattered more than any encoder setting; without it the
  differences below mostly vanish into the high nineties.

  A later reading of the film's own Dolby Vision Level 5 metadata put the bars at 276 rows
  each — the active picture is 3840×1608, not the 3840×1600 assumed here — so this crop
  scored 8 rows inside the real picture. Harmless for these measurements, which only needed
  the same crop on both sides of every comparison, but the app's letterbox removal uses
  Dolby's own 276, not this 280.

## The result the app is built on

| bit rate | x265 | VideoToolbox |
|---|---|---|
| ~11 Mbps | 92.65 | ~90.9 |
| ~16 Mbps | **93.91** | 91.82 |
| ~22 Mbps | 94.52 | 92.49 |
| ~26 Mbps | **95.02** | 93.09 |
| ~30 Mbps | 95.66 | **93.74** |

The two curves are parallel, about 1.9 VMAF apart at every rate, which is the same thing as
saying **VideoToolbox needs 1.87× the bit rate for the same picture**: it reaches 93.74 at
30 Mbps where x265 is already there at 16.

The mechanism is visible in how the bits are spread, not in the entropy coder. VideoToolbox
will not vary its rate by more than about a tenth — 1.07× peak to average — whichever mode
it is asked for, so on a hard shot it has no reserve to draw on. x265 runs 1.66×, inside the
1.5–2.1× range Apple's own content moves in.

**Neither curve saturates anywhere between 10 and 30 Mbps.** Both climb at a steady ~1.9
VMAF per doubling with no knee, so the target cannot be justified as "the point where extra
bits stop paying" — there isn't one. It has to be anchored to something outside the
measurement, which is why it is anchored to Apple.

## What Apple actually ships

The published tables give 16,800 kbps for 4K SDR and 20,000 for HDR, with a note taking 20%
off for 24 fps content. But the specification opens that section with "there are many
possible choices of bit rates for variants. The following tables provide one possible set",
and Apple does not ship the top of them.

From their own reference Dolby Vision stream, at this resolution and frame rate, video rate
being the declared `AVERAGE-BANDWIDTH` less the audio rendition it is paired with:

| rung | shipped | table × 0.8 |
|---|---|---|
| Dolby Vision, 4K, top | **24.33 Mbps** | 16.0 |
| Dolby Vision, 4K, 2nd | 15.89 | 16.0 |
| HDR10, 4K, top | 23.99 | 16.0 |
| HDR10, 1080p, top | 8.62 | 5.6 |

Their **second** 4K rung is the table figure with the frame-rate reduction. Their **top**
rung is half again above it. Cross-checked against the media playlist's own per-segment
`EXT-X-BITRATE` values, which average 24.5 Mbps across 19 segments — two independent routes
agreeing.

Hence `appleTopRungMultiplier = 1.5`, which reproduces their 4K and 1080p rungs to within
3%. 1440p does not fit and is not made to: Apple ships one 1440p rung at 14.56 Mbps, sitting
almost exactly on their second 4K rung, which reads as a rung to catch a player falling off
4K rather than a quality tier with a top of its own.

**This multiplier is only honest with an encoder good enough to earn it.** It arrives in the
same commit as x265 for that reason. Applied to VideoToolbox it would have been nonsense —
that encoder cannot reach the published numbers, let alone a multiple of them.

## Preset: it was never measuring preset

Five presets at a matched rate, and the entire spread was 0.44 VMAF:

| preset | SAO | AQ strength | VMAF |
|---|---|---|---|
| ultrafast + `signhide` | off | 0.0 | **93.92** |
| superfast | off | 0.0 | 93.91 |
| medium | on | 1.0 | 93.62 |
| faster | on | 1.0 | 93.48 |
| veryfast | on | 1.0 | 93.47 |
| fast | on | 1.0 | 93.47 |

The scores break exactly where two switches flip, and a factorial at veryfast confirms it:
SAO off is worth +0.19, AQ off is worth +0.19, both off is +0.40, and veryfast with both
off scores 93.88 against superfast's 93.91. **The effects are additive and they account for
the whole ladder.** All the extra motion search the slower presets spend their time on
contributes nothing measurable on dark, grainy film.

Sample-adaptive offset is a smoothing filter run after reconstruction; adaptive quantisation
moves bits between flat and detailed regions. On this material both remove the fine texture
that is the thing being lost in the first place.

`ultrafast` differs from `superfast` in one tool — sign data hiding — and buying that back
matches superfast exactly, 93.915 against 93.910, while running 13% faster. Hence the
settings this app uses.

## Six settings that did nothing at all

Every one returned the control's score to three decimal places, which is the tell: genuinely
different encoder settings do not agree that precisely.

| setting | why it did nothing |
|---|---|
| `tune=grain` in `--x265-params` | **`tune` is not parsed there.** It is consumed by `x265_param_default_preset()` before parameter parsing, and x265 does not complain about names it does not recognise. Only ffmpeg's `-tune` reaches it: via the params string psy-rd stays 2.00, via `-tune grain` it becomes 4.00 |
| `sao=0` at superfast | already off at that preset |
| `aq-mode=3` at superfast | superfast sets `aq-strength=0`, so any mode is multiplied by nothing |
| `aq-mode=4` at superfast | same — after tripling the encode time to prove it |
| `psy-rdoq=2.0` at superfast | needs RDO quantisation, which is off at `rd=2`. Unreachable at any preset fast enough for a feature |
| `spatial_aq` on VideoToolbox | byte-identical output |

The common cause for four of them: **a preset is not a neutral baseline for testing the
things the preset itself switches off.** Anyone extending this app's settings should check
that a new parameter actually reached the encoder before believing a null result.

## Two results that reversed a confident expectation

**B-frames make VideoToolbox worse.** ffmpeg's VideoToolbox wrapper leaves frame reordering
off unless `-bf` is passed, so every early measurement had I/P only. Enabling it — verified
in the output, `IBBBPBBBP…` rather than `IPPPPP…` — cost **0.61 VMAF at 24 Mbps and 0.73 at
30**. x265 gains from B-frames; this encoder loses. Immersive Cinema's optimizer set
`AVVideoAllowFrameReordering: true`, which on this evidence was costing it quality, and is
one more reason that optimizer is gone.

**Restricting x265 to the performance cores is 54% slower.** This machine is 4 performance +
6 efficiency cores, and WPP has row dependencies, so the expectation was that efficiency
cores would be stragglers. Measured: `--pools 4` runs 260 s where the default runs 169 s.
The efficiency cores contribute about 35% of throughput. ffmpeg's defaults are already
right, and `frame-threads=5` changes nothing either.

## What was ruled out

**AV1**, on two grounds. It has no Apple-readable Dolby Vision path, so encoding a DV source
to AV1 means discarding the RPU this app exists to preserve. And measured at comparable
encode speed it did not win anyway: SVT-AV1 preset 8 scored 92.67 at 16.65 Mbps against
x265's 93.91 at 17.53 — about 1.1 VMAF behind once rate-adjusted. A slower AV1 preset would
likely close that at several times the encode time. It remains interesting for SDR and plain
HDR10 content on M3/A17 Pro or later, where there is no RPU to lose.

**Reproducing Atmos.** Apple ships it as E-AC-3 with JOC, and no encoder outside Dolby's own
writes JOC; ffmpeg's E-AC-3 encoder stops at 5.1 channels and carries no objects.

## Two things about the measurements themselves

**Battery throttling invalidated a whole column.** A laptop encoding on battery ran 39%
slower than the same configuration on mains — 240 s against 173 s for a byte-identical
result. Every timing taken overnight was wrong by that factor, and the cause was diagnosed
twice as something else (CPU contention, then encoder non-determinism) before anyone checked
whether the machine was plugged in. Quality figures were unaffected: throttling changes the
clock, not the bitstream.

**Concurrency changes the answer, not just the speed.** Two encodes at once produce different
files, not merely slower ones, because x265 sizes its frame threads and lookahead to the
cores it can get and those decisions feed back into rate control. Anything measuring here
should have the machine to itself.

## Reproducing this

The bench is not in this repository — it was a scratch harness, not a product. What it did
is simple enough to rebuild:

```
ffmpeg -ss <t> -t 60 -i <source> -map 0:v:0 -c copy -tag:v hvc1 clip.mp4

ffmpeg -i clip.mp4 -an -c:v libx265 -preset ultrafast \
  -pix_fmt yuv420p10le -tag:v hvc1 -b:v 24000k \
  -x265-params "signhide=1:vbv-maxrate=48000:vbv-bufsize=48000:keyint=48:min-keyint=24:no-open-gop=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:master-display=<...>:max-cll=<...>" \
  out.mp4

ffmpeg -i out.mp4 -i clip.mp4 -lavfi \
  "[0:v]crop=3840:1600:0:280[d];[1:v]crop=3840:1600:0:280[r];\
   [d][r]libvmaf=model=version=vmaf_4k_v0.6.1:n_threads=10:n_subsample=3" \
  -f null -
```

The crop is the part to keep. Everything else is a knob; that is the difference between
measuring the picture and measuring the letterbox.
