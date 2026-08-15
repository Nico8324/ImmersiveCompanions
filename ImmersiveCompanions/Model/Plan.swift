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
    /// One audio track as it survives into the output: which source stream it comes from,
    /// and how it gets there.
    private struct AudioTrack {
        let stream: Probe.Stream
        let isCopy: Bool
        /// Set only when transcoding.
        let targetCodec: String?
        let bitrate: String?
    }

    /// The display name for a codec MP4 can hold, for the note that says a track was
    /// converted to it. `AAC` and `HEVC` read fine uppercased; the hyphenated Dolby names
    /// don't.
    private static func displayName(forAudioCodec codec: String) -> String {
        switch codec {
        case "eac3": "E-AC-3"
        case "ac3": "AC-3"
        default: codec.uppercased()
        }
    }

    /// Groups the file's audio by language, keeps one main track per group plus anything
    /// that's a different programme rather than a duplicate of it, and decides how each
    /// surviving track reaches the output.
    ///
    /// A remux carrying TrueHD Atmos alongside the AC-3 core it was struck from used to
    /// keep both — two near-identical 5.1 tracks, the length of the film again in disk for
    /// nothing — and transcoded lossless multichannel to AAC, a codec Apple uses for
    /// stereo, not surround. Now one main track survives per language, chosen by what it
    /// costs to keep: E-AC-3 is copied first because it's the only one of these that can
    /// carry Atmos's JOC metadata, then AC-3, then whatever else MP4 already holds without
    /// transcoding. Only when nothing in the language passes through is anything
    /// transcoded, and then it's the richest source — most channels — that's picked.
    ///
    /// A stray stereo track never wins over a surround mix merely for already being in a
    /// copyable codec: if the best passthrough candidate is stereo and the language also
    /// carries a multichannel mix, the multichannel one is taken and transcoded instead.
    /// Keeping a film's 7.1 as E-AC-3 costs a lossy generation; keeping its stereo instead
    /// would cost the surround programme itself.
    ///
    /// Commentary and accessibility mixes are a different programme, not a duplicate mix,
    /// so they survive alongside the main track rather than being folded into it.
    private static func selectAudioTracks(from probe: Probe) -> (tracks: [AudioTrack], notes: [String]) {
        // E-AC-3 first: the one route here that can preserve Atmos's JOC metadata rather
        // than merely the discrete channels under it.
        let passthroughPriority: [String: Int] = ["eac3": 0, "ac3": 1, "aac": 2, "alac": 2, "mp3": 2]

        // Grouped in the file's own order, so a language that appears twice doesn't have
        // its tracks reshuffled to wherever the second group happened to start.
        var order: [String] = []
        var groups: [String: [Probe.Stream]] = [:]
        for stream in probe.audioStreams {
            let key = stream.language ?? "und"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(stream)
        }

        var kept: Set<Int> = []
        var duplicatesDropped = 0

        for key in order {
            let streams = groups[key] ?? []
            let secondary = streams.filter(\.isSecondaryAudioProgramme)
            let candidates = streams.filter { !$0.isSecondaryAudioProgramme }

            // Best copyable candidate first by codec, with channel count breaking ties —
            // a 5.1 AC-3 beats a stereo AC-3, not just a stereo AAC.
            let byPriority = candidates.compactMap { stream in
                passthroughPriority[stream.codecName ?? ""].map { (stream, $0) }
            }
            let bestPassthrough = byPriority.min {
                ($0.1, -($0.0.channels ?? 0)) < ($1.1, -($1.0.channels ?? 0))
            }?.0
            let richest = candidates.max { ($0.channels ?? 0) < ($1.channels ?? 0) }

            if let main = bestPassthrough,
               (main.channels ?? 0) > 2 || (richest?.channels ?? 0) <= 2 {
                kept.insert(main.index)
            } else if let richest {
                kept.insert(richest.index)
            }
            if candidates.count > 1 { duplicatesDropped += candidates.count - 1 }
            kept.formUnion(secondary.map(\.index))
        }

        // Back into the file's own order for the arguments themselves, so a track's
        // position in the output says as little as possible about which language group it
        // came from.
        let orderedKept = probe.audioStreams.filter { kept.contains($0.index) }

        var notes: [String] = []
        let tracks: [AudioTrack] = orderedKept.map { stream in
            let codec = stream.codecName ?? ""
            guard !passthroughAudio.contains(codec) else {
                return AudioTrack(stream: stream, isCopy: true, targetCodec: nil, bitrate: nil)
            }
            // The bit rates Immersive Cinema's own target uses, so a file converted here
            // and a file optimized there sound the same. Multichannel now lands on E-AC-3
            // rather than AAC — the format Apple actually ships surround sound in, where
            // AAC is what it ships stereo in.
            let channels = stream.channels ?? 2
            let targetCodec = channels > 2 ? "eac3" : "aac"
            let bitrate = channels > 2 ? "640k" : "256k"
            notes.append("\(codec.uppercased()) → \(displayName(forAudioCodec: targetCodec))")
            return AudioTrack(stream: stream, isCopy: false, targetCodec: targetCodec, bitrate: bitrate)
        }
        if duplicatesDropped > 0 {
            notes.append("\(duplicatesDropped) duplicate audio track\(duplicatesDropped == 1 ? "" : "s") dropped")
        }

        return (tracks, notes)
    }

    /// The `-disposition` flags worth preserving on a subtitle track carried into the
    /// output: `forced`, because that's what marks the translated dialogue MP4 keeps, and
    /// `default` alongside it when the source set both, since asking ffmpeg for one
    /// replaces whatever disposition the track already had rather than adding to it.
    private static func dispositionArgument(for stream: Probe.Stream) -> String? {
        guard stream.isForced else { return nil }
        return (stream.disposition?["default"] ?? 0) != 0 ? "default+forced" : "forced"
    }

    /// The `-disposition` value for a sidecar subtitle, mirroring `dispositionArgument`'s
    /// combined-flag convention: `forced` and `hearing_impaired` are independent bits in
    /// ffmpeg's own disposition mask, so a file named `Movie.eng.forced.sdh.srt` writes
    /// both rather than picking one.
    private static func dispositionArgument(for sidecar: SidecarSubtitle) -> String? {
        var flags: [String] = []
        if sidecar.isForced { flags.append("forced") }
        if sidecar.isHearingImpaired { flags.append("hearing_impaired") }
        return flags.isEmpty ? nil : flags.joined(separator: "+")
    }

    /// ISO 639-2 bibliographic codes, mapped to their terminological equivalents.
    ///
    /// Both codes name the same language — `chi` and `zho` are both "Chinese" — and either
    /// is a legal Matroska tag, so a source can carry the bibliographic one. GPAC does not
    /// treat the two as interchangeable: an intermediate whose subtitle track carried
    /// `language=chi` came out of `MP4Box -add` as `language=nor` — Norwegian — reproduced
    /// on this machine with the installed `MP4Box`, and the cause a real conversion shipped
    /// with two Chinese subtitle tracks labelled Norwegian. `zho`, `fra`, `deu`, `nld` and
    /// the rest of the terminological codes passed through the same import unchanged, which
    /// is why this maps every bibliographic code to its terminological pair rather than
    /// special-casing `chi` — the terminological code is the one every tool in this chain,
    /// GPAC included, reads back as what it was given.
    ///
    /// A code not in this table — already terminological, or a language with no B/T split at
    /// all, such as `eng` or `jpn` — passes through `normalisedLanguage` untouched.
    private static let bibliographicToTerminological: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym"
    ]

    /// The language tag actually worth writing: a bibliographic ISO 639-2 code rewritten to
    /// its terminological pair, or the code unchanged when it isn't one. Every site in this
    /// file that writes a `language=` metadata argument — audio, source subtitles, sidecar
    /// subtitles — goes through this rather than writing `stream.language` or
    /// `sidecar.language` straight through, so the fix in `bibliographicToTerminological`'s
    /// doc comment reaches all three the same way.
    private static func normalisedLanguage(_ language: String) -> String {
        bibliographicToTerminological[language] ?? language
    }

    /// How the audio and subtitles are handled, which is the same either route.
    ///
    /// - Parameter sidecars: Subtitle files found beside the source — see
    ///   `SidecarSubtitle.discover` — already validated against the probe's duration by the
    ///   caller. Each is its own ffmpeg input by the time this runs: `Plan.init` and
    ///   `trackOnlyArguments` both add a `-i` for every sidecar right after the source's
    ///   own, in this same order, so a sidecar at `sidecars[offset]` is always ffmpeg input
    ///   `offset + 1` — input `0` being the source throughout this app.
    static func trackArguments(
        for probe: Probe,
        sidecars: [SidecarSubtitle] = []
    ) -> (arguments: [String], notes: [String], isReencoding: Bool) {
        var arguments: [String] = []
        var notes: [String] = []
        var reencoding = false

        let audio = Plan.selectAudioTracks(from: probe)
        for (offset, track) in audio.tracks.enumerated() {
            arguments += ["-map", "0:\(track.stream.index)"]
            if track.isCopy {
                arguments += ["-c:a:\(offset)", "copy"]
            } else {
                reencoding = true
                arguments += ["-c:a:\(offset)", track.targetCodec!, "-b:a:\(offset)", track.bitrate!]
            }
            // A mapped stream keeps its language by default in the plain route, but the
            // Dolby Vision route carries it through an audio-only intermediate that MP4Box
            // then imports separately, and a file was observed coming out the far end of
            // that with `language: und` on every track. Writing it explicitly here, rather
            // than trusting it to travel implicitly through ffmpeg and then GPAC, is what
            // fixes that: MP4Box's default import reads a track's language straight off the
            // source file it's given, so as long as the intermediate has the right tag on
            // it, so does the file built from it.
            if let language = track.stream.language {
                arguments += ["-metadata:s:a:\(offset)", "language=\(Plan.normalisedLanguage(language))"]
            }
        }
        notes += audio.notes
        reencoding = reencoding || audio.tracks.contains { !$0.isCopy }

        // Subtitles: only the ones MP4 can hold, source tracks first.
        let text = probe.subtitleStreams.filter { textSubtitles.contains($0.codecName ?? "") }
        for (offset, stream) in text.enumerated() {
            arguments += ["-map", "0:\(stream.index)"]
            if let disposition = Plan.dispositionArgument(for: stream) {
                arguments += ["-disposition:s:\(offset)", disposition]
            }
            if let language = stream.language {
                arguments += ["-metadata:s:s:\(offset)", "language=\(Plan.normalisedLanguage(language))"]
            }
        }

        // Sidecar files next, numbered onward from the source's own text tracks: ffmpeg
        // assigns a `-map`ped subtitle stream its output index by the order it's mapped in,
        // not by which input it came from, so a sidecar takes `text.count + offset` here
        // regardless of how far into the file its own input sits.
        for (offset, sidecar) in sidecars.enumerated() {
            let outputIndex = text.count + offset
            arguments += ["-map", "\(offset + 1):0"]
            if let disposition = Plan.dispositionArgument(for: sidecar) {
                arguments += ["-disposition:s:\(outputIndex)", disposition]
            }
            if let language = sidecar.language {
                arguments += ["-metadata:s:s:\(outputIndex)", "language=\(Plan.normalisedLanguage(language))"]
            }
        }

        arguments += (text.isEmpty && sidecars.isEmpty) ? ["-sn"] : ["-c:s", "mov_text"]

        // Everything not carried across as text: PGS and VobSub, which have no home in
        // MP4, and the odd text codec ffmpeg can't remux into `mov_text`. A forced one
        // among them is worth saying so specifically — it's dialogue or on-screen text a
        // viewer can't get any other way, not a spare a film merely offered.
        let dropped = probe.subtitleStreams.filter { !textSubtitles.contains($0.codecName ?? "") }
        let droppedForced = dropped.filter(\.isForced)
        if !droppedForced.isEmpty {
            notes.append(droppedForced.count == 1
                ? "a forced subtitle track was dropped — the film may need an external subtitle file"
                : "\(droppedForced.count) forced subtitle tracks were dropped — the film may need an external subtitle file")
        }
        let droppedOther = dropped.count - droppedForced.count
        if droppedOther > 0 {
            notes.append("\(droppedOther) image subtitle\(droppedOther == 1 ? "" : "s") dropped")
        }

        if !sidecars.isEmpty {
            notes.append(sidecars.count == 1
                ? "1 subtitle added from a file beside the movie"
                : "\(sidecars.count) subtitles added from files beside the movie")
        }

        // Chapters are dropped unconditionally, on both routes. Apple's own store encodes
        // don't carry them, and this app exists to produce files that pass for one of those
        // — so parity with what Apple ships is the rule, not merely a fallback for the one
        // case that used to be visibly broken. It also removes a GPAC defect as a side
        // effect: ffmpeg writes a chapter as a timed-text track of its own (`SubtitleHandler`,
        // `tref 'chap'`) alongside the real chapter atom, and on the Dolby Vision route,
        // once the intermediate MP4Box imports whole also carries `mov_text` subtitle
        // tracks — as it does whenever the source has embedded text subtitles or a sidecar
        // file — that timed-text track comes out the other side as a `bin_data` track
        // running the length of the film: a phantom stream in the output, confirmed on the
        // installed `MP4Box`. `-map_chapters -1` here removes the cause on both routes at
        // once, rather than the symptom on the one route where it happened to surface.
        arguments += ["-map_chapters", "-1"]

        return (arguments, notes, reencoding)
    }

    /// The audio and subtitles alone, for the file GPAC adds to the rebuilt video.
    ///
    /// - Parameter sidecars: See `trackArguments` — added here as their own `-i` inputs,
    ///   right after the source, in the same order `trackArguments` numbers them in.
    static func trackOnlyArguments(
        for probe: Probe, from source: URL, to destination: URL, sidecars: [SidecarSubtitle] = []
    ) -> [String] {
        ["-y", "-loglevel", "error", "-i", source.path(percentEncoded: false)]
            + sidecars.flatMap { ["-i", $0.url.path(percentEncoded: false)] }
            + ["-vn"] + trackArguments(for: probe, sidecars: sidecars).arguments
            + ["-progress", "pipe:1", "-nostats", destination.path(percentEncoded: false)]
    }

    /// - Parameters:
    ///   - isRebuildingDolbyVision: Whether the Dolby Vision route is handling the picture,
    ///     in which case this plan describes only the audio and subtitles and must not also
    ///     report what would have happened to the Dolby Vision without it.
    ///   - sidecars: Subtitle files found beside the source and already checked against the
    ///     probe's duration — see `SidecarSubtitle`. Added as their own `-i` inputs right
    ///     after the source, which is what lets `trackArguments` address them by a fixed
    ///     `offset + 1`.
    init(
        for probe: Probe,
        from source: URL,
        to destination: URL,
        isRebuildingDolbyVision: Bool = false,
        hdr: HDRMetadata = HDRMetadata(framesJSON: Data()),
        sidecars: [SidecarSubtitle] = []
    ) throws {
        guard let picture = probe.picture, let codec = picture.codecName else {
            throw ConversionError.noVideo
        }

        var arguments = ["-y", "-i", source.path(percentEncoded: false)]
            + sidecars.flatMap { ["-i", $0.url.path(percentEncoded: false)] }
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

        let tracks = Plan.trackArguments(for: probe, sidecars: sidecars)
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
