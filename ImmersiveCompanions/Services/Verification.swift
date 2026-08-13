/*
Abstract:
Checking that what came out is a file AVFoundation will actually play.
*/

import AVFoundation

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
