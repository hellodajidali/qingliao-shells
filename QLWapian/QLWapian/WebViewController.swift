import UIKit
import WebKit

/// 轻聊 WebView 壳 v1.0.1
/// 改动：改成 autoresizing 布局（防 0 尺寸白屏）、加顶部诊断条（能看到状态码/报错/页面文字长度）、
///       UA 用完整 iPhone UA、网页进程被杀自动重载
class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 每个 App 只改这两行
    let entryURL = "https://www.youwuapp.top/f?gid=162&pw=1"
    let uaSuffix = "YouwuPindan/1.0.1"

    var webView: WKWebView!
    var hud: UILabel!
    var retryBox: UIView?
    var lastError: String = ""

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

        // 顶部诊断条：白色页面时也能看到到底发生了什么
        hud = UILabel()
        hud.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 0)
        hud.autoresizingMask = [.flexibleWidth]
        hud.backgroundColor = UIColor(white: 0, alpha: 0.75)
        hud.textColor = .white
        hud.font = UIFont.systemFont(ofSize: 11)
        hud.numberOfLines = 0
        hud.textAlignment = .left
        hud.text = "正在打开…"
        hud.alpha = 0
        view.addSubview(hud)

        clearCacheThenLoad()
    }

    @objc func pullRefresh() { clearCacheThenLoad() }

    func setHud(_ text: String, show: Bool = true) {
        hud.text = "  " + text
        hud.sizeToFit()
        hud.frame.size.width = view.bounds.width
        hud.frame.size.height = hud.frame.height + 6
        hud.alpha = show ? 1 : 0
    }

    // MARK: - 清缓存（不清 localStorage / cookie，登录状态保留）
    func clearCacheThenLoad() {
        setHud("清缓存…")
        URLCache.shared.removeAllCachedResponses()
        let store = WKWebsiteDataStore.default()
        var types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]
        if #available(iOS 11.3, *) { types.insert(WKWebsiteDataTypeServiceWorkerRegistrations) }
        store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0)) { [weak self] in
            DispatchQueue.main.async { self?.load() }
        }
    }

    func load() {
        let ts = Int(Date().timeIntervalSince1970)
        let sep = entryURL.contains("?") ? "&" : "?"
        guard let url = URL(string: entryURL + sep + "fresh=" + String(ts)) else { return }
        setHud("请求 " + url.absoluteString)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 40)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.load(req)
    }

    // MARK: - 导航回调
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            if http.statusCode >= 400 {
                lastError = "HTTP " + String(http.statusCode)
                setHud(lastError + " " + (navigationResponse.response.url?.absoluteString ?? ""))
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = ""
        setHud("连接中…")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        setHud("收到页面，等渲染…")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideRetry()
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        // 把页面真实状态打出来：标题 / 可见文字长度 / 地址
        webView.evaluateJavaScript("JSON.stringify({t:document.title||'', n:(document.body?document.body.innerText.length:0), u:location.href, errs:(window.__errs||[]).slice(0,2)})") { [weak self] res, err in
            guard let self = self else { return }
            var msg = "已加载"
            if let s = res as? String { msg = "已加载 " + s }
            if let e = err { msg = "已加载但取不到状态: " + e.localizedDescription }
            if !self.lastError.isEmpty { msg += " | " + self.lastError }
            self.setHud(msg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.hud.alpha = 0 }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        setHud("网页进程被系统回收，正在重载…")
        load()
    }

    func fail(_ error: Error) {
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        let e = error as NSError
        let msg = "错误 \(e.code)：" + e.localizedDescription + " | " + entryURL
        setHud(msg)
        showRetry(msg)
    }

    // MARK: - 失败重试
    func showRetry(_ msg: String) {
        if retryBox != nil { return }
        let box = UIView(frame: view.bounds)
        box.backgroundColor = .white
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
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -28),
            btn.heightAnchor.constraint(equalToConstant: 44),
            btn2.heightAnchor.constraint(equalToConstant: 36)
        ])
        view.addSubview(box)
        retryBox = box
    }

    @objc func retryTapped() { hideRetry(); clearCacheThenLoad() }

    @objc func openInSafari() {
        if let u = URL(string: entryURL) { UIApplication.shared.open(u, options: [:], completionHandler: nil) }
    }

    func hideRetry() {
        retryBox?.removeFromSuperview()
        retryBox = nil
    }

    // 外链交系统
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
