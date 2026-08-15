/*
Abstract:
Subtitle files placed beside the source, folded into the output as native text tracks.
*/

import Foundation

// MARK: - Sidecar subtitles

/// A subtitle file found beside the source, and what its name says about it.
///
/// Blu-ray rips carry their major-language subtitles as PGS images, which have nowhere to
/// go in MP4 and get dropped — `Plan.trackArguments` — so a converted film can end up with
/// ten minor-language text tracks and no English at all. The remedy is letting the user
/// supply the text themselves: a plain-text subtitle file named after the source, sitting
/// beside it, is muxed into the output as a native `mov_text` track and the sidecar can be
/// deleted afterwards. This is the user-supplied equivalent of the text files studios
/// themselves hand Apple's own pipeline as iTT.
struct SidecarSubtitle {
    let url: URL
    /// The ISO 639 tag read off the file name, passed straight through rather than mapped
    /// through a table of our own — ffmpeg and MP4 already accept whatever's given here.
    /// `nil` for a bare `Movie.srt`, which has nothing to write.
    let language: String?
    let isForced: Bool
    /// Hearing-impaired / SDH, from a `sdh` component in the name.
    let isHearingImpaired: Bool

    /// Extensions ffmpeg turns into `mov_text` on the way into MP4.
    static let acceptedExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    // MARK: Discovery

    /// Finds subtitle files beside `source` whose name starts with its stem.
    ///
    /// `Movie.srt` (no language), `Movie.eng.srt`, `Movie.en.forced.srt` and
    /// `Movie.fre.sdh.srt` are all accepted. `Movie2.srt` is not: matching is exact on the
    /// stem plus a dot, so a differently numbered file — or a sequel sitting in the same
    /// folder — is never mistaken for this film's subtitles.
    ///
    /// The dotted components between the stem and the extension are read in any order: a
    /// 2- or 3-letter alphabetic component is a language tag, `forced` sets the forced
    /// disposition, `sdh` sets hearing-impaired. An unrecognised component — a release
    /// group tag, a track number — is ignored rather than disqualifying the file; a naming
    /// scheme this doesn't understand shouldn't cost the subtitles entirely.
    static func discover(for source: URL) -> [SidecarSubtitle] {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        guard let siblings = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return siblings
            .compactMap { url -> SidecarSubtitle? in
                let ext = url.pathExtension.lowercased()
                guard acceptedExtensions.contains(ext) else { return nil }

                let base = url.deletingPathExtension().lastPathComponent
                let remainder: Substring
                if base == stem {
                    remainder = ""
                } else if base.hasPrefix(stem + ".") {
                    remainder = base.dropFirst(stem.count + 1)
                } else {
                    return nil
                }

                var language: String?
                var isForced = false
                var isHearingImpaired = false
                for component in remainder.split(separator: ".") {
                    let token = String(component)
                    switch token.lowercased() {
                    case "forced": isForced = true
                    case "sdh": isHearingImpaired = true
                    default:
                        if (2...3).contains(token.count), token.allSatisfy(\.isLetter) {
                            language = token
                        }
                    }
                }

                return SidecarSubtitle(
                    url: url, language: language, isForced: isForced, isHearingImpaired: isHearingImpaired
                )
            }
            // A stable order, so which sidecar becomes ffmpeg input 1 and which becomes
            // input 2 doesn't depend on whatever order `FileManager` happened to hand them
            // back in.
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    // MARK: Sanity check

    /// How far past the film's own duration a sidecar's last cue is allowed to run before
    /// it's treated as belonging to a different cut rather than trusted — a subtitle file
    /// found beside the source is only as reliable as the assumption that it's for this cut
    /// of the film, and a cue running well past the end is evidence it isn't.
    private static let maximumOvershoot: TimeInterval = 10 * 60

    /// Whether this file is worth muxing in, and why not when it isn't.
    ///
    /// An unreadable or empty file is skipped outright. One whose last cue runs
    /// implausibly past the probed duration is skipped as well, rather than muxed in as
    /// though it lined up — better no subtitles than subtitles that quietly lie about
    /// where the film ends. No charset conversion is attempted: ffmpeg expects UTF-8, and a
    /// file that isn't fails to read here the same way it would fail to mux.
    ///
    /// A file this can't find a last cue in at all — anything other than SRT/VTT's `-->`
    /// cue lines or ASS/SSA's `Dialogue:` lines — is let through untested rather than
    /// rejected for a format the check doesn't understand.
    func skipReason(durationInSeconds duration: Double) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "\(url.lastPathComponent) couldn't be read as UTF-8, so it was skipped"
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(url.lastPathComponent) was empty, so it was skipped"
        }
        guard let lastCue = SidecarSubtitle.lastCueEnd(in: text) else { return nil }
        guard duration <= 0 || lastCue <= duration + SidecarSubtitle.maximumOvershoot else {
            let minutesPast = Int(((lastCue - duration) / 60).rounded())
            return "\(url.lastPathComponent) runs about \(minutesPast) minutes past the end of the "
                + "film — probably a different cut — so it was skipped"
        }
        return nil
    }

    /// The end time of the last cue in the file, read cheaply rather than by parsing the
    /// whole thing into cues.
    ///
    /// SRT and VTT share the same `HH:MM:SS,mmm --> HH:MM:SS,mmm` shape (VTT uses `.`
    /// instead of `,` and may drop the hours), so the last line containing `-->` is read
    /// for both. ASS and SSA instead write `Dialogue: Layer,Start,End,Style,...` — the end
    /// time is the third comma-separated field, read with a bounded split so a comma inside
    /// the dialogue text itself, which comes later in the line, is never mistaken for one.
    private static func lastCueEnd(in text: String) -> TimeInterval? {
        let lines = text.split(whereSeparator: \.isNewline)

        if let arrowLine = lines.last(where: { $0.contains("-->") }) {
            let end = arrowLine.components(separatedBy: "-->").last ?? ""
            let token = end.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""
            if let end = parseTimestamp(token) { return end }
        }

        if let dialogueLine = lines.last(where: { $0.hasPrefix("Dialogue:") }) {
            let fields = dialogueLine.dropFirst("Dialogue:".count)
                .split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            if fields.count > 2, let end = parseTimestamp(String(fields[2])) { return end }
        }

        return nil
    }

    /// A timestamp in any of `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm` or `H:MM:SS.cc` —
    /// the shapes SRT, VTT and ASS/SSA respectively write. Read from the right: the last
    /// colon-separated component is always seconds, the one before it minutes if present,
    /// and the one before that hours if present, which handles all four without needing to
    /// know which format supplied the string.
    private static func parseTimestamp(_ raw: String) -> TimeInterval? {
        let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard let secondsPart = parts.last, let seconds = Double(secondsPart) else { return nil }
        let minutes = parts.count >= 2 ? Double(parts[parts.count - 2]) ?? 0 : 0
        let hours = parts.count >= 3 ? Double(parts[parts.count - 3]) ?? 0 : 0
        return hours * 3600 + minutes * 60 + seconds
    }
}
