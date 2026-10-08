import Foundation

// Техническая цепочка ошибки. Имена файлов и адреса пользователя в журнал
// не отправляются: для причины нужны этап, домен и код каждого NSError.
enum ExportDiagnostics {
    static func details(_ error: Error, phase: String) -> [String: Any] {
        var chain: [[String: Any]] = [], current: NSError? = error as NSError
        while let cause = current, chain.count < 5 {
            chain.append(["domain": cause.domain, "code": cause.code])
            current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return ["phase": phase, "errors": chain]
    }
}
