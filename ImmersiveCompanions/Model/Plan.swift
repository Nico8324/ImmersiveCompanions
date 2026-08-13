/*
Abstract:
What to do with a file, decided from what the probe found in it.
*/

import Foundation

// MARK: - Deciding what to do

/// What the conversion of one file will do, and the arguments that do it.
///
/// The bias is towards copying streams rather than re-encoding them: the job is to get a
/// file into a container AVFoundation can open, touching it as little as possible.
///
/// Where a re-encode is unavoidable, this is now the only place one happens. Immersive
/// Cinema used to carry its own optimizer and no longer does — through `AVAssetWriter` it
/// could reach only VideoToolbox, which needs 1.87x the bit rate for the same picture, and
/// it could not carry Dolby Vision across at all. So there is nothing downstream to correct
/// a decision made here.
struct Plan {
    /// Video codecs that go into MP4 as they are and decode in hardware on Apple silicon,
    /// Apple TV 4K and Vision Pro — the three devices the library has to satisfy.
    static let passthroughVideo: Set<String> = ["h264", "hevc"]

    /// Audio codecs MP4 carries and AVFoundation decodes.
    static let passthroughAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "mp3"]

    /// Subtitle codecs that survive the trip into MP4's text track. Image-based subtitles —
    /// PGS from a Blu-ray, VobSub from a DVD — have no home in MP4 and are dropped.
    static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt"]

    var arguments: [String]
    /// What this did, in a few words, for the row in the list.
    var summary: String
    /// Whether anything is being re-encoded, which is the difference between seconds and
    /// a long wait.
    var isReencoding: Bool
}

extension Plan {
    /// How the audio and subtitles are handled, which is the same either route.
    static func trackArguments(
        for probe: Probe
    ) -> (arguments: [String], notes: [String], isReencoding: Bool) {
        var arguments: [String] = []
        var notes: [String] = []
        var reencoding = false

        // Audio: every track, so a film keeps its other languages, each judged on its own.
        for (offset, stream) in probe.audioStreams.enumerated() {
            arguments += ["-map", "0:\(stream.index)"]
            let audioCodec = stream.codecName ?? ""
            if passthroughAudio.contains(audioCodec) {
                arguments += ["-c:a:\(offset)", "copy"]
            } else {
                reencoding = true
                notes.append("\(audioCodec.uppercased()) → AAC")
                // The bit rates Immersive Cinema's own target uses, so a file converted
                // here and a file optimized there sound the same.
                let bitrate = (stream.channels ?? 2) > 2 ? "640k" : "256k"
                arguments += ["-c:a:\(offset)", "aac", "-b:a:\(offset)", bitrate]
            }
        }

        // Subtitles: only the ones MP4 can hold.
        let text = probe.subtitleStreams.filter { textSubtitles.contains($0.codecName ?? "") }
        for stream in text {
            arguments += ["-map", "0:\(stream.index)"]
        }
        arguments += text.isEmpty ? ["-sn"] : ["-c:s", "mov_text"]

        let dropped = probe.subtitleStreams.count - text.count
        if dropped > 0 {
            notes.append("\(dropped) image subtitle\(dropped == 1 ? "" : "s") dropped")
        }

        // Chapters are carried across by default, which is right until they are wrong.
        // A set running past the end of the file becomes a `text` track longer than the
        // media, and AVFoundation takes an asset's duration from its longest track — so the
        // library would read the runtime off that and show it. Better no chapters than a
        // file that lies about how long it is.
        if probe.hasChaptersPastTheEnd {
            arguments += ["-map_chapters", "-1"]
            notes.append("chapters dropped — they ran past the end of the file")
        }

        return (arguments, notes, reencoding)
    }

    /// The audio and subtitles alone, for the file GPAC adds to the rebuilt video.
    static func trackOnlyArguments(for probe: Probe, from source: URL, to destination: URL) -> [String] {
        ["-y", "-loglevel", "error", "-i", source.path(percentEncoded: false)]
            + ["-vn"] + trackArguments(for: probe).arguments
            + ["-progress", "pipe:1", "-nostats", destination.path(percentEncoded: false)]
    }

