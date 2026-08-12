/*
Abstract:
A Mac app that rewraps video Immersive Cinema can't open into MP4 it can.
*/

import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The app

@main
struct ImmersiveCompanionsApp: App {
    @State private var queue = ConversionQueue()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// One window, not a `WindowGroup`.
    ///
    /// A `WindowGroup` is the multi-window scene, and the app declares itself a viewer of
    /// movie files — so every Open With, every drop on the Dock icon and every `open -a`
    /// arriving while it was already running opened *another* window. All of them onto the
    /// same queue, since that lives here and there is only ever one of it, so what you got
    /// was several identical lists stacked on top of each other.
    ///
    /// There is one queue because the encoder is one piece of hardware. A single window is
    /// the honest shape for that.
    var body: some Scene {
        Window("Immersive Companions", id: "converter") {
            ContentView()
                .environment(queue)
                .onAppear { delegate.queue = queue }
        }
        .defaultSize(width: 680, height: 500)
        .windowResizability(.contentMinSize)
    }
}

/// Takes files opened from outside the window: dropped on the Dock icon, sent with Open
/// With, or handed over by `open -a`. The drop zone is the obvious way in; this is the one
/// that fits into everything else on the Mac.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var queue: ConversionQueue?

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        queue?.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - How the library looks

/// Measurements taken from Immersive Cinema, so a file on its way into the library is
/// presented the way the library will present it.
///
/// Transcribed rather than shared, for the same reason `PlaybackTarget` is: this tool has to
/// keep working with the library nowhere in sight. If `Constants` there changes, change this
/// with it.
enum Layout {
    /// `Constants.cornerRadius`, which is what every still and card in the library is
    /// clipped to.
    static let cornerRadius: Double = 10

    /// The width of the still beside a row.
    ///
    /// The library's `episodeThumbnailWidth` is 160 on a Mac, but that sits on a detail page
    /// beside a title, a number and three lines of synopsis. A row here is three short lines
    /// about a file, and a still that tall leaves most of the row empty.
    static let thumbnailWidth: Double = 120

    /// `Constants.progressBarHeight`.
    static let progressBarHeight: Double = 4

    /// `Constants.genreSpacing`, which is the inset the library gives that bar when it draws
    /// it across a card.
    static let progressBarInset: Double = 8
}

// MARK: - Finding the tools

/// The ffmpeg install this app drives.
///
/// Deliberately the one already on the machine rather than a copy inside the app bundle.
/// ffmpeg is LGPL, and shipping it inside an app carries obligations — notices, the right
/// to relink — that a personal tool has no business taking on. Invoking a separate process
/// keeps that boundary clean, at the cost of asking you to install it.
enum Tools {
    /// Where Homebrew, MacPorts and a hand-built install put things, in that order.
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    static let ffmpeg = locate("ffmpeg")
    static let ffprobe = locate("ffprobe")

    /// Rewrites a Dolby Vision RPU to a profile Apple decodes. Optional: without it, DV
    /// content still converts, it just arrives as its HDR10 base layer.
    static let doviTool = locate("dovi_tool")

    /// Writes the `dvvC` box that tells a player the track is Dolby Vision. ffmpeg's MP4
    /// muxer has no way to add one to a raw stream, which is why GPAC is here.
    static let mp4box = locate("MP4Box")

    static var isInstalled: Bool {
        ffmpeg != nil && ffprobe != nil
    }

    /// Whether the Dolby Vision route is available at all.
    static var canConvertDolbyVision: Bool {
        doviTool != nil && mp4box != nil
    }

