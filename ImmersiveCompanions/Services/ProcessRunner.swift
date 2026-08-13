/*
Abstract:
Running a command-line tool and reading its progress as it goes.
*/

import Foundation

// MARK: - Running ffmpeg

extension Process {
    /// Runs a tool and returns everything it wrote to standard output.
    static func output(of tool: URL, arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    /// Runs one tool with its output piped straight into another.
    ///
    /// Neither end can report progress here — the first tool's standard output is carrying
    /// the video, not a progress feed — so the file being written is measured as it grows
    /// instead. It ends up smaller than what went in, since the enhancement layer is
    /// dropped along the way, so this runs slightly ahead of the truth rather than behind.
    static func runPiped(
        _ first: URL,
        arguments firstArguments: [String],
        into second: URL,
        arguments secondArguments: [String],
        holding: @escaping @MainActor (Process) -> Void,
        expectedBytes: Int64?,
        watching output: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let upstream = Process()
        upstream.executableURL = first
        upstream.arguments = firstArguments

        let downstream = Process()
        downstream.executableURL = second
        downstream.arguments = secondArguments

        let bridge = Pipe()
        upstream.standardOutput = bridge
        downstream.standardInput = bridge

        let upstreamErrors = Pipe()
        let downstreamErrors = Pipe()
        upstream.standardError = upstreamErrors
        downstream.standardError = downstreamErrors
        holding(downstream)

        let monitor = sizeMonitor(of: output, expecting: expectedBytes, onProgress: onProgress)
        defer { monitor?.cancel() }

        try upstream.run()
        try downstream.run()

        let errorData = await Task.detached {
            _ = upstreamErrors.fileHandleForReading.readDataToEndOfFile()
            return downstreamErrors.fileHandleForReading.readDataToEndOfFile()
        }.value
        upstream.waitUntilExit()
        downstream.waitUntilExit()

        guard downstream.terminationReason == .exit else { throw CancellationError() }
        guard downstream.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: errorData))
        }
    }

    /// Runs a tool that says nothing useful about its progress, measuring what it writes.
    static func runWatchingOutput(
        _ tool: URL,
        arguments: [String],
        holding: @escaping @MainActor (Process) -> Void,
        expectedBytes: Int64?,
        watching output: URL,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        holding(process)

        let monitor = sizeMonitor(of: output, expecting: expectedBytes, onProgress: onProgress)
        defer { monitor?.cancel() }

        try process.run()
        let errorData = await Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()

        guard process.terminationReason == .exit else { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(lastLine(of: errorData))
        }
    }

    /// Reports how far a file has been written by watching it grow.
    private static func sizeMonitor(
        of url: URL,
        expecting expected: Int64?,
        onProgress: @escaping @MainActor (Double) -> Void
    ) -> Task<Void, Never>? {
        guard let expected, expected > 0 else { return nil }
        return Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                let written = url.currentFileSize ?? 0
                let fraction = min(Double(written) / Double(expected), 0.99)
                await MainActor.run { onProgress(fraction) }
            }
        }
    }

    private static func lastLine(of data: Data) -> String {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Runs ffmpeg, reporting how far through the file it has got.
    ///
    /// Progress comes from `-progress pipe:1`, which prints `out_time_us` as it goes —
    /// measuring the timeline rather than guessing from bytes, so it stays honest whether
    /// the streams are being copied or re-encoded.
    static func run(
        _ tool: URL,
        arguments: [String],
        duration: Double,
        holding: @escaping @MainActor (Process) -> Void,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        holding(process)

        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard duration > 0,
                      let microseconds = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let fraction = min(microseconds / 1_000_000 / duration, 1)
                Task { @MainActor in onProgress(fraction) }
            }
        }

        try process.run()

        let errorData = await Task.detached { err.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil

        // Terminated by hand rather than by finishing: SIGTERM shows up as an uncaught signal.
        guard process.terminationReason == .exit else { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            throw ConversionError.failed(String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }
}
