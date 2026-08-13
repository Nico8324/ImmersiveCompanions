/*
Abstract:
Carrying Dolby Vision across a re-encode, which is the one thing Immersive Cinema cannot do for itself.
*/

import Foundation

// MARK: - Dolby Vision

/// Rebuilding a Dolby Vision track into a profile Apple can decode.
///
/// Apple plays profiles 5 and 8.1. A Blu-ray rip is profile 7 — a base layer, an
/// enhancement layer and an RPU — which decodes on no Apple device, so the plain route
/// throws the Dolby Vision away and keeps the HDR10 base. That's watchable, and it's what
/// happens without this. But the metadata is right there in the file, and 8.1 is the
/// profile it was always going to become.
///
/// Three steps, because no single tool does all of it. ffmpeg can demux but can't rewrite
/// an RPU; `dovi_tool` rewrites the RPU but doesn't mux; and ffmpeg's MP4 muxer can't write
/// the `dvvC` box that marks the track as Dolby Vision — only GPAC will do that. So the
/// video goes out to a raw stream, through `dovi_tool`, and back in through `MP4Box`, while
/// the audio and subtitles take the ordinary ffmpeg route and are added at the end.
///
/// The enhancement layer is discarded rather than carried: 8.1 is single-layer by
/// definition, nothing Apple owns would read the EL, and dropping it takes about a tenth
/// off the file.
struct DolbyVisionPlan {
    /// Which `dovi_tool` mode turns this profile into 8.1, or `nil` for one not worth
    /// touching.
    ///
    /// Profile 8 is already right and only needs its signalling rewritten on the way into
    /// MP4 — mode 0 parses and rewrites the RPU untouched, which is what carries it across.
    static func mode(forProfile profile: Int) -> Int? {
        switch profile {
        case 7: 2   // dual layer Blu-ray: convert and drop the enhancement layer
        case 5: 3   // IPT-graded base, unwatchable as HDR10 until it's converted
        case 8: 0   // already 8.x — rewrite untouched, purely to keep the signalling
        default: nil
        }
    }

    let videoStream: Int
    let mode: Int
    let frameRate: String
    let sourceProfile: Int

    /// The rate to re-encode the picture at, or `nil` to keep it as it is.
    ///
    /// Set only when the source is spending more than Immersive Cinema's target and a
    /// re-encode would actually save something. This is the one job the library can't do
    /// for itself: its optimizer rebuilds the picture through `AVAssetWriter`, and there is
    /// no public way to put an RPU back afterwards, so optimizing a Dolby Vision file there
    /// silently costs you the Dolby Vision. Here the RPU is taken out first and put back
    /// after, which is the whole reason to do this on the way in.
    let optimizedBitrate: Int?

    /// Pulls the RPU out of the source, converting it to 8.1 on the way.
    ///
    /// Read from the original rather than from a converted copy: a plain HEVC decoder
    /// ignores the enhancement layer, so the frames it produces are the base layer in
    /// order, which is exactly what the RPU is keyed to.
    func extractRPUArguments(from source: URL) -> (ffmpeg: [String], doviTool: [String]) {
        (
            ffmpeg: [
                "-y", "-loglevel", "error",
                "-i", source.path(percentEncoded: false),
                "-map", "0:\(videoStream)", "-c:v", "copy",
                "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "-"
            ],
            doviTool: ["-m", "\(mode)", "extract-rpu", "-", "-o"]
        )
    }

    /// Re-encodes the base layer to a raw stream, at the library's own target.
    ///
    /// Ten bit and Rec. 2020 throughout: a Dolby Vision base layer is PQ HDR, and decoding
    /// it into eight-bit buffers is where banding in a sky comes from.
    ///
    /// This is the path that most needs the better encoder. A Dolby Vision source is
    /// typically a disc remux spending 70 Mbps or more, and it is the one kind of file
    /// nothing else can convert — so what comes out here is what gets kept. Measured on
    /// exactly this material, x265 reaches at 16 Mbps what VideoToolbox needs 30 to match.
    func encodeArguments(
        from source: URL,
        to destination: URL,
        bitrate: Int,
        framesPerSecond: Double,
        hdr: HDRMetadata
    ) -> [String] {
        [
            "-y", "-loglevel", "error",
            "-i", source.path(percentEncoded: false),
            "-map", "0:\(videoStream)", "-an", "-sn"
        ]
        + PlaybackTarget.rateControlArguments(bitrate: bitrate)
        + PlaybackTarget.encoderParameters(
            bitrate: bitrate,
            framesPerSecond: framesPerSecond,
            dynamicRange: .hdr10,
            masteringDisplay: hdr.masteringDisplay,
            contentLightLevel: hdr.contentLightLevel
        )
        + [
            "-profile:v", "main10",
            "-pix_fmt", "yuv420p10le",
            "-color_primaries", "bt2020",
            "-color_trc", "smpte2084",
            "-colorspace", "bt2020nc"
        ]
        // A player that doesn't read the RPU falls back to these tags, and an untagged
        // fallback is the washed-out grey one. x265 writes them itself; this is the belt
        // and braces that was a necessity when VideoToolbox did the encoding.
        + DynamicRange.hdr10.bitstreamColourArguments
        + [
            "-progress", "pipe:1", "-nostats",
            "-f", "hevc", destination.path(percentEncoded: false)
        ]
    }

    /// Threads the RPU back between the slices of the freshly encoded stream.
    ///
    /// Only lines up because the encode changed neither the number of frames nor their
    /// order — the app never resizes and never resamples the frame rate, so every RPU
    /// still lands on the frame it was written for.
    func injectArguments(video: URL, rpu: URL, to destination: URL) -> [String] {
        [
            "inject-rpu",
            "-i", video.path(percentEncoded: false),
            "--rpu-in", rpu.path(percentEncoded: false),
            "-o", destination.path(percentEncoded: false)
        ]
    }

    /// Demuxes the video to Annex B and rewrites its RPU. Two processes joined by a pipe,
    /// so the stream is never written out twice.
    func extractArguments(from source: URL) -> (ffmpeg: [String], doviTool: [String]) {
        (
            ffmpeg: [
                "-y", "-loglevel", "error",
                "-i", source.path(percentEncoded: false),
                "-map", "0:\(videoStream)",
                "-c:v", "copy",
                // MP4-style length prefixes become start codes, which is the only shape
                // `dovi_tool` reads.
                "-bsf:v", "hevc_mp4toannexb",
                "-f", "hevc", "-"
            ],
            doviTool: ["-m", "\(mode)", "convert", "--discard", "-", "-o"]
        )
    }

    /// Puts the rewritten video and the ordinary tracks into one file.
    ///
    /// `dvp=8.hdr10` is profile 8 with the HDR10 compatibility ID — 8.1, written so a
    /// player that doesn't know Dolby Vision still sees a correct HDR10 picture. The frame
    /// rate has to be given because a raw stream carries no timing of its own.
    func muxArguments(video: URL, tracks: URL, to destination: URL) -> [String] {
        [
            "-quiet",
            "-add", "\(video.path(percentEncoded: false)):dvp=8.hdr10:fps=\(frameRate)",
            "-add", tracks.path(percentEncoded: false),
            "-new", destination.path(percentEncoded: false)
        ]
    }
}
