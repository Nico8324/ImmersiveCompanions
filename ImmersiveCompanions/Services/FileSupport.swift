/*
Abstract:
Small things about files that several parts of the app need.
*/

import Foundation

// MARK: - Files

extension URL {
    /// How large the file is now, asked afresh every time.
    ///
    /// Not `resourceValues(forKeys:)`, which caches what it read the first time and keeps
    /// handing it back. That's harmless for a file sitting still and wrong for one being
    /// written: a size polled while a mux was starting pinned the answer at nothing, so a
    /// 64 GB result was measured, reported and displayed as zero bytes long after it had
    /// finished. `FileManager` reads the file system each time it's asked.
    nonisolated var currentFileSize: Int64? {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path(percentEncoded: false))[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }

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
