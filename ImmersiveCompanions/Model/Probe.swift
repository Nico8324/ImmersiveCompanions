/*
Abstract:
What ffprobe says a file contains.
*/

import Foundation

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
        let tags: [String: String]?

        /// The Dolby Vision record on this stream, if it carries one.
        var dolbyVision: SideData? {
            sideDataList?.first { $0.dvProfile != nil }
        }

        /// What this track alone is spending, in bits per second, or `nil` if it won't say.
        ///
        /// Matroska doesn't fill in `bit_rate` per stream — it comes back `N/A` — and the
        /// obvious fallback, the rate ffprobe reports for the whole file, is not this
        /// track: on a Blu-ray rip it also counts lossless audio and a dozen subtitle
        /// tracks, which read as 79.8 Mbps where the picture was spending 66.5. Judging a
        /// picture by that overstates it by whatever the soundtrack costs, and a file whose
        /// video is comfortably within budget can be re-encoded because its audio pushed
        /// the total over.
        ///
        /// Matroska does write the real figure per track, as `BPS` or as a byte count to
        /// divide by the duration, so those are asked first. When nothing says, the answer
        /// is nil rather than the file's rate: not knowing is not the same as being fat,
        /// and guessing in that direction costs a generation of quality.
        func bitsPerSecond(durationInSeconds duration: Double) -> Int? {
            if let bitRate, let value = Int(bitRate), value > 0 { return value }
            if let value = tag(named: "BPS").flatMap(Int.init), value > 0 { return value }
            if duration > 0, let bytes = tag(named: "NUMBER_OF_BYTES").flatMap(Double.init), bytes > 0 {
                return Int(bytes * 8 / duration)
            }
            return nil
        }

        /// A Matroska tag, matched by name and ignoring the language suffix a muxer may
        /// append — the same tag arrives as `BPS` on one file and `BPS-eng` on the next.
        private func tag(named name: String) -> String? {
            tags?.first { $0.key.uppercased().hasPrefix(name) }?.value
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

    /// A chapter mark, which matters here only so a broken set can be spotted.
    struct Chapter: Decodable {
        let startTime: String?

        var startInSeconds: Double { Double(startTime ?? "") ?? 0 }
    }

    let streams: [Stream]
    let format: Format
    let chapters: [Chapter]?

    /// Whether the file's chapters run past the end of the file itself.
    ///
    /// They can, and a clip cut out of a longer film with `-c copy` is how: ffmpeg carries
    /// the chapters over and rebases the first one, leaving the rest at offsets belonging to
    /// the original. Copied onward, MP4Box imports them as a `text` track longer than the
    /// media — and **AVFoundation takes an asset's duration from its longest track**, so a
    /// two-minute file reports as an hour and fifty. Immersive Cinema reads `Video.duration`
    /// straight off the file, so the library would show that runtime and believe it.
    var hasChaptersPastTheEnd: Bool {
        guard let chapters, !chapters.isEmpty, durationInSeconds > 0 else { return false }
        // A little slack: the last chapter legitimately starts just before the end.
        return chapters.contains { $0.startInSeconds > durationInSeconds + 1 }
    }

    var durationInSeconds: Double {
        Double(format.duration ?? "") ?? 0
    }

    /// How many bits the picture spends on each pixel of each frame, or `nil` if the file
    /// won't say what the picture costs.
    var bitsPerPixel: Double? {
        guard let picture,
              let bitrate = picture.bitsPerSecond(durationInSeconds: durationInSeconds),
              let width = picture.width, let height = picture.height,
              width > 0, height > 0 else { return nil }
        let pixelsPerSecond = Double(width * height) * picture.framesPerSecond
        guard pixelsPerSecond > 0 else { return nil }
        return Double(bitrate) / pixelsPerSecond
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
            "-show_format", "-show_streams", "-show_chapters",
            url.path(percentEncoded: false)
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Probe.self, from: output)
    }
}
