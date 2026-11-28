//
//  AppFont.swift
//  Shared by the app and the widget.
//
//  The app's typeface: Apple's system font (SF Pro), which is drawn for the iPhone screen, has
//  tabular digits and follows Dynamic Type. Figtree was tried (build 195) and dropped. All text
//  goes through `.fig(...)`, so a future change of typeface is made here only.
//

import SwiftUI

extension Font {
    /// The app font in a text style (headline is semibold, like the system's).
    static func fig(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        .system(style, weight: weight ?? (style == .headline ? .semibold : .regular))
    }

    /// The app font at a fixed size (big numbers that are already sized to their space).
    static func fig(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
