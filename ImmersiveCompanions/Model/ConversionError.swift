/*
Abstract:
What can go wrong, and how the result is checked afterwards.
*/

import Foundation

// MARK: - Doing it

enum ConversionError: LocalizedError {
    case toolsMissing
    case noVideo
    case notEnoughSpace(needed: Int64, free: Int64)
    case unplayableResult
    case dolbyVisionLost
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
        case .dolbyVisionLost:
            return "The Dolby Vision RPU didn’t survive the rebuild, so the file was deleted rather than kept " +
                "looking like Dolby Vision when it no longer is."
        case .failed(let message):
            return message.isEmpty ? "The conversion failed." : message
        }
    }
}
