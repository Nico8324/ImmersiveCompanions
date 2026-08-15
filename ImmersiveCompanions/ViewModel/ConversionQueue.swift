/*
Abstract:
The queue of files being converted, and the state the window draws from.
*/

import Foundation
import SwiftUI

/// The files waiting to be converted, and the one being converted now.
///
/// One at a time on purpose: the encoder is a fixed piece of hardware, so a second
/// conversion alongside the first finishes no sooner and just competes for disk.
@MainActor
@Observable
final class ConversionQueue {


    private(set) var jobs: [Job] = []

    /// Whether to bring an over-fat Dolby Vision picture down to the library's target on
    /// the way through.
    ///
    /// Off by default. Converting is the job; re-encoding is a separate decision that costs
    /// a generation of quality and a good deal of time, and it should be asked for. It only
    /// applies to Dolby Vision, because that's the only case Immersive Cinema can't handle
    /// for itself — for anything else its own optimizer does this properly, after import.
    ///
    /// Kept between launches. Whether someone wants their library prepared this way is a
    /// standing preference, not something to answer again every time the app opens — and a
    /// switch that forgets is a switch you stop trusting.
    var optimizesBitrate = UserDefaults.standard.bool(forKey: ConversionQueue.optimizeKey) {
        didSet { UserDefaults.standard.set(optimizesBitrate, forKey: Self.optimizeKey) }
    }

    static let optimizeKey = "optimizesDolbyVision"

    private var isRunning = false
    private var current: Process?
    private var stillTask: Task<Void, Never>?

    var isBusy: Bool { isRunning }

    /// Whether anything in the list carries Dolby Vision this app could rebuild.
    ///
    /// What decides the toggle is in the window, not what's installed on the machine: the
    /// tools being present says the feature could work, not that it would do anything to
    /// these files.
    ///
    /// Any job counts, not only the ones still waiting. A single dropped file goes straight
    /// to converting and the probe that discovers its profile finishes later still, so
    /// keying on `waiting` left a control that was correctly scoped and never actually
    /// there. The setting itself is remembered between launches, which is what makes it
    /// useful before a drop rather than during one; here it stays visible so you can see
    /// what it's set to, and change it for what comes next or for a retry.
    var hasDolbyVision: Bool {
        Tools.canConvertDolbyVision && jobs.contains { job in
            job.dolbyVisionProfile.map { DolbyVisionPlan.mode(forProfile: $0) != nil } == true
        }
    }

    /// What re-encoding would do to the files waiting, in a sentence.
    ///
    /// The toggle used to explain the feature. It's more use explaining the decision: the
    /// same switch is obviously right on a wasteful encode and a real loss on a disc
    /// master, and the file itself says which it is.
    var dolbyVisionAdvice: String {
        let densities = jobs
            .filter { $0.dolbyVisionProfile != nil }
            .compactMap(\.bitsPerPixel)
        let base = """
            Bring the picture down to the bit rate Immersive Cinema targets, keeping the \
            Dolby Vision — which its own optimizer can't, because re-encoding there loses \
            the metadata.
            """

        guard let densest = densities.max() else { return base }
        return densest >= PlaybackTarget.masteredBitsPerPixel
            ? base + "\n\nThis looks like a disc master, at "
                + String(format: "%.2f", densest)
                + " bits per pixel. Those bits are doing work: re-encoding trades picture "
                + "quality for space rather than removing waste."
            : base + "\n\nThis encode is spending "
                + String(format: "%.2f", densest)
                + " bits per pixel, well above what the picture needs. There's little to lose."
    }

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
                    if let probe {
                        job.details = probe.mediaSummary
                        job.dolbyVisionProfile = probe.picture?.dolbyVision?.dvProfile
                        job.bitsPerPixel = probe.bitsPerPixel
                    }
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
    /// Reads the mastering display and content light level, which the main probe misses.
    ///
    /// ffprobe reports both on the frames rather than on the stream — asked for
    /// `-show_streams` on a Dolby Vision remux, the only side data that comes back is the
    /// DOVI configuration record. One frame is enough, since static metadata is static.
    ///
    /// Returns empty rather than throwing: a file without HDR metadata is the ordinary case
    /// for anything that isn't HDR, and a file that won't answer is not a reason to refuse
    /// to convert it.
    private static func readHDRMetadata(from source: URL, probe: Probe) async -> HDRMetadata {
        guard let ffprobe = Tools.ffprobe, let picture = probe.picture else {
            return HDRMetadata(framesJSON: Data())
        }
        let output = try? await Process.output(of: ffprobe, arguments:
            HDRMetadata.probeArguments(for: source, videoStream: picture.index))
        return HDRMetadata(framesJSON: output ?? Data())
    }

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

    /// Whether this file's letterbox bars are worth removing, and by how much.
    ///
    /// Only asked when the picture is already being re-encoded for Dolby Vision. Cropping
    /// needs a real re-encode — the lossless ways to shrink the frame, an SPS conformance
    /// window or MP4 clean aperture, both play back wrong through AVPlayer — so this is asked
    /// on the one route that already produces new pixels rather than copying old ones. See
    /// `DolbyVisionCrop`.
    private static func dolbyVisionCropGeometry(
        for dolbyVision: DolbyVisionPlan?,
        source: URL,
        probe: Probe
    ) async -> DolbyVisionCrop.Geometry? {
        guard let dolbyVision, dolbyVision.optimizedBitrate != nil else { return nil }
        return await DolbyVisionCrop.geometry(for: source, probe: probe, videoStream: dolbyVision.videoStream)
    }

