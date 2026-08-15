/*
Abstract:
Reading Dolby Vision's own letterbox geometry from the source, so a re-encode can crop to the
studio's real frame rather than guess at one.
*/

import Foundation

// MARK: - Letterbox bars, from Dolby's own metadata

/// Finds the active-picture crop a Dolby Vision source already declares, for the one path
/// that's allowed to act on it.
///
/// Apple's own store encodes carry no letterbox bars — the frame *is* the active picture —
/// and the two lossless ways to get there without touching a pixel both fail in AVFoundation:
/// an SPS conformance-window top-crop decodes to a black or mispositioned frame through
/// `AVPlayer`, and MP4 clean aperture sizes the window without moving a sample, so the picture
/// plays back squished into it. Only a real crop of real pixels works, which is why this is
/// asked for only on the route that is re-encoding the picture anyway — see `ConversionQueue`.
///
/// The geometry itself doesn't need detecting. A Dolby Vision RPU carries Level 5 active-area
/// metadata that says exactly where the studio put its bars — verified on a real film at
/// `active_area_top_offset=276, bottom=276` against a 3840×2160 frame, which is 3840×1608,
/// 2.39:1. `ffprobe` never surfaces it — asked for `-show_streams` on a Dolby Vision remux the
/// only side data that comes back is the DOVI configuration record — so this reads it the only
/// way it's exposed: demux a short sample to Annex B, hand it to `dovi_tool extract-rpu`, and
/// export that RPU's Level 5 block as JSON with `dovi_tool export -d level5=`.
///
/// Sampled three times — near the start, the middle, and near the end — rather than once,
/// because a value read once is a value trusted once. A film whose framing genuinely changes
/// partway through, an IMAX shot expanding into open matte being the case that actually
/// happens, will disagree between samples, and disagreement here means no crop rather than a
/// guess at which portion is "the" frame.
enum DolbyVisionCrop {
    /// The crop this route should apply: the offset to start reading from, and the size of
    /// what's left once the bars are gone.
    struct Geometry: Equatable, Sendable {
        let left: Int
        let top: Int
        let width: Int
        let height: Int
    }

    /// How much of the file to sample at each point. Long enough that one misdecoded frame at
    /// the front of a clip can't swing the answer on its own, short enough that three of them
    /// together cost seconds rather than minutes — about 12 MB of HEVC each on a typical 4K
    /// Dolby Vision remux.
    private static let sampleLengthInSeconds = 4.0

    /// Below this in either dimension, whatever the metadata claims, cropping stops being a
    /// letterbox removal and starts being a file with almost nothing left in it.
    private static let minimumDimension = 64

    /// One sample's Level 5 offsets: how many pixels of bar sit on each edge.
    private struct Offsets: Equatable {
        let left: Int
        let right: Int
        let top: Int
        let bottom: Int
    }

    /// The shape `dovi_tool export -d level5=` writes: an editor config whose `active_area`
    /// lists every distinct offset combination seen across the exported RPUs, keyed by frame
    /// range in `edits`. A single preset means every frame in the sample agreed with itself;
    /// more than one means the framing moved within the four seconds sampled, which this
    /// treats the same as disagreement between samples — there's no single answer to read off
    /// a window that didn't hold still. Verified against `dovi_tool` 2.3.3's own bundled test
    /// RPU, which is where this shape comes from rather than the tool's documentation.
    private struct Level5Export: Decodable {
        struct ActiveArea: Decodable {
            struct Preset: Decodable {
                let left: Int
                let right: Int
                let top: Int
                let bottom: Int
            }
            let presets: [Preset]
        }
        let activeArea: ActiveArea
    }

    /// Three points to sample: near the start, the middle, and near the end, each far enough
    /// from the very edges of the file that a fade-in, a distributor card, or the last few
    /// frames of a reel don't stand in for the whole picture. A file shorter than one sample
    /// collapses all three onto the same window — reading the same handful of frames three
    /// times, which agrees with itself trivially and is no less honest than reading them once.
    private static func sampleTimes(durationInSeconds duration: Double) -> [Double] {
        guard duration > 0 else { return [0, 0, 0] }
        let latest = max(duration - sampleLengthInSeconds, 0)
        return [0.1, 0.5, 0.9].map { min(duration * $0, latest) }
    }

