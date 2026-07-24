import WebKit

struct Cookie {
    var name: String
    var value: String
}

// Стартовый URL — PWA-фоторедактор «Piks» (telomer1.ru/foto/v2).
let rootUrl = URL(string: "https://telomer1.ru/foto/v2/")!

// Домены, остающиеся внутри WebView. Должны совпадать с WKAppBoundDomains в Info.plist.
let allowedOrigins: [String] = ["telomer1.ru"]

// Сторонний вход не используется — вход по коду на e-mail.
let authOrigins: [String] = []

let platformCookie = Cookie(name: "app-platform", value: "iOS App Store")

// UI options
let displayMode = "standalone"
let adaptiveUIStyle = true
let overrideStatusBar = false
let statusBarTheme = "dark"
let pullToRefresh = true