    /// Runs the three steps a Dolby Vision rebuild takes.
    ///
    /// The weights are how long each actually takes rather than an even split: the demux
    /// and RPU rewrite is a full pass over the video, the audio is small beside it, and
    /// GPAC then writes the whole file out again.
    private func runDolbyVision(
        _ plan: DolbyVisionPlan,
        probe: Probe,
        hdr: HDRMetadata,
        crop: DolbyVisionCrop.Geometry?,
        sidecars: [SidecarSubtitle],
        from source: URL,
        to destination: URL,
        onProgress: @escaping @MainActor (Double) -> Void
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
        let sourceBytes = source.currentFileSize

        if let bitrate = plan.encodeBitrate(cropped: crop, picture: probe.picture, probe: probe) {
            // The RPU comes out first, the picture is re-encoded without it, and it goes
            // back in afterwards. Every frame is still where it was, so every RPU still
            // lands on the frame it describes.
            let rpuURL = scratch.appending(path: "rpu.bin")
            let encodedURL = scratch.appending(path: "encoded.hevc")

            let extraction = plan.extractRPUArguments(from: source, crop: crop != nil)
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
                    framesPerSecond: probe.picture?.framesPerSecond ?? 24,
                    hdr: hdr,
                    crop: crop
                ),
                duration: probe.durationInSeconds,
                holding: { self.current = $0 }
            ) { onProgress(0.05 + $0 * 0.65) }

            try await Process.runWatchingOutput(
                doviTool,
                arguments: plan.injectArguments(video: encodedURL, rpu: rpuURL, to: videoURL),
                holding: { self.current = $0 },
                expectedBytes: encodedURL.currentFileSize,
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
            arguments: Plan.trackOnlyArguments(for: probe, from: source, to: tracksURL, sidecars: sidecars),
            duration: probe.durationInSeconds,
            holding: { self.current = $0 }
        ) { onProgress(0.80 + $0 * 0.05) }

        // Put them together, with the signalling that makes it Dolby Vision.
        try await Process.runWatchingOutput(
            mp4box,
            arguments: plan.muxArguments(video: videoURL, tracks: tracksURL, to: destination),
            holding: { self.current = $0 },
            expectedBytes: videoURL.currentFileSize,
            watching: destination
        ) { onProgress(0.85 + $0 * 0.15) }
    }

    /// Refuses a conversion the disk can't hold.
    ///
    /// The estimate is the source's own size. The video is normally copied whole, so the
    /// output lands within a few per cent of it either way — smaller when a fat lossless
    /// audio track becomes AAC, larger when nothing does.
    private func checkSpace(for source: URL, writingTo destination: URL) throws {
        guard let needed = source.currentFileSize,
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
            let dolbyVision = Self.dolbyVisionPlan(for: probe, optimizing: optimizesBitrate)
            // Read separately from the probe, because ffprobe reports the mastering display
            // and content light level on the frames rather than the stream. x265 drops both
            // unless handed them, and the specification asks for them (1.35).
            let hdr = await Self.readHDRMetadata(from: source, probe: probe)
            // Only asked when the picture above is already being re-encoded — see
            // `dolbyVisionCropGeometry`.
            let cropGeometry = await Self.dolbyVisionCropGeometry(for: dolbyVision, source: source, probe: probe)

            // Subtitle files sitting beside the source — PGS's major-language replacement.
            // Each is checked against the probe's own duration before it's trusted with
            // anything; one that fails the check is left out of `sidecars` entirely and its
            // reason folded into the row's summary below, rather than muxed in on faith.
            var sidecarSkipNotes: [String] = []
            let sidecars = SidecarSubtitle.discover(for: source).filter { sidecar in
                if let reason = sidecar.skipReason(durationInSeconds: probe.durationInSeconds) {
                    sidecarSkipNotes.append(reason)
                    return false
                }
                return true
            }

            let plan = try Plan(
                for: probe,
                from: source,
                to: destination,
                isRebuildingDolbyVision: dolbyVision != nil,
                hdr: hdr,
                sidecars: sidecars
            )

            // The output is about the size of the input — the video is usually copied
            // whole. Better to say so now than to fill the disk and fail at the far end of
            // an hour's work.
            try checkSpace(for: source, writingTo: destination)
            let reencodedBitrate = dolbyVision?.encodeBitrate(cropped: cropGeometry, picture: probe.picture, probe: probe)
            let outcomeSummary = switch (dolbyVision, reencodedBitrate) {
            case (nil, _):
                plan.summary
            case (_, let bitrate?):
                "Dolby Vision 8.1 kept, picture re-encoded at "
                    + "\(Int((Double(bitrate) / 1_000_000).rounded())) Mbps"
                    + (cropGeometry.map { ", letterbox removed — \($0.width)×\($0.height)" } ?? "")
                    + ", " + plan.summary
            default:
                "Dolby Vision → profile 8.1, " + plan.summary
            }
            let summary = sidecarSkipNotes.isEmpty
                ? outcomeSummary
                : ([outcomeSummary] + sidecarSkipNotes).joined(separator: ", ")
            update(id) { job in
                job.summary = summary
                job.details = probe.mediaSummary
                job.startedAt = .now
                job.status = .converting(fraction: 0)
            }

            // Typed as main-actor isolated rather than plain, which is what makes it
            // `Sendable` enough to hand to the process runners: they call it from a pipe's
            // readability handler and from a detached task watching a file grow, both off
            // the main actor, and both hop back here before it runs.
            let report: @MainActor (Double) -> Void = { fraction in
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
                    hdr: hdr,
                    crop: cropGeometry,
                    sidecars: sidecars,
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

            try await Verification.check(
                destination,
                wasRebuiltAsDolbyVision: dolbyVision != nil,
                expectedCroppedSize: cropGeometry.map { (width: $0.width, height: $0.height) }
            )

            update(id) { job in
                job.output = destination
                job.outputBytes = destination.currentFileSize
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
