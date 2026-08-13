/*
Abstract:
Finding the command-line tools this app drives, rather than shipping them.
*/

import Foundation

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
