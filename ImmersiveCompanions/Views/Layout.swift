/*
Abstract:
Measurements borrowed from Immersive Cinema, so a file on its way in looks the way it will look once it arrives.
*/

import SwiftUI

// MARK: - How the library looks

/// Measurements taken from Immersive Cinema, so a file on its way into the library is
/// presented the way the library will present it.
///
/// Transcribed rather than shared, for the same reason `PlaybackTarget` is: this tool has to
/// keep working with the library nowhere in sight. If `Constants` there changes, change this
/// with it.
enum Layout {
    /// `Constants.cornerRadius`, which is what every still and card in the library is
    /// clipped to.
    static let cornerRadius: Double = 10

    /// The width of the still beside a row.
    ///
    /// The library's `episodeThumbnailWidth` is 160 on a Mac, but that sits on a detail page
    /// beside a title, a number and three lines of synopsis. A row here is three short lines
    /// about a file, and a still that tall leaves most of the row empty.
    static let thumbnailWidth: Double = 120

    /// `Constants.progressBarHeight`.
    static let progressBarHeight: Double = 4

    /// `Constants.genreSpacing`, which is the inset the library gives that bar when it draws
    /// it across a card.
    static let progressBarInset: Double = 8
}
