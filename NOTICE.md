# Notices

## Third-party tools

Immersive Companions drives three command-line tools. It **does not bundle, link against, or
redistribute** any of them — each is invoked as a separate process, from wherever it is
already installed on the machine.

That separation is deliberate. ffmpeg is LGPL, and shipping a copy inside an application
carries obligations — supplying notices, preserving the right to relink — that a personal
tool has no business taking on. Calling a program the user installed themselves is an
ordinary use of that program, not a distribution of it.

| Tool | Project | Licence |
| --- | --- | --- |
| `ffmpeg`, `ffprobe` | [FFmpeg](https://ffmpeg.org) | LGPL-2.1-or-later, or GPL depending on build |
| `dovi_tool` | [quietvoid/dovi_tool](https://github.com/quietvoid/dovi_tool) | MIT |
| `MP4Box` | [GPAC](https://gpac.io) | LGPL-2.1-or-later |

None of these is included in this repository or in the built application bundle. Their
licences are held by their own authors and are unaffected by this project's licence.

## Trademarks

Dolby, Dolby Vision, Dolby Atmos, Dolby Digital and Dolby Digital Plus are trademarks of
Dolby Laboratories. This project is not affiliated with, endorsed by, or certified by Dolby
Laboratories.

It creates no Dolby Vision and no Atmos. It rewrites metadata that already exists in a file
into a profile Apple's devices decode, and copies audio streams unchanged. Producing either
format from scratch requires Dolby's licensed encoders, which this does not use and does not
replace.

Apple, macOS, tvOS, visionOS, Apple TV, Apple Vision Pro and AVFoundation are trademarks of
Apple Inc.
