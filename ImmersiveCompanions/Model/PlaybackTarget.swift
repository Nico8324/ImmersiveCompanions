/*
Abstract:
The encode this app aims for: what Apple ships, with the encoder that can reach it.
*/

import Foundation

// MARK: - The encode Immersive Cinema aims for

/// The range a picture was graded in.
enum DynamicRange {
    case standard
    case hdr10
    case hlg

    /// Read from the transfer function, which is what actually distinguishes them.
    ///
    /// Dolby Vision profile 8 reports PQ and is treated as the HDR10 it falls back to —
    /// the extra metadata layer can't survive a re-encode, and HDR10 is what a device
    /// without Dolby Vision would have shown anyway. Same call the library makes.
    init(transfer: String?) {
        switch transfer {
        case "smpte2084": self = .hdr10
        case "arib-std-b67": self = .hlg
        default: self = .standard
        }
    }

    var isHighDynamicRange: Bool { self != .standard }

    /// Writes the colour description into the bitstream itself.
    ///
    /// `-color_primaries` and `-color_trc` are not enough on their own.
    /// `hevc_videotoolbox` writes the matrix coefficients into the VUI and silently drops
    /// the other two, so a file encoded with all three asked for comes out of ffprobe as
    /// `color_space=bt2020nc, color_transfer=unknown, color_primaries=unknown`. ffmpeg
    /// records what it was told at the stream level; VideoToolbox just never puts it in the
    /// stream. For HDR that is the whole problem — a PQ picture with no transfer
    /// characteristic is the washed-out grey one, because nothing downstream knows to apply
    /// the curve.
    ///
    /// So the values are stamped in afterwards with the `hevc_metadata` bitstream filter,
    /// which rewrites the VUI directly. The numbers are H.273 code points, not names.
    var bitstreamColourArguments: [String] {
        let (primaries, transfer, matrix) = switch self {
        case .standard: (1, 1, 1)      // BT.709 throughout
        case .hdr10: (9, 16, 9)        // BT.2020 primaries, ST 2084, BT.2020 non-constant
        case .hlg: (9, 18, 9)          // as HDR10 but ARIB STD-B67
        }
        return [
            "-bsf:v",
            "hevc_metadata=colour_primaries=\(primaries)"
                + ":transfer_characteristics=\(transfer)"
                + ":matrix_coefficients=\(matrix)"
        ]
    }
}

/// Immersive Cinema's `PlaybackTarget`, transcribed.
///
/// One target rather than one per device: Apple Vision Pro, Apple TV 4K and Apple silicon
/// Macs all decode HEVC Main 10 up to 4K in hardware, so a single file satisfies all three.
/// The bit rates are the top HEVC rung of each tier in Apple's *HLS Authoring
/// Specification for Apple Devices*, as written, with the specification's own 20%
/// reduction for 24 fps content applied on top.
///
/// Kept deliberately as a copy rather than shared: this app is a separate tool that must
/// keep working when the library isn't around. If the library's ladder changes, this needs
/// changing with it.
enum PlaybackTarget {
    /// Seconds between key frames.
    static let keyFrameIntervalInSeconds = 2.0

    /// The rung of Apple's ladder a picture sits on, chosen by pixel count rather than
    /// height: a 2.39:1 feature stored without its bars is 3840×1600, three-quarters of a
    /// 4K frame but only middling by height. The boundaries are the midpoints between
    /// neighbouring frame sizes.
    private static func megabitsPerSecond(pixels: Int, dynamicRange: DynamicRange) -> Double {
        let isHDR = dynamicRange.isHighDynamicRange
        return switch pixels {
        case ..<460_800: isHDR ? 1.93 : 1.6
        case ..<1_382_400: isHDR ? 4.08 : 3.4
        case ..<2_764_800: isHDR ? 7.0 : 5.8
        case ..<5_529_600: isHDR ? 9.7 : 8.1
        default: isHDR ? 20.0 : 16.8
        }
    }

    /// How many bits HEVC needs to hold what another codec was holding, as a ratio.
    ///
    /// Below one where HEVC is the more efficient codec, above one where it isn't: an AV1
    /// file re-encoded at its own bit rate comes out visibly worse, because AV1 was doing
    /// more with those bits than HEVC can.
    private static func bitrateRatio(replacing codec: String) -> Double {
        switch codec {
        case "h264", "mpeg4", "msmpeg4v3", "vc1", "mpeg2video": 0.65
        case "vp9", "vp8": 0.95
        case "av1": 1.3
        case "hevc": 0.9
        // A mastering codec carries far more than any delivery encode needs, so the
        // ceiling is what applies.
        default: 1.0
        }
    }