    private static func locate(_ name: String) -> URL? {
        searchPaths
            .map { URL(filePath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }
}

// MARK: - Reading a file

/// What ffprobe says is in a file.
struct Probe: Decodable {
    struct Stream: Decodable {
        let index: Int
        let codecName: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let bitRate: String?
        let colorTransfer: String?
        let avgFrameRate: String?
        let rFrameRate: String?
        let sideDataList: [SideData]?

        /// The Dolby Vision record on this stream, if it carries one.
        var dolbyVision: SideData? {
            sideDataList?.first { $0.dvProfile != nil }
        }

        /// The frame rate exactly as ffprobe reports it, kept as the rational it is.
        ///
        /// A raw stream carries no timing, so this is what GPAC is told. Rounding
        /// `24000/1001` to 23.976 drifts a film a frame or so out by the end of it.
        var rationalFrameRate: String {
            for candidate in [avgFrameRate, rFrameRate] {
                if let candidate, candidate != "0/0", !candidate.isEmpty { return candidate }
            }
            return "24000/1001"
        }

        /// The frame rate, which ffprobe reports as a rational such as `24000/1001`.
        ///
        /// Falls back to 24 rather than 0: the rate only decides whether this counts as
        /// high frame rate for the bit rate, and guessing film is the safer of the two.
        var framesPerSecond: Double {
            for candidate in [avgFrameRate, rFrameRate] {
                let parts = (candidate ?? "").split(separator: "/")
                guard parts.count == 2,
                      let numerator = Double(parts[0]),
                      let denominator = Double(parts[1]),
                      denominator > 0, numerator > 0 else { continue }
                return numerator / denominator
            }
            return 24
        }
    }

    /// The extra records ffprobe hangs off a stream. Only Dolby Vision matters here.
    struct SideData: Decodable {
        let sideDataType: String?
        let dvProfile: Int?
        /// Which conventional format the base layer is already gradeable as: 1 for HDR10,
        /// 2 SDR, 4 HLG, 6 for the Blu-ray flavour of HDR10.
        let dvBlSignalCompatibilityId: Int?
    }

    struct Format: Decodable {
        let duration: String?
        let bitRate: String?
    }

    let streams: [Stream]
    let format: Format

    var durationInSeconds: Double {
        Double(format.duration ?? "") ?? 0
    }

    var videoStreams: [Stream] { streams.filter { $0.codecType == "video" } }
    var audioStreams: [Stream] { streams.filter { $0.codecType == "audio" } }
    var subtitleStreams: [Stream] { streams.filter { $0.codecType == "subtitle" } }

    /// The first video stream that's an actual picture rather than embedded cover art.
    ///
    /// Matroska files routinely carry a poster as a still "video" stream, and mapping that
    /// as the picture produces a one-frame film.
    var picture: Stream? {
        videoStreams.first { ($0.codecName ?? "") != "mjpeg" && ($0.codecName ?? "") != "png" }
            ?? videoStreams.first
    }

    /// What's in the file, in one line, for the row in the list.
    ///
    /// Worth showing before anything happens: it's the difference between trusting the app
    /// picked the right stream out of a file with cover art and three languages in it, and
    /// hoping it did. The Dolby Vision profile is named rather than reduced to "HDR",
    /// because which profile it is decides what the conversion can do with it.
    var mediaSummary: String {
        var parts: [String] = []

        if let picture {
            if let codec = picture.codecName { parts.append(codec.uppercased()) }
            if let width = picture.width, let height = picture.height {
                parts.append("\(width)×\(height)")
            }
            if let profile = picture.dolbyVision?.dvProfile {
                parts.append("Dolby Vision \(profile)")
            } else {
                switch DynamicRange(transfer: picture.colorTransfer) {
                case .hdr10: parts.append("HDR10")
                case .hlg: parts.append("HLG")
                case .standard: break
                }
            }
        }

        if !audioStreams.isEmpty {
            parts.append("\(audioStreams.count) audio")
        }
        if !subtitleStreams.isEmpty {
            let count = subtitleStreams.count
            parts.append("\(count) subtitle\(count == 1 ? "" : "s")")
        }
        if durationInSeconds > 0 {
            // Minutes for anything of a length worth converting; seconds below that, so a
            // forty-second clip doesn't round up to "1min" and look like a mistake.
            let units: Set<Duration.UnitsFormatStyle.Unit> =
                durationInSeconds < 60 ? [.seconds] : [.hours, .minutes]
            parts.append(Duration.seconds(durationInSeconds).formatted(
                .units(allowed: units, width: .narrow, maximumUnitCount: 2)
            ))
        }
        return parts.joined(separator: " · ")
    }

    static func read(_ url: URL) async throws -> Probe {
        guard let ffprobe = Tools.ffprobe else { throw ConversionError.toolsMissing }
        let output = try await Process.output(of: ffprobe, arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            url.path(percentEncoded: false)
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Probe.self, from: output)
    }
}

// MARK: - A frame from the file

/// A still for the row in the list.
///
/// Which frame to take is Immersive Cinema's `thumbnailData`, transcribed: sample several
/// positions rather than one, keep to the opening, take the first frame that isn't
/// essentially black, and fall back to the brightest if the whole sample is dark. A single
/// grab lands on a fade-in or a distributor card often enough to matter, and a black
/// rectangle doesn't read as "no artwork" — it reads as a file that's already broken.
///
/// How the frame is obtained can't be transcribed. The library uses `AVAssetImageGenerator`,
/// which is precisely what this app exists because you can't do: AVFoundation won't open a
/// Matroska file at all, and these files aren't converted yet. So ffmpeg decodes the frame
/// and only the choosing is shared.
enum Thumbnail {
    /// How far into a video to sample, as a fraction of its duration.
    private static let position = 0.1

    /// The latest point, in seconds, at which to take that first sample.
    private static let latestPosition = 5.0

    /// Where to look when the opening is black. Far enough in to clear a title sequence,
    /// not so far as to put a spoiler in the list.
    private static let fallbackPositions = [0.15, 0.25, 0.4, 0.55]

    /// How bright a frame has to be, from 0 to 1, to count as showing something. Low on
    /// purpose: this rejects black, it doesn't judge a night scene.
    private static let minimumLuminance = 0.06

    /// The width the frame is decoded at — twice what it's drawn at, for a Retina display,
    /// and no more. One of these is held for every file in the queue.
    private static let decodeWidth = Int(Layout.thumbnailWidth * 2)

    /// Returns a representative frame, or `nil` if none could be read.
    ///
    /// Never throws: a row without a still is still a perfectly good row.
    static func read(
        from source: URL,
        durationInSeconds seconds: Double,
        dynamicRange: DynamicRange
    ) async -> CGImage? {
        guard let ffmpeg = Tools.ffmpeg else { return nil }

        var brightest: (image: CGImage, luminance: Double)?
        for time in times(forDurationInSeconds: seconds) {
            guard let data = try? await Process.output(
                of: ffmpeg,
                arguments: arguments(for: source, at: time, dynamicRange: dynamicRange)
            ),
                !data.isEmpty,
                let decoded = CGImage.decoded(from: data),
                let image = decoded.forDisplay(from: dynamicRange)
            else { continue }

            // Judged after the conversion rather than before it, because that's the frame
            // anyone actually sees. PQ holds most of its code values in the shadows, so an
            // unconverted dark frame measures far brighter than it looks.
            let luminance = image.averageLuminance
            if luminance >= minimumLuminance { return image }
            if luminance > (brightest?.luminance ?? -1) { brightest = (image, luminance) }
        }
        return brightest?.image
    }

    /// When to sample, in the order the frames are preferred.
    private static func times(forDurationInSeconds seconds: Double) -> [Double] {
        // Nothing to divide up when the length is unknown; take whatever the file opens on.
        guard seconds > 0 else { return [0] }

        let opening = min(seconds * position, latestPosition)
        return ([opening] + fallbackPositions.map { $0 * seconds })
            // A short clip's later samples collapse onto its end, where there's no frame.
            .filter { $0 >= 0 && $0 < seconds }
    }

    /// - Note: No tone mapping is asked of ffmpeg, deliberately. The filter that does it
    ///   properly, `zscale`, needs libzimg, and Homebrew's ffmpeg bottle is built without
    ///   it — so a chain built around `zscale` would fail on a plain `brew install ffmpeg`,
    ///   which is every install this app expects. An HDR frame is handed over exactly as it
    ///   was encoded and converted afterwards by ColorSync instead.
    private static func arguments(for source: URL, at seconds: Double, dynamicRange: DynamicRange) -> [String] {
        [
            "-v", "error",
            // Seeking before the input rather than after it: ffmpeg jumps to the nearest key
            // frame instead of decoding everything up to that point, which is the difference
            // between a still appearing at once and a minute of work for each file.
            "-ss", "\(seconds)",
            "-i", source.path(percentEncoded: false),
            "-an", "-frames:v", "1",
            "-vf", "scale=\(decodeWidth):-2"
        ]
        // Sixteen bits and PNG for HDR, because those code values still have to survive a
        // transfer conversion — eight bits of PQ banded across a sky is the thing this is
        // trying to avoid. JPEG is fine for SDR, where nothing further happens to it.
        + (dynamicRange.isHighDynamicRange
            ? ["-pix_fmt", "rgb48be", "-c:v", "png"]
            : ["-c:v", "mjpeg"])
        + ["-f", "image2", "-"]
    }
}

private extension CGImage {
    static func decoded(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The frame as it should appear on an ordinary screen.
    ///
    /// An HDR frame arrives from ffmpeg still encoded the way it was graded — PQ or HLG,
    /// in Rec. 2020 — and carries no profile to say so, so anything that draws it treats
    /// those numbers as sRGB. That is what a washed-out, grey-blacked thumbnail is: PQ
    /// holds most of its code values down in the shadows, and read as sRGB the whole
    /// picture lifts.
    ///
    /// Rather than ask ffmpeg to convert, the frame is labelled with the colour space it
    /// was actually encoded in and redrawn into sRGB, which hands the conversion to
    /// ColorSync. It's a colorimetric conversion and not a true tone map — there's no
    /// highlight roll-off, so specular detail above the SDR white point clips — but it puts
    /// the midtones and shadows where they belong, and it needs nothing of ffmpeg that a
    /// stock Homebrew build doesn't have.
    ///
    /// SDR frames are returned untouched.
    func forDisplay(from dynamicRange: DynamicRange) -> CGImage? {
        let name: CFString? = switch dynamicRange {
        case .hdr10: CGColorSpace.itur_2100_PQ
        case .hlg: CGColorSpace.itur_2100_HLG
        case .standard: nil
        }
        guard let name else { return self }

        guard let space = CGColorSpace(name: name),
              let tagged = copy(colorSpace: space),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else {
            // A frame that won't convert is still a frame. Better a slightly flat still
            // than an empty row.
            return self
        }

        context.draw(tagged, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? self
    }

    /// How bright the frame is overall, by drawing it into a single pixel.
    ///
    /// Rec. 601 luma, as the library uses: the eye reads green as far brighter than blue at
    /// equal value, so an even average would call a deep blue frame brighter than it looks.
    var averageLuminance: Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }
        context.interpolationQuality = .medium
        context.draw(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let red = Double(pixel[0]) / 255
        let green = Double(pixel[1]) / 255
        let blue = Double(pixel[2]) / 255
        return 0.299 * red + 0.587 * green + 0.114 * blue
    }
}

// MARK: - Deciding what to do

/// What the conversion of one file will do, and the arguments that do it.
///
/// The bias is towards copying streams rather than re-encoding them. Immersive Cinema has
/// its own optimizer, which knows Apple's bit rate ladder and decides properly whether a
/// file is worth re-encoding; doing that here as well would spend a generation of quality
/// on a judgement this app isn't the one making. So the job here is narrow: get the streams
/// into a container AVFoundation can open, touching them as little as possible.
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
        return (arguments, notes, reencoding)
    }

    /// The audio and subtitles alone, for the file GPAC adds to the rebuilt video.
    static func trackOnlyArguments(for probe: Probe, from source: URL, to destination: URL) -> [String] {
        ["-y", "-loglevel", "error", "-i", source.path(percentEncoded: false)]
            + ["-vn"] + trackArguments(for: probe).arguments
            + ["-progress", "pipe:1", "-nostats", destination.path(percentEncoded: false)]
    }

    init(for probe: Probe, from source: URL, to destination: URL) throws {
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
            arguments += Plan.videoEncodeArguments(for: picture, probe: probe)
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
        if let dolbyVision = picture.dolbyVision, let profile = dolbyVision.dvProfile {
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
    /// These settings are `PlaybackTarget` from Immersive Cinema, transcribed. Where a
    /// stream is copied this app defers the bit rate question to the library's own
    /// optimizer — but a re-encode here is final. The optimizer judges what it finds, and
    /// what it finds will be an HEVC file within its tolerance, so it will quite correctly
    /// leave it alone. Whatever is decided here is what the library keeps, which is why it
    /// has to be decided the same way.
    private static func videoEncodeArguments(for picture: Probe.Stream, probe: Probe) -> [String] {
        let range = DynamicRange(transfer: picture.colorTransfer)
        let frameRate = picture.framesPerSecond
        let bitrate = PlaybackTarget.videoBitrate(
            width: picture.width ?? 1920,
            height: picture.height ?? 1080,
            frameRate: frameRate,
            dynamicRange: range,
            sourceCodec: picture.codecName ?? "",
            sourceBitrate: Int(picture.bitRate ?? "") ?? Int(probe.format.bitRate ?? "") ?? 0
        )

        var arguments = [
            "-c:v", "hevc_videotoolbox",
            "-tag:v", "hvc1",
            "-b:v", "\(bitrate)",
            // Two seconds between key frames, which is what Apple's authoring
            // specification asks for and what makes scrubbing land where you dropped it.
            "-g", "\(max(Int((frameRate * PlaybackTarget.keyFrameIntervalInSeconds).rounded()), 1))"
            // Frame reordering is left at the VideoToolbox default, which is on — the same
            // thing the library asks for with `AVVideoAllowFrameReorderingKey`.
        ]

        // Ten bits and Rec. 2020 for HDR; eight and Rec. 709 for everything else. Tagging
        // matters as much as the pixels — an untagged HDR file is what comes out washed
        // out and grey, and an untagged SDR file is at the mercy of whatever assumes what.
        switch range {
        case .hdr10, .hlg:
            arguments += [
                "-profile:v", "main10",
                "-pix_fmt", "p010le",
                "-color_primaries", "bt2020",
                "-color_trc", range == .hlg ? "arib-std-b67" : "smpte2084",
                "-colorspace", "bt2020nc"
            ]
        case .standard:
            arguments += [
                "-profile:v", "main",
                "-pix_fmt", "yuv420p",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709"
            ]
        }

        // And again into the bitstream, because the encoder drops two of the three.
        return arguments + range.bitstreamColourArguments
    }
}

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
    func encodeArguments(from source: URL, to destination: URL, bitrate: Int, framesPerSecond: Double) -> [String] {
        [
            "-y", "-loglevel", "error",
            "-i", source.path(percentEncoded: false),
            "-map", "0:\(videoStream)", "-an", "-sn",
            "-c:v", "hevc_videotoolbox",
            "-b:v", "\(bitrate)",
            "-g", "\(max(Int((framesPerSecond * PlaybackTarget.keyFrameIntervalInSeconds).rounded()), 1))",
            "-profile:v", "main10",
            "-pix_fmt", "p010le",
            "-color_primaries", "bt2020",
            "-color_trc", "smpte2084",
            "-colorspace", "bt2020nc"
        ]
        // The base layer of a Dolby Vision file is PQ HDR, and the encoder drops the
        // transfer characteristic unless it's written into the VUI directly. A player that
        // doesn't read the RPU falls back to this, and an untagged fallback is the grey one.
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
/// The bit rates come from Apple's *HLS Authoring Specification for Apple Devices*.
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
        case ..<460_800: isHDR ? 4 : 3
        case ..<1_382_400: isHDR ? 8 : 6
        case ..<2_764_800: isHDR ? 12 : 10
        case ..<5_529_600: isHDR ? 20 : 16
        default: isHDR ? 30 : 25
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
    static func worthwhileBitrate(for picture: Probe.Stream, probe: Probe) -> Int? {
        let sourceBitrate = Int(picture.bitRate ?? "") ?? Int(probe.format.bitRate ?? "") ?? 0
        guard sourceBitrate > 0 else { return nil }

        let range = DynamicRange(transfer: picture.colorTransfer)
        let frameRate = picture.framesPerSecond
        let frameRateFactor = frameRate > 33 ? 1.5 : 1.0
        let reference = Int(
            megabitsPerSecond(
                pixels: (picture.width ?? 1920) * (picture.height ?? 1080),
                dynamicRange: range
            ) * frameRateFactor * 1_000_000
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
        // Twice the frames need more than the same bit rate, though not twice as much:
        // consecutive frames at 60 fps are more alike than at 24.
        let frameRateFactor = frameRate > 33 ? 1.5 : 1.0
        let reference = Int(
            megabitsPerSecond(pixels: width * height, dynamicRange: dynamicRange)
                * frameRateFactor * 1_000_000
        )

        guard sourceBitrate > 0 else { return reference }
        let matchedToSource = Int(Double(sourceBitrate) * bitrateRatio(replacing: sourceCodec))
        return min(reference, matchedToSource)
    }
}

// MARK: - Doing it

enum ConversionError: LocalizedError {
    case toolsMissing
    case noVideo
    case notEnoughSpace(needed: Int64, free: Int64)
    case unplayableResult
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolsMissing:
            return "ffmpeg wasn’t found. Install it with `brew install ffmpeg`."
        case .noVideo:
            return "That file doesn’t contain a video track."
        case .notEnoughSpace(let needed, let free):
            let format = ByteCountFormatStyle(style: .file)
            return "Not enough room: needs about \(needed.formatted(format)), \(free.formatted(format)) free."
        case .unplayableResult:
            return "The converted file came out unplayable, so it was deleted rather than left for you to find later."
        case .failed(let message):
            return message.isEmpty ? "The conversion failed." : message
        }
    }
}

/// Checks that what came out is something the library can actually use.
///
/// Not a formality. A conversion can finish, exit zero and produce a file that AVFoundation
/// opens, enumerates and reads — and still refuses to play, which is what an HEVC track
/// tagged `hev1` rather than `hvc1` does. ffmpeg has no opinion on that; only the framework
/// doing the playing does. So the framework is asked, here, before the file is called done.
///
/// `AVAssetReader` is constructed too, because that's the first thing Immersive Cinema's
/// optimizer does, and a file it can't read is a file that can't be optimized.
enum Verification {
    static func check(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let video = try await asset.loadTracks(withMediaType: .video)

        guard playable, !video.isEmpty, duration.seconds > 0 else {
            throw ConversionError.unplayableResult
        }
        guard (try? AVAssetReader(asset: asset)) != nil else {
            throw ConversionError.unplayableResult
        }
    }
}

/// The files waiting to be converted, and the one being converted now.
///
/// One at a time on purpose: the encoder is a fixed piece of hardware, so a second
/// conversion alongside the first finishes no sooner and just competes for disk.
@MainActor
@Observable
final class ConversionQueue {
    struct Job: Identifiable {
        let id = UUID()
        let source: URL
        var status: Status = .waiting
        /// What the conversion will do, once the file has been read.
        var summary: String?
        /// What's in the file: codec, frame, range, tracks, length.
        var details: String?
        var sourceBytes: Int64?
        /// When the conversion actually started, which is what turns a fraction into a
        /// time remaining.
        var startedAt: Date?
        var output: URL?
        var outputBytes: Int64?
        /// A frame from the file, once one has been read.
        var image: NSImage?
        /// Whether the still has been looked for, so a file no frame can be read from
        /// isn't tried again on every pass.
        var stillWasRead = false

        var isConverting: Bool {
            if case .converting = status { true } else { false }
        }

        /// Whether there's anything to try again — a job that finished has its file.
        var isRetryable: Bool {
            switch status {
            case .failed, .cancelled: true
            case .waiting, .converting, .finished: false
            }
        }

        /// The source's size, read up front so a waiting row can show it.
        init(source: URL) {
            self.source = source
            self.sourceBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init)
        }
    }

    enum Status: Equatable {
        case waiting
        case converting(fraction: Double)
        case finished
        case failed(String)
        case cancelled
    }

    private(set) var jobs: [Job] = []

    /// Whether to bring an over-fat Dolby Vision picture down to the library's target on
    /// the way through.
    ///
    /// Off by default. Converting is the job; re-encoding is a separate decision that costs
    /// a generation of quality and a good deal of time, and it should be asked for. It only
    /// applies to Dolby Vision, because that's the only case Immersive Cinema can't handle
    /// for itself — for anything else its own optimizer does this properly, after import.
    var optimizesBitrate = false

    private var isRunning = false
    private var current: Process?
    private var stillTask: Task<Void, Never>?

    var isBusy: Bool { isRunning }

    func add(_ urls: [URL]) {
        let accepted = urls.filter(\.looksLikeVideo)
        guard !accepted.isEmpty else { return }
        jobs.append(contentsOf: accepted.map { Job(source: $0) })
        Task { await runNext() }
        readStills()
    }

    /// Reads what each queued file looks like and what's in it, before its turn comes.
    ///
    /// Separate from the conversion, and running beside it, so a row is worth looking at
    /// from the moment it's dropped rather than from the moment it starts. It costs a
    /// second probe of each file — the conversion does its own, because what it plans from
    /// shouldn't depend on whether the list happened to be decorated yet — and an ffprobe
    /// is cheap next to what follows it.
    ///
    /// One file at a time, and one task overall: a dozen files dropped together would
    /// otherwise start a dozen ffmpegs alongside the conversion that actually matters.
    private func readStills() {
        guard stillTask == nil else { return }
        stillTask = Task { @MainActor in
            while let job = jobs.first(where: { !$0.stillWasRead }) {
                let id = job.id
                let probe = try? await Probe.read(job.source)
                let still = await Thumbnail.read(
                    from: job.source,
                    durationInSeconds: probe?.durationInSeconds ?? 0,
                    dynamicRange: DynamicRange(transfer: probe?.picture?.colorTransfer)
                )
                update(id) { job in
                    job.stillWasRead = true
                    if let probe { job.details = probe.mediaSummary }
                    if let still {
                        job.image = NSImage(
                            cgImage: still,
                            size: CGSize(width: still.width, height: still.height)
                        )
                    }
                }
            }
            stillTask = nil
        }
    }

    func clearFinished() {
        jobs.removeAll { job in
            switch job.status {
            case .finished, .failed, .cancelled: true
            case .waiting, .converting: false
            }
        }
    }

    /// Puts a job that failed back in the queue.
    ///
    /// Most failures here are worth another go without changing anything — a full disk
    /// that has since been emptied, a tool installed after the first attempt.
    func retry(_ id: Job.ID) {
        update(id) { job in
            job.status = .waiting
            job.summary = nil
            job.details = nil
            job.startedAt = nil
            job.output = nil
            job.outputBytes = nil
        }
        Task { await runNext() }
    }

    /// Takes one file out of the list.
    ///
    /// The one converting can't simply be dropped — there's a process running against it
    /// and a half-written file beside the original — so it's stopped instead, and `runNext`
    /// clears up and moves on. Everything else goes at once.
    func remove(_ id: Job.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if case .converting = jobs[index].status {
            current?.terminate()
        } else {
            jobs.remove(at: index)
        }
    }

    /// Changes one job by identity rather than by position.
    ///
    /// Positions don't hold: `clearFinished` can remove rows above the one converting
    /// while it converts, and an index captured when the job started would then be
    /// pointing at a different job, or off the end of the array.
    private func update(_ id: Job.ID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    var finishedCount: Int { jobs.filter { $0.status == .finished }.count }

    var failedCount: Int {
        jobs.filter { if case .failed = $0.status { true } else { false } }.count
    }

    /// Stops the conversion running now and drops anything still waiting.
    func cancelAll() {
        for index in jobs.indices where jobs[index].status == .waiting {
            jobs[index].status = .cancelled
        }
        current?.terminate()
    }

    /// Whether this file's Dolby Vision is worth rebuilding, and how.
    ///
    /// Only when both extra tools are present: without them the ordinary route still
    /// produces a good HDR10 file, which is a far better outcome than refusing the job.
    private static func dolbyVisionPlan(for probe: Probe, optimizing: Bool) -> DolbyVisionPlan? {
        guard Tools.canConvertDolbyVision,
              let picture = probe.picture,
              picture.codecName == "hevc",
              let dolbyVision = picture.dolbyVision,
              let profile = dolbyVision.dvProfile,
              let mode = DolbyVisionPlan.mode(forProfile: profile)
        else { return nil }

        return DolbyVisionPlan(
            videoStream: picture.index,
            mode: mode,
            frameRate: picture.rationalFrameRate,
            sourceProfile: profile,
            optimizedBitrate: optimizing
                ? PlaybackTarget.worthwhileBitrate(for: picture, probe: probe)
                : nil
        )
    }

    /// Runs the three steps a Dolby Vision rebuild takes.
    ///
    /// The weights are how long each actually takes rather than an even split: the demux
    /// and RPU rewrite is a full pass over the video, the audio is small beside it, and
    /// GPAC then writes the whole file out again.
    private func runDolbyVision(
        _ plan: DolbyVisionPlan,
        probe: Probe,
        from source: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let ffmpeg = Tools.ffmpeg,
              let doviTool = Tools.doviTool,
              let mp4box = Tools.mp4box else { throw ConversionError.toolsMissing }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "CinemaConverter-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appending(path: "video.hevc")
        let tracksURL = scratch.appending(path: "tracks.mp4")
        let sourceBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        if let bitrate = plan.optimizedBitrate {
            // The RPU comes out first, the picture is re-encoded without it, and it goes
            // back in afterwards. Every frame is still where it was, so every RPU still
            // lands on the frame it describes.
            let rpuURL = scratch.appending(path: "rpu.bin")
            let encodedURL = scratch.appending(path: "encoded.hevc")

            let extraction = plan.extractRPUArguments(from: source)
            try await Process.runPiped(
                ffmpeg, arguments: extraction.ffmpeg,
                into: doviTool, arguments: extraction.doviTool + [rpuURL.path(percentEncoded: false)],
                holding: { self.current = $0 },
                expectedBytes: nil, watching: rpuURL
            ) { _ in }
            onProgress(0.05)

            try await Process.run(
                ffmpeg,
                arguments: plan.encodeArguments(
                    from: source, to: encodedURL,
                    bitrate: bitrate,
                    framesPerSecond: probe.picture?.framesPerSecond ?? 24
                ),
                duration: probe.durationInSeconds,
                holding: { self.current = $0 }
            ) { onProgress(0.05 + $0 * 0.65) }

            try await Process.runWatchingOutput(
                doviTool,
                arguments: plan.injectArguments(video: encodedURL, rpu: rpuURL, to: videoURL),
                holding: { self.current = $0 },
                expectedBytes: (try? encodedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                watching: videoURL
            ) { onProgress(0.70 + $0 * 0.10) }
        } else {
            // Nothing to re-encode: convert the RPU in place and keep the picture as it is.
            let extraction = plan.extractArguments(from: source)
            try await Process.runPiped(
                ffmpeg, arguments: extraction.ffmpeg,
                into: doviTool, arguments: extraction.doviTool + [videoURL.path(percentEncoded: false)],
                holding: { self.current = $0 },
                expectedBytes: sourceBytes, watching: videoURL
            ) { onProgress($0 * 0.80) }
        }

        // The audio and subtitles, the ordinary way.
        try await Process.run(
            ffmpeg,
            arguments: Plan.trackOnlyArguments(for: probe, from: source, to: tracksURL),
            duration: probe.durationInSeconds,
            holding: { self.current = $0 }
        ) { onProgress(0.80 + $0 * 0.05) }

        // Put them together, with the signalling that makes it Dolby Vision.
        try await Process.runWatchingOutput(
            mp4box,
            arguments: plan.muxArguments(video: videoURL, tracks: tracksURL, to: destination),
            holding: { self.current = $0 },
            expectedBytes: (try? videoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
            watching: destination
        ) { onProgress(0.85 + $0 * 0.15) }
    }

    /// Refuses a conversion the disk can't hold.
    ///
    /// The estimate is the source's own size. The video is normally copied whole, so the
    /// output lands within a few per cent of it either way — smaller when a fat lossless
    /// audio track becomes AAC, larger when nothing does.
    private func checkSpace(for source: URL, writingTo destination: URL) throws {
        guard let needed = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let free = try? destination.deletingLastPathComponent()
                  .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                  .volumeAvailableCapacityForImportantUsage
        else { return }

        guard Int64(needed) < free else {
            throw ConversionError.notEnoughSpace(needed: Int64(needed), free: free)
        }
    }

    /// Works through the queue until nothing is waiting.
    ///
    /// A loop rather than a tail call at the end of each job. `isRunning` is only cleared
    /// when this returns, so a recursive call made from inside the job would see the queue
    /// still busy, turn straight back at the guard, and leave everything behind it waiting
    /// for a conversion that had already finished.
    private func runNext() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while let next = jobs.first(where: { $0.status == .waiting }) {
            await convert(next.id, source: next.source)
            current = nil
        }
    }

    private func convert(_ id: Job.ID, source: URL) async {
        let destination = URL.unused(forConverting: source)

        do {
            let probe = try await Probe.read(source)
            let plan = try Plan(for: probe, from: source, to: destination)

            // The output is about the size of the input — the video is usually copied
            // whole. Better to say so now than to fill the disk and fail at the far end of
            // an hour's work.
            try checkSpace(for: source, writingTo: destination)

            let dolbyVision = Self.dolbyVisionPlan(for: probe, optimizing: optimizesBitrate)
            let summary = switch (dolbyVision, dolbyVision?.optimizedBitrate) {
            case (nil, _):
                plan.summary
            case (_, let bitrate?):
                "Dolby Vision 8.1 kept, picture re-encoded at "
                    + "\(Int((Double(bitrate) / 1_000_000).rounded())) Mbps, " + plan.summary
            default:
                "Dolby Vision → profile 8.1, " + plan.summary
            }
            update(id) { job in
                job.summary = summary
                job.details = probe.mediaSummary
                job.startedAt = .now
                job.status = .converting(fraction: 0)
            }

            let report: (Double) -> Void = { fraction in
                self.update(id) { job in
                    if case .converting = job.status {
                        job.status = .converting(fraction: fraction)
                    }
                }
            }

            guard let ffmpeg = Tools.ffmpeg else { throw ConversionError.toolsMissing }
            if let dolbyVision {
                try await runDolbyVision(
                    dolbyVision,
                    probe: probe,
                    from: source,
                    to: destination,
                    onProgress: report
                )
            } else {
                try await Process.run(
                    ffmpeg,
                    arguments: plan.arguments,
                    duration: probe.durationInSeconds,
                    holding: { self.current = $0 },
                    onProgress: report
                )
            }

            try await Verification.check(destination)

            update(id) { job in
                job.output = destination
                job.outputBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init)
                job.status = .finished
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            update(id) { $0.status = .cancelled }
        } catch {
            // A half-written file is worse than none: it looks importable and isn't.
            try? FileManager.default.removeItem(at: destination)
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }
}

// MARK: - Running ffmpeg

extension Process {
    /// Runs a tool and returns everything it wrote to standard output.
    static func output(of tool: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Runs one tool with its output piped straight into another.
    ///
    /// Neither end can report progress here — the first tool's standard output is carrying
    /// the video, not a progress feed — so the file being written is measured as it grows
    /// instead. It ends up smaller than what went in, since the enhancement layer is
    /// dropped along the way, so this runs slightly ahead of the truth rather than behind.
    static func runPiped(
        _ first: URL,
        arguments firstArguments: [String],
        into second: URL,
        arguments secondArguments: [String],
        holding: @escaping (Process) -> Void,
        expectedBytes: Int64?,
        watching output: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let upstream = Process()
        upstream.executableURL = first
        upstream.arguments = firstArguments

        let downstream = Process()
        downstream.executableURL = second
        downstream.arguments = secondArguments

        let bridge = Pipe()
        upstream.standardOutput = bridge
        downstream.standardInput = bridge

        let upstreamErrors = Pipe()
        let downstreamErrors = Pipe()
        upstream.standardError = upstreamErrors
        downstream.standardError = downstreamErrors
        holding(downstream)

        let monitor = sizeMonitor(of: output, expecting: expectedBytes, onProgress: onProgress)
        defer { monitor?.cancel() }

        try upstream.run()
        try downstream.run()

        let errorData = await Task.detached {
            _ = upstreamErrors.fileHandleForReading.readDataToEndOfFile()
            return downstreamErrors.fileHandleForReading.readDataToEndOfFile()
        }.value
        upstream.waitUntilExit()
        downstream.waitUntilExit()

        guard downstream.terminationReason == .exit else { throw CancellationError() }
        guard downstream.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: errorData))
        }
    }

    /// Runs a tool that says nothing useful about its progress, measuring what it writes.
    static func runWatchingOutput(
        _ tool: URL,
        arguments: [String],
        holding: @escaping (Process) -> Void,
        expectedBytes: Int64?,
        watching output: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        holding(process)

        let monitor = sizeMonitor(of: output, expecting: expectedBytes, onProgress: onProgress)
        defer { monitor?.cancel() }

        try process.run()
        let errorData = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()

        guard process.terminationReason == .exit else { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: errorData))
        }
    }

