import WebKit

struct Cookie {
    var name: String
    var value: String
}

// Стартовый URL — видеоредактор Ryndi (rynpro.ru/ryn).
// Прежний адрес фоторедактора: https://telomer1.ru/foto/v2/ — точка возврата
// лежит в метке git foto-v2-before-ryndi и в D:\Archive\piks-foto-v2-2026-09-23.
//
// «Тестовая версия» (переключатель в профиле редактора) открывает /ryn-next/ —
// там новое до одобрения владельца. Выбор хранится в настройках приложения.
let stableUrl = URL(string: "https://rynpro.ru/ryn/")!
let nextUrl = URL(string: "https://rynpro.ru/ryn-next/")!
let siteKey = "ryndi.site"

// Сборка из TestFlight (ею проверяет владелец) без выбора открывает тестовую
// версию, сборка из App Store — рабочую. Выбор в профиле или в меню трёх
// пальцев важнее.
var isTestFlight: Bool {
    return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
}

// Выбирать версию сайта можно только в TestFlight (ею проверяет владелец) и
// в отладочной сборке. В сборке из App Store скрытый переключатель — это
// «скрытая функция» (правило 2.3.1 проверки Apple): там всегда рабочая
// версия /ryn/, меню трёх пальцев и «Тестовая версия» в профиле не видны.
var canChooseSite: Bool {
#if DEBUG
    return true
#else
    return isTestFlight
#endif
}

var rootUrl: URL {
    guard canChooseSite else { return stableUrl }
    switch UserDefaults.standard.string(forKey: siteKey) {
    case "next": return nextUrl
    case "stable": return stableUrl
    default: return isTestFlight ? nextUrl : stableUrl
    }
}

// Домены, остающиеся внутри WebView. Должны совпадать с WKAppBoundDomains в Info.plist.
let allowedOrigins: [String] = ["rynpro.ru", "telomer1.ru"]

// Сторонний вход не используется — вход по коду на e-mail.
let authOrigins: [String] = []

let platformCookie = Cookie(name: "app-platform", value: "iOS App Store")

// UI options
let displayMode = "standalone"
let adaptiveUIStyle = true
let overrideStatusBar = false
let statusBarTheme = "dark"
let pullToRefresh = true
