/*
Abstract:
The window: a list of what is queued, and somewhere to drop more.
*/

import SwiftUI
import UniformTypeIdentifiers

// MARK: - The window

struct ContentView: View {
    @Environment(ConversionQueue.self) private var queue
    @State private var isTargeted = false
    @State private var isChoosingFiles = false

    var body: some View {
        VStack(spacing: 0) {
            if Tools.isInstalled {
                content
                if !queue.jobs.isEmpty {
                    Divider()
                    statusBar
                }
            } else {
                missingTools
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        // On the whole window rather than the drop zone alone, so files can still be
        // dropped once the list has replaced it.
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted && !queue.jobs.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .toolbar {
            ToolbarItemGroup {
                // Only once something in the list is actually Dolby Vision. Offering it on
                // the strength of the tools being installed put a control in the window
                // that did nothing at all for a queue of ordinary files — pressed once,
                // nothing changed, and it taught you not to trust the toolbar.
                if queue.hasDolbyVision {
                    @Bindable var queue = queue
                    Toggle(isOn: $queue.optimizesBitrate) {
                        Label("Optimize Dolby Vision", systemImage: "wand.and.sparkles")
                    }
                    .toggleStyle(.button)
                    // The only control here that says what it does. A wand on its own gives
                    // no hint which of the two things it is, and one of them costs an hour.
                    .labelStyle(.titleAndIcon)
                    .help(queue.dolbyVisionAdvice)
                    .disabled(queue.isBusy)
                }
                if queue.isBusy {
                    Button("Stop", systemImage: "stop.fill") { queue.cancelAll() }
                        .help("Stop the conversion running now and drop the rest")
                }
                Button("Clear", systemImage: "xmark.circle") { queue.clearFinished() }
                    .disabled(queue.jobs.isEmpty)
                    .help("Remove finished, failed and stopped rows")
                Button("Add Files…", systemImage: "plus") { isChoosingFiles = true }
                    .disabled(!Tools.isInstalled)
                    .help("Add files to convert")
            }
        }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.movie, .video, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if queue.jobs.isEmpty {
            dropZone
        } else {
            List(queue.jobs) { job in
                JobRow(job: job) { queue.retry(job.id) }
                    .contextMenu {
                        if case .finished = job.status, let output = job.output {
                            Button("Show in Finder", systemImage: "folder") {
                                NSWorkspace.shared.activateFileViewerSelecting([output])
                            }
                            Divider()
                        }
                        if job.isRetryable {
                            Button("Try Again", systemImage: "arrow.clockwise") {
                                queue.retry(job.id)
                            }
                        }
                        Button(
                            job.isConverting ? "Stop" : "Remove",
                            systemImage: job.isConverting ? "stop.fill" : "trash",
                            role: .destructive
                        ) {
                            queue.remove(job.id)
                        }
                    }
            }
            .listStyle(.inset)
            .animation(.default, value: queue.jobs.count)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .symbolEffect(.bounce, value: isTargeted)

            VStack(spacing: 6) {
                Text("Drop video here")
                    .font(.title2.weight(.medium))
                Text("MKV and anything else Immersive Cinema can’t open, rewrapped as MP4 beside the original.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            toolsNote
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? AnyShapeStyle(.tint.opacity(0.06)) : AnyShapeStyle(.clear))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                }
                .padding(16)
        }
    }

    /// Whether Dolby Vision can be rebuilt, said before a file is dropped rather than
    /// discovered afterwards.
    ///
    /// Without `dovi_tool` and `MP4Box` the conversion still works and the toggle simply
    /// isn't there — which looks like the app not offering the feature rather than the
    /// machine not being able to.
    private var toolsNote: some View {
        Label {
            Text(Tools.canConvertDolbyVision
                 ? "Dolby Vision will be rebuilt as profile 8.1."
                 : "Install dovi_tool and gpac to keep Dolby Vision.")
        } icon: {
            Image(systemName: Tools.canConvertDolbyVision ? "checkmark.seal" : "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Text(queueSummary)
            Spacer()
            if queue.optimizesBitrate {
                Label("Optimizing Dolby Vision", systemImage: "wand.and.sparkles")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var queueSummary: String {
        var parts = ["\(queue.finishedCount) of \(queue.jobs.count) converted"]
        if queue.failedCount > 0 {
            parts.append("\(queue.failedCount) failed")
        }
        return parts.joined(separator: " · ")
    }

    private var missingTools: some View {
        ContentUnavailableView {
            Label("ffmpeg Not Found", systemImage: "exclamationmark.triangle")
        } description: {
            Text("This app drives the ffmpeg already on your Mac rather than shipping its own.")
        } actions: {
            Text(verbatim: "brew install ffmpeg")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        }
    }
}