    /// Reports how far a file has been written by watching it grow.
    private static func sizeMonitor(
        of url: URL,
        expecting expected: Int64?,
        onProgress: @escaping (Double) -> Void
    ) -> Task<Void, Never>? {
        guard let expected, expected > 0 else { return nil }
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let written = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let fraction = min(Double(written) / Double(expected), 0.99)
                await MainActor.run { onProgress(fraction) }
            }
        }
    }

    private static func lastLine(of data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Runs ffmpeg, reporting how far through the file it has got.
    ///
    /// Progress comes from `-progress pipe:1`, which prints `out_time_us` as it goes —
    /// measuring the timeline rather than guessing from bytes, so it stays honest whether
    /// the streams are being copied or re-encoded.
    static func run(
        _ tool: URL,
        arguments: [String],
        duration: Double,
        holding: @escaping (Process) -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        holding(process)

        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard duration > 0,
                      let microseconds = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let fraction = min(microseconds / 1_000_000 / duration, 1)
                Task { @MainActor in onProgress(fraction) }
            }
        }

        try process.run()

        let errorData = await Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil

        // Terminated by hand rather than by finishing: SIGTERM shows up as an uncaught signal.
        guard process.terminationReason == .exit else { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }
}

// MARK: - Files

extension URL {
    /// The containers worth offering to convert.
    ///
    /// MKV is the reason this app exists, but the same wall stands in front of everything
    /// else AVFoundation has no demuxer for.
    static let convertibleExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "vob", "ogv", "ogm",
        "ts", "m2ts", "mts", "mpg", "mpeg", "divx", "rmvb", "asf", "3gp"
    ]

    var looksLikeVideo: Bool {
        isFileURL && Self.convertibleExtensions.contains(pathExtension.lowercased())
    }

    /// Where to write the converted copy: beside the original, never over it.
    static func unused(forConverting source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent

        let first = directory.appending(path: "\(stem).mp4")
        guard FileManager.default.fileExists(atPath: first.path(percentEncoded: false)) else {
            return first
        }
        for suffix in 2... {
            let candidate = directory.appending(path: "\(stem) \(suffix).mp4")
            if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return first
    }
}

