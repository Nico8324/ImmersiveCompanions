/*
Abstract:
The static HDR metadata a file carries, in the form x265 wants it back.
*/

import Foundation

/// The mastering display and content light level a file was graded against.
///
/// Read separately from the rest of the probe because ffprobe does not report these on the
/// stream — asked for `-show_streams` on a Dolby Vision remux, the only side data that comes
/// back is the DOVI configuration record. Both live on the frames, so this reads one frame
/// and stops.
///
/// Carrying them matters: they tell a display how the grade was made, and Apple's authoring
/// specification asks for both to be present (1.35). x265 drops them unless told, so a
/// re-encode that never reads them produces a file that tone maps differently from its
/// source on every display that reads the metadata.
struct HDRMetadata: Sendable {
    /// SMPTE ST 2086 mastering display, formatted as x265's `master-display`.
    let masteringDisplay: String?
    /// `MaxCLL,MaxFALL`, formatted as x265's `max-cll`.
    let contentLightLevel: String?

    var isEmpty: Bool { masteringDisplay == nil && contentLightLevel == nil }

    /// The arguments that read one frame's side data and nothing else.
    static func probeArguments(for source: URL, videoStream: Int) -> [String] {
        [
            "-v", "error",
            "-select_streams", "\(videoStream)",
            // One frame is enough: static metadata is static.
            "-read_intervals", "%+#1",
            "-show_frames",
            "-of", "json",
            source.path(percentEncoded: false)
        ]
    }

    /// Pulls both out of ffprobe's frame JSON.
    ///
    /// ffprobe reports the coordinates as rationals already in the units the SEI uses —
    /// `34000/50000` for a primary, `10000000/10000` for a luminance — so the numerator is
    /// the number to pass on, and dividing would only introduce rounding.
    init(framesJSON data: Data) {
        var display: String?
        var light: String?

        struct Frames: Decodable {
            struct Frame: Decodable {
                struct SideData: Decodable {
                    let sideDataType: String?
                    let redX: String?, redY: String?
                    let greenX: String?, greenY: String?
                    let blueX: String?, blueY: String?
                    let whitePointX: String?, whitePointY: String?
                    let minLuminance: String?, maxLuminance: String?
                    let maxContent: Int?, maxAverage: Int?
                }
                let sideDataList: [SideData]?
            }
            let frames: [Frame]
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let decoded = try? decoder.decode(Frames.self, from: data) else {
            self.masteringDisplay = nil
            self.contentLightLevel = nil
            return
        }

        /// The leading integer of a rational such as `34000/50000`.
        func numerator(_ rational: String?) -> String? {
            guard let value = rational?.split(separator: "/").first else { return nil }
            return String(value)
        }

        for frame in decoded.frames {
            for side in frame.sideDataList ?? [] {
                let kind = side.sideDataType ?? ""
                if kind.contains("Mastering"),
                   let gx = numerator(side.greenX), let gy = numerator(side.greenY),
                   let bx = numerator(side.blueX), let by = numerator(side.blueY),
                   let rx = numerator(side.redX), let ry = numerator(side.redY),
                   let wx = numerator(side.whitePointX), let wy = numerator(side.whitePointY),
                   let maxL = numerator(side.maxLuminance), let minL = numerator(side.minLuminance) {
                    display = "G(\(gx),\(gy))B(\(bx),\(by))R(\(rx),\(ry))WP(\(wx),\(wy))L(\(maxL),\(minL))"
                }
                if kind.lowercased().contains("light level"),
                   let content = side.maxContent, let average = side.maxAverage {
                    light = "\(content),\(average)"
                }
            }
        }

        self.masteringDisplay = display
        self.contentLightLevel = light
    }
}
