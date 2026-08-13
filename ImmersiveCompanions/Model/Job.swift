/*
Abstract:
One file on its way through the queue, and everything the window shows about it.
*/

import AppKit
import Foundation

/// A file queued for conversion, and what has been learned about it so far.
///
/// Lifted out of ``ConversionQueue`` so the thing being managed is not defined inside the
/// thing managing it: the queue owns the work, this owns what a row has to say.
struct Job: Identifiable {
    enum Status: Equatable {
        case waiting
        case converting(fraction: Double)
        case finished
        case failed(String)
        case cancelled
    }

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

    /// The Dolby Vision profile this file carries, once it's been read.
    var dolbyVisionProfile: Int?

    /// How many bits the picture spends per pixel of each frame.
    ///
    /// The measure that tells a disc master from a botched encode, which the bit rate
    /// alone cannot: a 4K remux at 66 Mbps and a mangled 1080p at 60 Mbps are the same
    /// number and nothing alike. Per pixel they're 0.33 and 1.21, and Apple's own rungs
    /// sit around 0.15 to 0.20 — so the first is spending its bits and the second is
    /// wasting them.
    var bitsPerPixel: Double?

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
        self.sourceBytes = source.currentFileSize
    }
}
