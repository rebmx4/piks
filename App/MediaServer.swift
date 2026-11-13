import Foundation
import WebKit

extension MediaBridge: WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { mediaServer.webView(webView, start: task) }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { mediaServer.webView(webView, stop: task) }

    func resolveSchemeResource(_ url: URL, done: @escaping (MediaSchemeResource?) -> Void) -> (() -> Void) {
        let id = (url.lastPathComponent as NSString).deletingPathExtension
        switch url.host {
        case "thumb":
            let requested = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "s" })?.value ?? "") ?? 300
            galleryThumb(id, size: min(1024, max(32, requested))) { data in done(data.map { .data($0, "image/jpeg") }) }
            return {}
        case "preview":
            done(PreviewCopies.ready(id).map { .file($0, "video/mp4") }); return {}
        case "audio":
            done(audioFiles[id].map { .file($0, "audio/mp4") }); return {}
        default:
            // Host allowlist and the document grant were checked before resolution.
            return resolveFile(id) { file in done(file.map { .file($0, MediaBridge.mimeType(for: $0)) }) }
        }
    }
}