    /// The rate to re-encode a picture at, or `nil` when re-encoding wouldn't earn its keep.
    ///
    /// The same test the library applies: only worth doing when the file is spending more
    /// than a third again over what the picture needs. Below that the storage saved doesn't
    /// pay for the generation of quality it costs.
    /// What Apple ships this picture at, which is both the rate to aim for and the yardstick
    /// a source is judged against.
    ///
    /// One function on purpose. These two uses were separate calculations that happened to
    /// agree, and they stopped agreeing the moment ``appleTopRungMultiplier`` arrived: the
    /// test for "is this worth re-encoding" still measured against 16 Mbps while the encode
    /// itself targeted 24, so a 22 Mbps source passed the test and came out *larger* than it
    /// went in.
    static func referenceBitrate(
        width: Int,
        height: Int,
        frameRate: Double,
        dynamicRange: DynamicRange
    ) -> Int {
        let frameRateFactor = frameRate < filmFrameRateCeiling ? 0.8 : 1.0
        return Int(
            megabitsPerSecond(pixels: width * height, dynamicRange: dynamicRange)
                * frameRateFactor * appleTopRungMultiplier * 1_000_000
        )
    }

    static func worthwhileBitrate(for picture: Probe.Stream, probe: Probe) -> Int? {
        // Nothing to judge against means nothing to judge: a file that won't say what its
        // picture costs is left alone rather than re-encoded on a guess.
        guard let sourceBitrate = picture.bitsPerSecond(durationInSeconds: probe.durationInSeconds),
              sourceBitrate > 0 else { return nil }

        let range = DynamicRange(transfer: picture.colorTransfer)
        let frameRate = picture.framesPerSecond
        let reference = referenceBitrate(
            width: picture.width ?? 1920,
            height: picture.height ?? 1080,
            frameRate: frameRate,
            dynamicRange: range
        )

        guard Double(sourceBitrate) > Double(reference) * bitrateTolerance else { return nil }
        return videoBitrate(
            width: picture.width ?? 1920,
            height: picture.height ?? 1080,
            frameRate: frameRate,
            dynamicRange: range,
            sourceCodec: picture.codecName ?? "hevc",
            sourceBitrate: sourceBitrate
        )
    }

    /// How far above the target a source has to sit before re-encoding is worth it.
    static let bitrateTolerance = 1.35

    /// The frame rate below which the specification's 24 fps reduction applies.
    ///
    /// Catches 23.976 and 24 and leaves 25 alone: 24 fps is what the specification names,
    /// and inventing a rule for PAL film is how the previous numbers went wrong. There is
    /// deliberately no uplift above 30 either — the tables give one figure per rung for a
    /// source's own frame rate and say nothing about spending more at 60.
    static let filmFrameRateCeiling = 24.5

    /// How far above the published table Apple's own top rung actually sits.
    ///
    /// The tables are explicitly "one possible set of bit rate variants" (1.25), and Apple
    /// does not ship the top of them. Measured off their own reference Dolby Vision stream,
    /// at this project's resolution and frame rate, video rate being the declared
    /// `AVERAGE-BANDWIDTH` less the audio rendition it is paired with:
    ///
    ///     rung                    shipped     table x 0.8
    ///     Dolby Vision, 4K, top   24.33         16.0
    ///     Dolby Vision, 4K, 2nd   15.89         16.0
    ///     HDR10, 1080p, top        8.62          5.6
    ///
    /// Their *second* 4K rung is the table figure with the 24 fps reduction. Their top rung
    /// is half again above it, and that is the one worth matching for a file kept on a disc,
    /// which has no ladder to fall down. The same 1.5x reproduces their 1080p rung to within
    /// 3%. Cross-checked against the media playlist's own per-segment rates, which average
    /// 24.5 Mbps.
    ///
    /// This is only honest with an encoder as good as the one Apple used. It is applied
    /// here because this app encodes with x265; it would have been wrong when the app called
    /// `hevc_videotoolbox`, which needs 1.87x the rate to reach the same picture and so
    /// could never have earned the published numbers, let alone a multiple of them.
    ///
    /// 1440p does not fit the pattern and is not made to: Apple ships one 1440p rung, at
    /// 14.56 Mbps, sitting almost exactly on their second 4K rung. That reads as a rung to
    /// catch a player falling off 4K rather than a quality tier with a top of its own.
    static let appleTopRungMultiplier = 1.5

    /// Above this many bits per pixel, a file reads as a master rather than a bad encode.
    ///
    /// Apple's own rungs land between roughly 0.15 and 0.20 — 30 Mbps across a 4K frame at
    /// 24 fps is 0.15. A UHD disc sits around 0.3, because a disc isn't rationing anything.
    /// The threshold sits between the two: above it the bits are buying picture, below it
    /// they're being wasted, and the same 60 Mbps means opposite things at 4K and at 1080p.
    static let masteredBitsPerPixel = 0.25

