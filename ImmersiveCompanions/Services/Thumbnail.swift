/*
Abstract:
A frame taken out of a file, to show what is about to be converted.
*/

import AVFoundation
import ImageIO
import SwiftUI

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
