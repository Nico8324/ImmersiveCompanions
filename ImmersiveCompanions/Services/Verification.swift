/*
Abstract:
Checking that what came out is a file AVFoundation will actually play — and, for a rebuilt
Dolby Vision file, that what it claims is actually true.
*/

import AVFoundation
import Foundation

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
    /// - Parameters:
    ///   - wasRebuiltAsDolbyVision: Whether this file went through
    ///     `ConversionQueue.runDolbyVision` — RPU extracted, base layer rebuilt or converted,
    ///     RPU injected, muxed by MP4Box. Passed in by the caller, which knows which route
    ///     ran, rather than guessed from the file: a plain HDR10 file and a Dolby Vision file
    ///     that lost its RPU partway through the rebuild look identical to AVFoundation, so
    ///     asking the file itself "is this Dolby Vision" isn't a question this check could
    ///     answer honestly.
    ///   - expectedCroppedSize: The picture size `DolbyVisionCrop` and the encode were told to
    ///     produce, when this job removed letterbox bars. `nil` for everything else — a copy,
    ///     a plain re-encode, or a Dolby Vision file whose bars were kept. Passed in for the
    ///     same reason as `wasRebuiltAsDolbyVision`: this check can confirm a size, not decide
    ///     on its own what size was ever asked for.
    static func check(
        _ url: URL,
        wasRebuiltAsDolbyVision: Bool,
        expectedCroppedSize: (width: Int, height: Int)? = nil
    ) async throws {
        let asset = AVURLAsset(url: url)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        let video = try await asset.loadTracks(withMediaType: .video)

        guard playable, !video.isEmpty, duration.seconds > 0 else {
            throw ConversionError.unplayableResult
        }
        guard (try? AVAssetReader(asset: asset)) != nil else {
            throw ConversionError.unplayableResult
        }

        if wasRebuiltAsDolbyVision {
            try await checkDolbyVisionRPU(url, durationInSeconds: duration.seconds)
        }

        if let expectedCroppedSize {
            try await checkCroppedSize(video, expected: expectedCroppedSize)
        }
    }

    /// Confirms the letterbox bars this job asked ffmpeg to crop actually left the file,
    /// rather than trusting that a `-vf crop` argument ffmpeg accepted was one it obeyed.
    ///
    /// Checked against `naturalSize` rather than the coded picture size on purpose: HEVC's
    /// internal, CTU-padded picture can be larger than what a player actually shows, and
    /// `naturalSize` is already the cropped, displayed frame — the figure the library itself
    /// would draw. Width is checked exactly; height is allowed a couple of pixels of slack for
    /// the same reason, in case an encoder's reported display size rounds differently from the
    /// coded height than it does for width. Not yet exercised against a real cropped encode —
    /// worth confirming this tolerance is neither too strict nor hiding a real mismatch the
    /// first time this runs against real Dolby Vision media.
    private static func checkCroppedSize(_ video: [AVAssetTrack], expected: (width: Int, height: Int)) async throws {
        guard let track = video.first else { throw ConversionError.unplayableResult }
        let size = try await track.load(.naturalSize)
        let actualWidth = Int(size.width.rounded())
        let actualHeight = Int(size.height.rounded())

        guard actualWidth == expected.width, abs(actualHeight - expected.height) <= 2 else {
            throw ConversionError.letterboxCropLost(
                expectedWidth: expected.width, expectedHeight: expected.height,
                actualWidth: actualWidth, actualHeight: actualHeight
            )
        }
    }

    /// Spot-checks that the RPU actually made it into the frames, rather than trusting
    /// that ffmpeg, `dovi_tool` and MP4Box all exiting zero means it did.
    ///
    /// The playability check above would pass regardless: it asks whether the file plays,
    /// not whether what plays is still Dolby Vision, and an `inject-rpu` that landed the
    /// RPU on the wrong frames or a `dvvC` box written over a track that no longer has one
    /// to match would both still produce a file AVFoundation opens and reads happily. So
    /// ffprobe is asked directly for the one thing that says so.
    ///
    /// Read at the start and again near the end, rather than decode the whole file to look:
    /// `-read_intervals` limits ffprobe to the seconds named rather than the frames in
    /// between, so two points a feature apart still cost next to nothing. The two are
    /// separate probes on purpose, and each must find an RPU on its own — asked together,
    /// one pass over the combined frames would accept a rebuild whose RPUs die partway
    /// through on the strength of its opening seconds, which is exactly the failure the
    /// near-end sample exists to catch.
    private static func checkDolbyVisionRPU(_ url: URL, durationInSeconds: Double) async throws {
        guard let ffprobe = Tools.ffprobe else { throw ConversionError.toolsMissing }

        let nearEnd = max(0, durationInSeconds - 10)
        for interval in ["%+2", "\(nearEnd)%+2"] {
            let output = try? await Process.output(of: ffprobe, arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_frames", "-show_entries", "frame=side_data_list",
                "-read_intervals", interval,
                "-print_format", "json",
                url.path(percentEncoded: false)
            ])

            guard let output, Verification.hasDolbyVisionRPU(in: output) else {
                throw ConversionError.dolbyVisionLost
            }
        }
    }

    private struct FrameSideData: Decodable {
        struct Frame: Decodable {
            struct SideData: Decodable {
                let sideDataType: String?
            }
            let sideDataList: [SideData]?
        }
        let frames: [Frame]
    }

    /// Whether any sampled frame carries an RPU. Matched by substring rather than an exact
    /// string: what ffmpeg actually prints is `"Dolby Vision RPU Data"`, and matching on
    /// the stable part of that rather than the whole thing is one fewer place a point
    /// release could quietly break this check.
    private static func hasDolbyVisionRPU(in json: Data) -> Bool {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(FrameSideData.self, from: json) else { return false }
        return decoded.frames.contains { frame in
            frame.sideDataList?.contains { ($0.sideDataType ?? "").contains("Dolby Vision RPU") } == true
        }
    }
}