// MARK: - The window

struct ContentView: View {
    @Environment(ConversionQueue.self) private var queue
    @State private var isTargeted = false
    @State private var isChoosingFiles = false

    var body: some View {
        VStack(spacing: 0) {
            if Tools.isInstalled {
                content
                if !queue.jobs.isEmpty {
                    Divider()
                    statusBar
                }
            } else {
                missingTools
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        // On the whole window rather than the drop zone alone, so files can still be
        // dropped once the list has replaced it.
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted && !queue.jobs.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .toolbar {
            ToolbarItemGroup {
                if Tools.canConvertDolbyVision {
                    @Bindable var queue = queue
                    Toggle(isOn: $queue.optimizesBitrate) {
                        Label("Optimize Dolby Vision", systemImage: "wand.and.sparkles")
                    }
                    .toggleStyle(.button)
                    // The only control here that says what it does. A wand on its own gives
                    // no hint which of the two things it is, and one of them costs an hour.
                    .labelStyle(.titleAndIcon)
                    .help("""
                        Bring a Dolby Vision picture down to the bit rate Immersive Cinema \
                        targets, keeping the Dolby Vision. Its own optimizer can't: \
                        re-encoding there loses the Dolby Vision metadata.
                        """)
                    .disabled(queue.isBusy)
                }
                if queue.isBusy {
                    Button("Stop", systemImage: "stop.fill") { queue.cancelAll() }
                        .help("Stop the conversion running now and drop the rest")
                }
                Button("Clear", systemImage: "xmark.circle") { queue.clearFinished() }
                    .disabled(queue.jobs.isEmpty)
                    .help("Remove finished, failed and stopped rows")
                Button("Add Files…", systemImage: "plus") { isChoosingFiles = true }
                    .disabled(!Tools.isInstalled)
                    .help("Add files to convert")
            }
        }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.movie, .video, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if queue.jobs.isEmpty {
            dropZone
        } else {
            List(queue.jobs) { job in
                JobRow(job: job) { queue.retry(job.id) }
                    .contextMenu {
                        if case .finished = job.status, let output = job.output {
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([output])
                            }
                            Divider()
                        }
                        if job.isRetryable {
                            Button("Try Again", systemImage: "arrow.clockwise") {
                                queue.retry(job.id)
                            }
                        }
                        Button(
                            job.isConverting ? "Stop" : "Remove",
                            systemImage: job.isConverting ? "stop.fill" : "trash",
                            role: .destructive
                        ) {
                            queue.remove(job.id)
                        }
                    }
            }
            .listStyle(.inset)
            .animation(.default, value: queue.jobs.count)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .symbolEffect(.bounce, value: isTargeted)

            VStack(spacing: 6) {
                Text("Drop video here")
                    .font(.title2.weight(.medium))
                Text("MKV and anything else Immersive Cinema can’t open, rewrapped as MP4 beside the original.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            toolsNote
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(.clear))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                }
                .padding(16)
        }
    }

    /// Whether Dolby Vision can be rebuilt, said before a file is dropped rather than
    /// discovered afterwards.
    ///
    /// Without `dovi_tool` and `MP4Box` the conversion still works and the toggle simply
    /// isn't there — which looks like the app not offering the feature rather than the
    /// machine not being able to.
    private var toolsNote: some View {
        Label {
            Text(Tools.canConvertDolbyVision
                 ? "Dolby Vision will be rebuilt as profile 8.1."
                 : "Install dovi_tool and gpac to keep Dolby Vision.")
        } icon: {
            Image(systemName: Tools.canConvertDolbyVision ? "checkmark.seal" : "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(queueSummary)
            Spacer()
            if queue.optimizesBitrate {
                Label("Optimizing Dolby Vision", systemImage: "wand.and.sparkles")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var queueSummary: String {
        var parts = ["\(queue.finishedCount) of \(queue.jobs.count) converted"]
        if queue.failedCount > 0 {
            parts.append("\(queue.failedCount) failed")
        }
        return parts.joined(separator: " · ")
    }

    private var missingTools: some View {
        ContentUnavailableView {
            Label("ffmpeg Not Found", systemImage: "exclamationmark.triangle")
        } description: {
            Text("This app drives the ffmpeg already on your Mac rather than shipping its own.")
        } actions: {
            Text(verbatim: "brew install ffmpeg")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        }
    }
}

struct JobRow: View {
    let job: ConversionQueue.Job
    let onRetry: () -> Void

    private static let byteFormat = ByteCountFormatStyle(style: .file)

    var body: some View {
        HStack(spacing: 14) {
            still

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(job.source.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                }

                // What's in the file, which is worth knowing before the conversion runs —
                // and worth checking after, since the whole job is a decision about these
                // streams.
                if let details = job.details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                status
            }

            actions
        }
        .padding(.vertical, 6)
    }

    /// A frame from the file, with how far through it is drawn across the bottom.
    ///
    /// The bar goes on the artwork rather than under the text, which is where the library
    /// puts it on a card someone is partway through — white over a dimmed track, the way a
    /// scrubber reads, rather than the accent colour, because it's sitting on a picture and
    /// not on app chrome.
    private var still: some View {
        Group {
            if let image = job.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: Layout.thumbnailWidth, height: Layout.thumbnailWidth * 9 / 16)
        .clipShape(.rect(cornerRadius: Layout.cornerRadius))
        .overlay(alignment: .bottom) {
            if case .converting(let fraction) = job.status {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule()
                            .fill(.white)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: Layout.progressBarHeight)
                .padding(Layout.progressBarInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The state badge sits on the still, so the row reads as a picture and a
            // description rather than a picture, a symbol and a description.
            //
            // Filled and white on a solid disc rather than a bare tinted symbol: it has to
            // stay legible on a bright frame, a black one, and the grey placeholder a file
            // whose still hasn't been read yet shows. A hierarchical style survives none of
            // those three.
            Image(systemName: badge.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(badge.tint, in: .circle)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .padding(5)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.tertiary)
        case .converting:
            Text(job.summary ?? "Converting").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .finished:
            Text(job.summary ?? "Done").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        case .cancelled:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The figure on the right of the name: what the file weighs, how far in it is, or
    /// what it came out at.
    private var trailing: String? {
        switch job.status {
        case .waiting, .cancelled:
            job.sourceBytes.map { $0.formatted(Self.byteFormat) }
        case .converting(let fraction):
            [fraction.formatted(.percent.precision(.fractionLength(0))), timeRemaining]
                .compactMap(\.self).joined(separator: " · ")
        case .finished:
            switch (job.sourceBytes, job.outputBytes) {
            case (let before?, let after?):
                "\(before.formatted(Self.byteFormat)) → \(after.formatted(Self.byteFormat))"
            default:
                job.outputBytes.map { $0.formatted(Self.byteFormat) }
            }
        case .failed:
            nil
        }
    }

    /// Roughly how much longer, extrapolated from how long the finished part took.
    ///
    /// Held back until a fiftieth of the way in: before that the estimate swings wildly,
    /// and a number that jumps from four minutes to forty is worse than no number. It
    /// recomputes whenever progress changes, so there's no timer behind it.
    private var timeRemaining: String? {
        guard case .converting(let fraction) = job.status,
              let startedAt = job.startedAt,
              fraction > 0.02
        else { return nil }

        let elapsed = Date.now.timeIntervalSince(startedAt)
        let remaining = elapsed / fraction - elapsed
        guard remaining >= 1 else { return nil }

        let text = Duration.seconds(remaining).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        return "\(text) left"
    }

    @ViewBuilder
    private var actions: some View {
        switch job.status {
        case .finished:
            if let output = job.output {
                Button("Show", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Show in Finder")
            }
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Try this file again")
        case .waiting, .converting:
            EmptyView()
        }
    }

    private var badge: (symbol: String, tint: Color) {
        switch job.status {
        case .waiting: ("clock", .gray)
        case .converting: ("arrow.triangle.2.circlepath", .accentColor)
        case .finished: ("checkmark", .green)
        case .failed: ("exclamationmark", .red)
        case .cancelled: ("minus", .gray)
        }
    }
}
