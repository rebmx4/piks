import UIKit
import WebKit
import SafariServices

class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private var webView: WKWebView!
    private var progressView: UIProgressView!
    private var offlineView: UIView!
    private let refreshControl = UIRefreshControl()

    private let bgColor = UIColor(red: 0.0549, green: 0.0588, blue: 0.0745, alpha: 1) // #0E0F13
    private let accent = UIColor(red: 1.0, green: 0.176, blue: 0.529, alpha: 1)       // #FF2D87

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = bgColor
        setupWebView()
        setupProgress()
        setupOffline()
        clearWebCachesThenLoad()
    }

    // The iOS URLCache and WKWebsiteDataStore were holding stale index.html
    // (heuristic freshness without Cache-Control) which pinned the app to an
    // old asset version even after reinstall. Clear caches (but NOT cookies /
    // localStorage — user session must survive) then load with a strict
    // no-cache policy so every launch pulls a fresh shell from the network.
    private func clearWebCachesThenLoad() {
        URLCache.shared.removeAllCachedResponses()
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeServiceWorkerRegistrations,
            WKWebsiteDataTypeFetchCache,
        ]
        WKWebsiteDataStore.default().removeData(
            ofTypes: types,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            self?.loadRoot()
        }
    }

    // MARK: - WebView

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(
            source: "window.__IS_IOS_APP = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        ucc.add(self, name: "nativeShare")
        config.userContentController = ucc
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            config.limitsNavigationsToAppBoundDomains = true
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true
        webView.isOpaque = false
        webView.backgroundColor = bgColor
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1 PiksiOS"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        if pullToRefresh {
            refreshControl.tintColor = .lightGray
            refreshControl.addTarget(self, action: #selector(reloadWeb), for: .valueChanged)
            webView.scrollView.refreshControl = refreshControl
        }
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
    }

    private func setupProgress() {
        progressView = UIProgressView(progressViewStyle: .bar)
        progressView.progressTintColor = accent
        progressView.trackTintColor = .clear
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    private func setupOffline() {
        offlineView = UIView()
        offlineView.backgroundColor = bgColor
        offlineView.isHidden = true
        offlineView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(offlineView)
        NSLayoutConstraint.activate([
            offlineView.topAnchor.constraint(equalTo: view.topAnchor),
            offlineView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            offlineView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offlineView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        let label = UILabel()
        label.text = "Нет подключения к интернету"
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        let button = UIButton(type: .system)
        button.setTitle("Повторить", for: .normal)
        button.setTitleColor(accent, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.addTarget(self, action: #selector(reloadWeb), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        offlineView.addSubview(label)
        offlineView.addSubview(button)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: offlineView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: offlineView.centerYAnchor, constant: -16),
            button.centerXAnchor.constraint(equalTo: offlineView.centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
        ])
    }

    private func loadRoot() {
        offlineView.isHidden = true
        var req = URLRequest(url: rootUrl)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(req)
    }

    @objc private func reloadWeb() {
        offlineView.isHidden = true
        if webView.url != nil {
            webView.reloadFromOrigin()
        } else { loadRoot() }
    }

    // MARK: - KVO progress

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.estimatedProgress) {
            let p = Float(webView.estimatedProgress)
            progressView.setProgress(p, animated: true)
            progressView.isHidden = p >= 1.0
            if p >= 1.0 { progressView.setProgress(0, animated: false) }
        }
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshControl.endRefreshing()
        offlineView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showOfflineIfNeeded(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showOfflineIfNeeded(error)
    }

    private func showOfflineIfNeeded(_ error: Error) {
        refreshControl.endRefreshing()
        let code = (error as NSError).code
        if code == NSURLErrorNotConnectedToInternet || code == NSURLErrorTimedOut || code == NSURLErrorCannotConnectToHost {
            offlineView.isHidden = false
        }
    }

    // Keep telomer1.ru inside the app, open everything else in Safari.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "tel" || scheme == "mailto" {
            UIApplication.shared.open(url); decisionHandler(.cancel); return
        }
        if let host = url.host, allowedOrigins.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            decisionHandler(.allow); return
        }
        if scheme == "http" || scheme == "https" {
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    // Open target=_blank in the same web view
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // Grant getUserMedia (camera) inside WKWebView if the web layer requests it.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // MARK: - WKScriptMessageHandler (native share sheet — web layer bridges here)
    // The web "Поделиться" button posts here; presenting a real
    // UIActivityViewController gives the wrapper genuine native functionality.
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "nativeShare" else { return }
        var items: [Any] = []
        if let body = message.body as? [String: Any] {
            if let text = body["text"] as? String, !text.isEmpty { items.append(text) }
            if let urlStr = body["url"] as? String, let url = URL(string: urlStr) { items.append(url) }
        } else if let text = message.body as? String, !text.isEmpty {
            items.append(text)
        }
        guard !items.isEmpty else { return }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let pop = av.popoverPresentationController {   // iPad: anchor to screen center
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        present(av, animated: true)
    }
}
