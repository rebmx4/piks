import UIKit
import WebKit

enum WrapperInputMode: String {
    case standard
    case minimal

    static let preferenceKey = "apiks.wrapper.input-mode"

    var title: String {
        self == .minimal ? NSLocalizedString("Упрощённая", comment: "Minimal wrapper input mode")
            : NSLocalizedString("Обычная", comment: "Standard wrapper input mode")
    }

    static func load(defaults: UserDefaults = .standard, comparisonAvailable: Bool) -> WrapperInputMode {
        // App Store always uses the mode accepted on the owner's iPhone.
        // TestFlight may still restore the saved comparison preference.
        guard comparisonAvailable else { return .minimal }
        return defaults.string(forKey: preferenceKey).flatMap(WrapperInputMode.init(rawValue:)) ?? .minimal
    }
}

// Snapshot the original host before applying either policy. Switching modes
// changes only the outer WebView, without configuring WebKit's child scrollers.
@MainActor
struct WrapperInputBaseline {
    private let navigation: Bool
    private let scrolling: Bool
    private let delay: Bool
    private let cancel: Bool
    private let bounce: Bool
    private let horizontalBounce: Bool
    private let verticalBounce: Bool

    init(_ web: WKWebView) {
        let scroll = web.scrollView
        navigation = web.allowsBackForwardNavigationGestures
        scrolling = scroll.isScrollEnabled
        delay = scroll.delaysContentTouches
        cancel = scroll.canCancelContentTouches
        bounce = scroll.bounces
        horizontalBounce = scroll.alwaysBounceHorizontal
        verticalBounce = scroll.alwaysBounceVertical
    }

    func apply(to web: WKWebView, mode: WrapperInputMode) {
        let original = mode == .standard
        let scroll = web.scrollView
        web.allowsBackForwardNavigationGestures = original && navigation
        scroll.isScrollEnabled = original && scrolling
        scroll.delaysContentTouches = original && delay
        scroll.canCancelContentTouches = original && cancel
        scroll.bounces = original && bounce
        scroll.alwaysBounceHorizontal = original && horizontalBounce
        scroll.alwaysBounceVertical = original && verticalBounce
    }
}