    /// Runs a short-lived tool to completion and reports whether it succeeded, without ever
    /// holding whichever actor asked for it.
    ///
    /// `Process.output` in `ProcessRunner` reads its pipes synchronously on the actor that
    /// calls it, which is the right trade-off for the sub-second `ffprobe` calls it normally
    /// serves, but three samples' worth of demuxing and RPU export take long enough on a large
    /// file that doing the same here would hold the main actor for it — felt as the window
    /// freezing rather than merely a slow probe. So this waits inside a detached task instead,
    /// the same technique `Process.runPiped` and `Process.runWatchingOutput` use to keep their
    /// own slow reads off it. Neither of this call's own streams is read: every tool here is
    /// told to write its result to a file rather than to standard output.
    private static func run(_ tool: URL, arguments: [String]) async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0
        }.value
    }

    /// One sample: a few seconds of Annex B video, its RPU, and that RPU's Level 5 block.
    ///
    /// Written to temporary files rather than piped between two processes — a 4-second sample
    /// is on the order of 12 MB, there's no progress to report on the way, and a pipe buys
    /// nothing here that a plain intermediate file doesn't already give more simply.
    ///
    /// `nil` on any failure along the way — a seek past the end of a short file, a sample with
    /// no RPU in it, JSON that doesn't parse. All of them mean this sample has nothing to say,
    /// which the caller treats as disagreement rather than a reason to stop asking.
    private static func offsets(
        from source: URL,
        videoStream: Int,
        at time: Double,
        ffmpeg: URL,
        doviTool: URL,
        scratch: URL
    ) async -> Offsets? {
        let sampleURL = scratch.appending(path: "sample-\(UUID().uuidString).hevc")
        let rpuURL = scratch.appending(path: "rpu-\(UUID().uuidString).bin")
        let level5URL = scratch.appending(path: "level5-\(UUID().uuidString).json")

        // No mode is passed to `extract-rpu` here: this reads the source's own, undoctored
        // geometry, not the mode-converted RPU the real pipeline injects later.
        guard await run(ffmpeg, arguments: [
            "-y", "-loglevel", "error",
            "-ss", "\(time)", "-t", "\(sampleLengthInSeconds)",
            "-i", source.path(percentEncoded: false),
            "-map", "0:\(videoStream)", "-c:v", "copy",
            "-bsf:v", "hevc_mp4toannexb", "-f", "hevc",
            sampleURL.path(percentEncoded: false)
        ]) else { return nil }

        guard await run(doviTool, arguments: [
            "extract-rpu", sampleURL.path(percentEncoded: false),
            "-o", rpuURL.path(percentEncoded: false)
        ]) else { return nil }

        guard await run(doviTool, arguments: [
            "export", "-i", rpuURL.path(percentEncoded: false),
            "-d", "level5=\(level5URL.path(percentEncoded: false))"
        ]) else { return nil }

        guard let data = try? Data(contentsOf: level5URL) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let export = try? decoder.decode(Level5Export.self, from: data),
              export.activeArea.presets.count == 1,
              let preset = export.activeArea.presets.first
        else { return nil }

        return Offsets(left: preset.left, right: preset.right, top: preset.top, bottom: preset.bottom)
    }

    /// The crop to apply, or `nil` when there isn't one worth trusting: no RPU, no bars
    /// declared, an offset that wouldn't survive 4:2:0 subsampling, a result too small to be a
    /// letterbox rather than a mistake, or three samples that couldn't agree with each other.
    ///
    /// Runs off the main actor — three short ffmpeg and `dovi_tool` round trips, none of them
    /// touching UI state — and reports failure as `nil` throughout rather than throwing: a
    /// source without a usable crop is the ordinary case for anything that isn't Dolby Vision
    /// with declared bars, not a reason to fail the conversion.
    static func geometry(for source: URL, probe: Probe, videoStream: Int) async -> Geometry? {
        guard let ffmpeg = Tools.ffmpeg, let doviTool = Tools.doviTool,
              let width = probe.picture?.width, let height = probe.picture?.height else { return nil }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "CinemaConverter-crop-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        var samples: [Offsets] = []
        for time in sampleTimes(durationInSeconds: probe.durationInSeconds) {
            guard let sample = await offsets(
                from: source, videoStream: videoStream, at: time,
                ffmpeg: ffmpeg, doviTool: doviTool, scratch: scratch
            ) else { return nil }
            samples.append(sample)
        }

        guard let agreed = samples.first, samples.allSatisfy({ $0 == agreed }) else { return nil }
        guard agreed.left.isMultiple(of: 2), agreed.right.isMultiple(of: 2),
              agreed.top.isMultiple(of: 2), agreed.bottom.isMultiple(of: 2) else { return nil }
        guard agreed.left != 0 || agreed.right != 0 || agreed.top != 0 || agreed.bottom != 0 else { return nil }

        let croppedWidth = width - agreed.left - agreed.right
        let croppedHeight = height - agreed.top - agreed.bottom
        guard croppedWidth >= minimumDimension, croppedHeight >= minimumDimension else { return nil }

        return Geometry(left: agreed.left, top: agreed.top, width: croppedWidth, height: croppedHeight)
    }
}