    /// The encoder, and how to ask it for a rate.
    ///
    /// x265, where this app used to call `hevc_videotoolbox`. Measured on a 4K Dolby Vision
    /// feature against its own 74 Mbps source, VMAF's 4K model, scored on the active picture
    /// so the letterbox bars couldn't flatter either encoder:
    ///
    ///     rate      x265     VideoToolbox
    ///     16 Mbps   93.91    91.82
    ///     24 Mbps   95.02    93.09
    ///     30 Mbps   95.66    93.74
    ///
    /// Two VMAF at every rate, which is another way of saying **VideoToolbox needs 1.87x the
    /// bit rate for the same picture**: it reaches 93.74 at 30 Mbps where x265 is already
    /// there at 16. So x265 is both better and smaller, and the only thing it costs is time
    /// — about three hours for a feature against fifty minutes, paid once for a file kept
    /// for good.
    ///
    /// One pass, not two. A second pass exists to land on an exact average, which matters
    /// when a player is choosing between rungs at a known bandwidth. A file on a disc has
    /// neither, and over a feature one pass converges anyway: asked for 24 Mbps, a 2h04
    /// encode delivered 23.85.
    static func rateControlArguments(bitrate: Int) -> [String] {
        ["-c:v", "libx265", "-preset", encoderPreset, "-b:v", "\(bitrate)"]
    }

    /// The x265 preset, which matters far less than its name suggests.
    ///
    /// Across five presets at a matched rate the entire spread was 0.44 VMAF, and none of it
    /// came from search effort. x265 switches off sample-adaptive offset and adaptive
    /// quantisation at ultrafast and superfast and switches both on from veryfast up; each
    /// costs about 0.19 VMAF on dark grainy film, and veryfast with both forced off scores
    /// 93.88 against superfast's 93.91. The extra motion search the slower presets spend
    /// their time on contributes nothing measurable on this material.
    ///
    /// ultrafast differs from superfast in one tool — sign data hiding — and buying that
    /// back matches superfast exactly, 93.915 against 93.910, while running 13% faster.
    static let encoderPreset = "ultrafast"

    /// The x265 parameters that go with it.
    ///
    /// - `signhide` is the one tool superfast has over ultrafast, added back.
    /// - `vbv-*` holds the peak to twice the average, which is what specification 1.30 asks
    ///   of VOD. It still leaves room to spend where the picture needs it: this encode ran
    ///   1.66x peak to average, against VideoToolbox's 1.07x and Apple's own 1.5x to 2.1x.
    /// - `keyint`/`min-keyint` put a closed IDR every two seconds (1.13), so scrubbing lands
    ///   where it was dropped.
    /// - `master-display` and `max-cll` carry the source's HDR10 static metadata across.
    ///   x265 drops both unless told, and specification 1.35 asks for them.
    static func encoderParameters(
        bitrate: Int,
        framesPerSecond: Double,
        dynamicRange: DynamicRange,
        masteringDisplay: String?,
        contentLightLevel: String?
    ) -> [String] {
        let keyInterval = max(Int((framesPerSecond * keyFrameIntervalInSeconds).rounded()), 1)
        var params = [
            "signhide=1",
            "vbv-maxrate=\(bitrate / 1000 * 2)",
            "vbv-bufsize=\(bitrate / 1000 * 2)",
            "keyint=\(keyInterval)",
            "min-keyint=\(max(keyInterval / 2, 1))",
            "no-open-gop=1"
        ]
        // x265 writes the colour description into the VUI when asked, which is the thing
        // `hevc_videotoolbox` would not do — see `bitstreamColourArguments`, still applied
        // afterwards as belt and braces.
        switch dynamicRange {
        case .hdr10:
            params += ["colorprim=bt2020", "transfer=smpte2084", "colormatrix=bt2020nc",
                       "range=limited", "hdr10=1"]
        case .hlg:
            params += ["colorprim=bt2020", "transfer=arib-std-b67", "colormatrix=bt2020nc",
                       "range=limited"]
        case .standard:
            params += ["colorprim=bt709", "transfer=bt709", "colormatrix=bt709",
                       "range=limited"]
        }
        if let masteringDisplay { params.append("master-display=\(masteringDisplay)") }
        if let contentLightLevel { params.append("max-cll=\(contentLightLevel)") }
        return ["-x265-params", params.joined(separator: ":")]
    }

    /// The rate to encode at: never above Apple's rung for the frame, never above what the
    /// source was already spending, adjusted for how the two codecs compare.
    ///
    /// Detail a file has already thrown away doesn't come back when you spend more bits on
    /// it, so a frugal 2 Mbps download re-encoded at Apple's 10 Mbps would be five times
    /// the size and not one bit better.
    static func videoBitrate(
        width: Int,
        height: Int,
        frameRate: Double,
        dynamicRange: DynamicRange,
        sourceCodec: String,
        sourceBitrate: Int
    ) -> Int {
        let reference = referenceBitrate(
            width: width, height: height, frameRate: frameRate, dynamicRange: dynamicRange
        )

        guard sourceBitrate > 0 else { return reference }
        let matchedToSource = Int(Double(sourceBitrate) * bitrateRatio(replacing: sourceCodec))
        return min(reference, matchedToSource)
    }
}