    /// - Parameter isRebuildingDolbyVision: Whether the Dolby Vision route is handling the
    ///   picture, in which case this plan describes only the audio and subtitles and must
    ///   not also report what would have happened to the Dolby Vision without it.
    init(
        for probe: Probe,
        from source: URL,
        to destination: URL,
        isRebuildingDolbyVision: Bool = false,
        hdr: HDRMetadata = HDRMetadata(framesJSON: Data())
    ) throws {
        guard let picture = probe.picture, let codec = picture.codecName else {
            throw ConversionError.noVideo
        }

        var arguments = ["-y", "-i", source.path(percentEncoded: false)]
        var notes: [String] = []
        var reencoding = false

        // Video: the picture only, so cover art doesn't become the film.
        arguments += ["-map", "0:\(picture.index)"]
        if Plan.passthroughVideo.contains(codec) {
            arguments += ["-c:v", "copy"]
            // HEVC in MP4 has two sample entry names, and Apple only accepts one of them.
            // `hev1` keeps the parameter sets in the stream; `hvc1` puts them in the sample
            // description, which is what AVFoundation insists on. Copied straight out of
            // Matroska the track lands as `hev1`, and the file then opens, enumerates its
            // tracks, reads through `AVAssetReader` — and reports `isPlayable == false`,
            // with the colour tags missing from the format description. Retagging is a
            // relabel, not a re-encode: the samples are untouched.
            if codec == "hevc" {
                arguments += ["-tag:v", "hvc1"]
            }
        } else {
            reencoding = true
            notes.append("\(codec.uppercased()) → HEVC")
            arguments += Plan.videoEncodeArguments(for: picture, probe: probe, hdr: hdr)
        }

        let tracks = Plan.trackArguments(for: probe)
        arguments += tracks.arguments
        notes += tracks.notes
        reencoding = reencoding || tracks.isReencoding

        // Dolby Vision, which is worth saying out loud rather than quietly dropping.
        //
        // Apple plays profiles 5 and 8.1. Profile 7 is the Blu-ray one — a base layer, an
        // enhancement layer and an RPU — and no Apple device decodes it. What survives here
        // is the base layer, and whether that's the right picture depends entirely on the
        // compatibility ID: 1 or 6 means the base is already graded as HDR10 and looks
        // correct, which covers the Blu-ray rips this app exists for. A profile 5 base is
        // graded in IPT and is *not* watchable as HDR10 — that one has to be said plainly,
        // because the file will otherwise look wrong rather than fail.
        //
        // None of it applies when the RPU is being rebuilt instead: the Dolby Vision is
        // being kept, not fallen back from, and saying both — "→ profile 8.1" alongside
        // "→ HDR10 base layer" — described two opposite outcomes for the same file.
        if !isRebuildingDolbyVision,
           let dolbyVision = picture.dolbyVision, let profile = dolbyVision.dvProfile {
            let compatibility = dolbyVision.dvBlSignalCompatibilityId ?? 0
            switch profile {
            case 5:
                notes.append("Dolby Vision profile 5 — the picture may look wrong")
            case 8:
                notes.append("Dolby Vision 8 kept as HDR10")
            default:
                notes.append(compatibility == 1 || compatibility == 6
                    ? "Dolby Vision \(profile) → HDR10 base layer"
                    : "Dolby Vision \(profile) dropped — the picture may look wrong")
            }
        }

        arguments += [
            // No `+faststart`. It moves the index to the front so a player reading over
            // HTTP can start before the file has arrived — which is worth nothing here,
            // because Immersive Cinema plays from local disk and AVFoundation just seeks
            // to the index wherever it sits. It isn't free either: it rewrites the file
            // afterwards to shift the index, about 11% on a 543 MB sample and more as
            // files grow, since the second pass is proportional to the whole file.
            "-progress", "pipe:1", "-nostats", "-loglevel", "error",
            destination.path(percentEncoded: false)
        ]

        self.arguments = arguments
        self.isReencoding = reencoding
        self.summary = notes.isEmpty ? "Rewrapped, nothing re-encoded" : notes.joined(separator: ", ")
    }

    /// How to encode a picture that can't be copied.
    ///
    /// This is now the only place a picture gets re-encoded for the library. Immersive
    /// Cinema used to carry its own optimizer and no longer does — it could only reach
    /// VideoToolbox through `AVAssetWriter`, which needs 1.87x the bit rate for the same
    /// picture and could never carry Dolby Vision across at all. So whatever is decided
    /// here is what the library keeps, with nothing downstream to correct it.
    private static func videoEncodeArguments(
        for picture: Probe.Stream,
        probe: Probe,
        hdr: HDRMetadata
    ) -> [String] {
        let range = DynamicRange(transfer: picture.colorTransfer)
        let frameRate = picture.framesPerSecond
        let bitrate = PlaybackTarget.videoBitrate(
            width: picture.width ?? 1920,
            height: picture.height ?? 1080,
            frameRate: frameRate,
            dynamicRange: range,
            sourceCodec: picture.codecName ?? "",
            sourceBitrate: picture.bitsPerSecond(durationInSeconds: probe.durationInSeconds) ?? 0
        )

        var arguments = ["-tag:v", "hvc1"]
            + PlaybackTarget.rateControlArguments(bitrate: bitrate)
            + PlaybackTarget.encoderParameters(
                bitrate: bitrate,
                framesPerSecond: frameRate,
                dynamicRange: range,
                masteringDisplay: hdr.masteringDisplay,
                contentLightLevel: hdr.contentLightLevel
            )

        // Ten bits for HDR, eight for the rest. Decoding HDR into eight-bit buffers is
        // where banding in a sky comes from, and no bit rate afterwards puts it back.
        switch range {
        case .hdr10, .hlg:
            arguments += [
                "-profile:v", "main10",
                "-pix_fmt", "yuv420p10le",
                "-color_primaries", "bt2020",
                "-color_trc", range == .hlg ? "arib-std-b67" : "smpte2084",
                "-colorspace", "bt2020nc"
            ]
        case .standard:
            arguments += [
                "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709"
            ]
        }

        // x265 writes the colour description into the VUI itself, so this is belt and
        // braces rather than the necessity it was when VideoToolbox did the encoding.
        return arguments + range.bitstreamColourArguments
    }
}
