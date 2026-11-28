//
//  Figtree.swift
//  Shared by the app and the widget.
//
//  The app's typeface: Figtree (SIL Open Font License 1.1, Resources/Fonts/OFL.txt), bundled
//  as static weights and listed under UIAppFonts. Each weight is picked by its PostScript name,
//  and sizes follow Dynamic Type through `relativeTo:`.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum Figtree {
    static func name(_ w: Font.Weight) -> String {
        if w == .medium { return "Figtree-Medium" }
        if w == .semibold { return "Figtree-SemiBold" }
        if w == .bold { return "Figtree-Bold" }
        if w == .heavy || w == .black { return "Figtree-ExtraBold" }
        return "Figtree-Regular"
    }

    /// Apple's default point sizes for each text style (Large / default Dynamic Type).
    static func size(_ s: Font.TextStyle) -> CGFloat {
        switch s {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 15
        case .body: return 17
        case .callout: return 16
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }

    #if canImport(UIKit)
    /// Navigation and tab bars (UIKit) in Figtree too.
    @MainActor static func styleBars() {
        let large = UIFont(name: name(.bold), size: 34).map { UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: $0) }
        let title = UIFont(name: name(.semibold), size: 17).map { UIFontMetrics(forTextStyle: .headline).scaledFont(for: $0) }
        let nav = UINavigationBar.appearance()
        if let large { nav.largeTitleTextAttributes = [.font: large] }
        if let title { nav.titleTextAttributes = [.font: title] }
        if let tab = UIFont(name: name(.medium), size: 10) {
            UITabBarItem.appearance().setTitleTextAttributes([.font: tab], for: .normal)
        }
    }
    #endif
}

extension Font {
    /// Figtree in a text style (headline is semibold, like the system's).
    static func fig(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        let w = weight ?? (style == .headline ? .semibold : .regular)
        return .custom(Figtree.name(w), size: Figtree.size(style), relativeTo: style)
    }

    /// Figtree at a fixed size (big numbers that are already sized to their space).
    static func fig(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(Figtree.name(weight), fixedSize: size)
    }
}
