/*
Abstract:
One file in the list, and everything it has to say about itself.
*/

import SwiftUI

struct JobRow: View {
    let job: Job
    let onRetry: () -> Void

    private static let byteFormat = ByteCountFormatStyle(style: .file)

    var body: some View {
        HStack(spacing: 14) {
            still

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(job.source.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let trailing {
                        Text(trailing)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                    }
                }

                // What's in the file, which is worth knowing before the conversion runs —
                // and worth checking after, since the whole job is a decision about these
                // streams.
                if let details = job.details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                status
            }

            actions
        }
        .padding(.vertical, 6)
    }

    /// A frame from the file, with how far through it is drawn across the bottom.
    ///
    /// The bar goes on the artwork rather than under the text, which is where the library
    /// puts it on a card someone is partway through — white over a dimmed track, the way a
    /// scrubber reads, rather than the accent colour, because it's sitting on a picture and
    /// not on app chrome.
    private var still: some View {
        Group {
            if let image = job.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "film")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: Layout.thumbnailWidth, height: Layout.thumbnailWidth * 9 / 16)
        .clipShape(.rect(cornerRadius: Layout.cornerRadius))
        .overlay(alignment: .bottom) {
            if case .converting(let fraction) = job.status {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.3))
                        Capsule()
                            .fill(.white)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: Layout.progressBarHeight)
                .padding(Layout.progressBarInset)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The state badge sits on the still, so the row reads as a picture and a
            // description rather than a picture, a symbol and a description.
            //
            // Filled and white on a solid disc rather than a bare tinted symbol: it has to
            // stay legible on a bright frame, a black one, and the grey placeholder a file
            // whose still hasn't been read yet shows. A hierarchical style survives none of
            // those three.
            Image(systemName: badge.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(badge.tint, in: .circle)
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                .padding(5)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var status: some View {
        switch job.status {
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.tertiary)
        case .converting:
            Text(job.summary ?? "Converting").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .finished:
            Text(job.summary ?? "Done").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        case .cancelled:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The figure on the right of the name: what the file weighs, how far in it is, or
    /// what it came out at.
    private var trailing: String? {
        switch job.status {
        case .waiting, .cancelled:
            job.sourceBytes.map { $0.formatted(Self.byteFormat) }
        case .converting(let fraction):
            [fraction.formatted(.percent.precision(.fractionLength(0))), timeRemaining]
                .compactMap(\.self).joined(separator: " · ")
        case .finished:
            switch (job.sourceBytes, job.outputBytes) {
            case (let before?, let after?):
                "\(before.formatted(Self.byteFormat)) → \(after.formatted(Self.byteFormat))"
            default:
                job.outputBytes.map { $0.formatted(Self.byteFormat) }
            }
        case .failed:
            nil
        }
    }

    /// Roughly how much longer, extrapolated from how long the finished part took.
    ///
    /// Held back until a fiftieth of the way in: before that the estimate swings wildly,
    /// and a number that jumps from four minutes to forty is worse than no number. It
    /// recomputes whenever progress changes, so there's no timer behind it.
    private var timeRemaining: String? {
        guard case .converting(let fraction) = job.status,
              let startedAt = job.startedAt,
              fraction > 0.02
        else { return nil }

        let elapsed = Date.now.timeIntervalSince(startedAt)
        let remaining = elapsed / fraction - elapsed
        guard remaining >= 1 else { return nil }

        let text = Duration.seconds(remaining).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
        )
        return "\(text) left"
    }

    @ViewBuilder
    private var actions: some View {
        switch job.status {
        case .finished:
            if let output = job.output {
                Button("Show", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Show in Finder")
            }
        case .failed, .cancelled:
            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .help("Try this file again")
        case .waiting, .converting:
            EmptyView()
        }
    }

    private var badge: (symbol: String, tint: Color) {
        switch job.status {
        case .waiting: ("clock", .gray)
        case .converting: ("arrow.triangle.2.circlepath", .accentColor)
        case .finished: ("checkmark", .green)
        case .failed: ("exclamationmark", .red)
        case .cancelled: ("minus", .gray)
        }
    }
}
