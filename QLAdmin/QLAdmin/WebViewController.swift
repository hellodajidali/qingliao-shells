import UIKit
import WebKit

/// 轻聊 WebView 壳 v1.0.2
/// 关键改动：屏幕上留一串「事件日志」，并且用 URLSession 单独探一次网络，
/// 用来分清「整个 App 没网」还是「只有 WKWebView 卡住」。
class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 每个 App 只改这两行
    let entryURL = "https://www.youwuapp.top/houtai"
    let uaSuffix = "QingliaoAdmin/1.0.2"

    var webView: WKWebView!
    var logView: UITextView!
    var retryBox: UIView?
    var lines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        if #available(iOS 14.0, *) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Mobile/15E148 Safari/604.1 " + uaSuffix
        view.addSubview(webView)

        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = rc

        // 底部日志条（可以上下滚，用来截图给我看）
        logView = UITextView(frame: CGRect(x: 0, y: 200, width: view.bounds.width, height: 220))
        logView.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        logView.backgroundColor = UIColor(white: 0, alpha: 0.82)
        logView.textColor = .white
        logView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.isEditable = false
        logView.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        view.addSubview(logView)

        log("启动 v1.0.2")
        probeNetwork()
        clearCacheThenLoad()
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lines.append(f.string(from: Date()) + "  " + s)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        logView.text = lines.joined(separator: "\n")
        let end = NSRange(location: logView.text.count, length: 0)
        logView.scrollRangeToVisible(end)
    }

    /// 用系统的 URLSession 直连一次，看看 App 到底有没有网
    func probeNetwork() {
        let ts = Int(Date().timeIntervalSince1970)
        let sep = entryURL.contains("?") ? "&" : "?"
        guard let url = URL(string: entryURL + sep + "probe=" + String(ts)) else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.httpMethod = "GET"
        let conf = URLSessionConfiguration.ephemeral
        conf.waitsForConnectivity = false
        conf.timeoutIntervalForRequest = 12
        log("URLSession 探测 " + url.absoluteString)
        URLSession(configuration: conf).dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                if let e = err as NSError? {
                    self?.log("探测失败 [\(e.code)] \(e.localizedDescription)")
                } else if let h = resp as? HTTPURLResponse {
                    self?.log("探测成功 HTTP \(h.statusCode)，收到 \(data?.count ?? 0) 字节")
                } else {
                    self?.log("探测返回空")
                }
            }
        }.resume()
    }

    @objc func pullRefresh() { probeNetwork(); clearCacheThenLoad() }

    func clearCacheThenLoad() {
        log("清缓存…")
        URLCache.shared.removeAllCachedResponses()
        let store = WKWebsiteDataStore.default()
        var types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]
        if #available(iOS 11.3, *) { types.insert(WKWebsiteDataTypeServiceWorkerRegistrations) }
        store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
            DispatchQueue.main.async {
                self?.log("清缓存完成，开始加载")
                self?.load()
            }
        }
    }

    func load() {
        let ts = Int(Date().timeIntervalSince1970)
        let sep = entryURL.contains("?") ? "&" : "?"
        guard let url = URL(string: entryURL + sep + "fresh=" + String(ts)) else { return }
        log("webview.load " + url.absoluteString)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 40)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.load(req)
    }

    // MARK: - 导航
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("didStart 开始导航")
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        log("302 跳转")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        log("didCommit 收到内容")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            log("响应 HTTP \(http.statusCode) " + (navigationResponse.response.url?.host ?? ""))
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideRetry()
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        log("didFinish")
        webView.evaluateJavaScript("JSON.stringify({t:document.title||'',n:(document.body?document.body.innerText.length:0),u:location.href})") { [weak self] res, err in
            if let s = res as? String { self?.log("页面状态 " + s) }
            if let e = err { self?.log("取页面状态失败: " + e.localizedDescription) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error, tag: "didFail")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error, tag: "didFailProvisional")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("WebContent 进程被回收，重载")
        load()
    }

    func fail(_ error: Error, tag: String) {
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        let e = error as NSError
        log("\(tag) 错误 [\(e.code)] \(e.localizedDescription)")
        showRetry("错误 \(e.code)：\(e.localizedDescription)")
    }

    // MARK: - 失败页
    func showRetry(_ msg: String) {
        if retryBox != nil { return }
        let box = UIView(frame: view.bounds)
        box.backgroundColor = UIColor.white.withAlphaComponent(0.96)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let title = UILabel()
        title.text = "没打开页面"
        title.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        title.textAlignment = .center
        let detail = UILabel()
        detail.text = msg
        detail.numberOfLines = 0
        detail.font = UIFont.systemFont(ofSize: 12.5)
        detail.textColor = .darkGray
        detail.textAlignment = .center

        let btn = UIButton(type: .system)
        btn.setTitle("重新加载", for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        btn.backgroundColor = UIColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1)
        btn.setTitleColor(.white, for: .normal)
        btn.layer.cornerRadius = 10
        btn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        let btn2 = UIButton(type: .system)
        btn2.setTitle("用 Safari 打开", for: .normal)
        btn2.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        btn2.setTitleColor(.darkGray, for: .normal)
        btn2.addTarget(self, action: #selector(openInSafari), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, detail, btn, btn2])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -80),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -28),
            btn.heightAnchor.constraint(equalToConstant: 44),
            btn2.heightAnchor.constraint(equalToConstant: 36)
        ])
        view.addSubview(box)
        retryBox = box
    }

    @objc func retryTapped() { hideRetry(); probeNetwork(); clearCacheThenLoad() }
    @objc func openInSafari() {
        if let u = URL(string: entryURL) { UIApplication.shared.open(u, options: [:], completionHandler: nil) }
    }
    func hideRetry() { retryBox?.removeFromSuperview(); retryBox = nil }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
