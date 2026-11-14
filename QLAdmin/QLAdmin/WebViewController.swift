import UIKit
import WebKit
import Photos

/// 轻聊 WebView 壳 v1.3.0（左右滑返回 + 长按不受系统菜单干扰）
/// - 默认地址改成 m.youwuapp.top（www 那条在部分手机上解析有问题）
/// - 不再常驻黑色日志框；只有「打开失败」时才会把日志显示在错误页里
/// - 右上角一个很淡的齿轮：换域名/换地址用
class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 每个 App 只改这三行
    let defaultURL = "https://youwutu.top/houtai"
    let appTitle = "轻聊"
    let uaSuffix = "QingliaoAdmin/1.3.0"
    var entryURL: String { return UserDefaults.standard.string(forKey: "ql_entry") ?? defaultURL }

    var webView: WKWebView!
    var gear: UIButton!
    var webBottom: NSLayoutConstraint!
    var retryBox: UIView?
    var lines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        /* v1.3.0 一次性迁移：以前手动把入口设成「尤雾排单」（/f?…）的，升级后回到会话主页面 */
        if !UserDefaults.standard.bool(forKey: "ql_entry_v3") {
            UserDefaults.standard.set(true, forKey: "ql_entry_v3")
            if let e = UserDefaults.standard.string(forKey: "ql_entry"), e.contains("/f?") || e.hasSuffix("/f") {
                UserDefaults.standard.removeObject(forKey: "ql_entry")
            }
        }
        view.backgroundColor = .white

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        /* 网页调用 window.webkit.messageHandlers.saveImage 时，交给原生写相册 */
        let ucc = cfg.userContentController
        ucc.add(self, name: "saveImage")
        if #available(iOS 14.0, *) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false     // 长按别弹系统预览，二级菜单自己做
        /* 左右两个方向的边缘滑动都当「返回」：
           页面是单页应用，退历史常常没反应，所以先问网页自己（window.__qlBack） */
        for edge in [UIRectEdge.left, UIRectEdge.right] {
            let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(edgePan(_:)))
            pan.edges = edge
            webView.addGestureRecognizer(pan)
        }

        /* 网页不再铺到状态栏下面（以前标题被时间/电量压住），也不再自己算安全区 */
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Mobile/15E148 Safari/604.1 " + uaSuffix
        view.addSubview(webView)
        webBottom = webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webBottom,
        ])
        /* 键盘弹出/收起：把网页底边抬到键盘上面，登录按钮和输入框才点得到 */
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(kbWillHide),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)

        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = rc

        // 很淡的小齿轮：换地址用，不挡内容
        gear = UIButton(type: .system)
        gear.setTitle("⚙", for: .normal)
        gear.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        gear.setTitleColor(.gray, for: .normal)
        gear.alpha = 0.28
        gear.translatesAutoresizingMaskIntoConstraints = false
        gear.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
        view.addSubview(gear)
        NSLayoutConstraint.activate([
            gear.widthAnchor.constraint(equalToConstant: 30),
            gear.heightAnchor.constraint(equalToConstant: 30),
            gear.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -2),
            gear.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
        ])

        log("启动 v1.3.0 · " + entryURL)
        clearCacheThenLoad()
    }

    func log(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        lines.append(f.string(from: Date()) + "  " + s)
        if lines.count > 30 { lines.removeFirst(lines.count - 30) }
    }

    @objc func pullRefresh() { clearCacheThenLoad() }

    /* 键盘：网页底边跟着键盘走，登录按钮 / 输入框不会被盖住 */
    @objc func kbWillChange(_ n: Notification) {
        guard let f = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let kb = max(0, view.bounds.height - f.origin.y)          // 键盘从底往上占多高
        let inset = view.safeAreaInsets.bottom                     // 网页底边本来就在安全区上
        webBottom.constant = -max(0, kb - inset)
        UIView.animate(withDuration: 0.18) { self.view.layoutIfNeeded() }
    }

    @objc func kbWillHide() {
        webBottom.constant = 0
        UIView.animate(withDuration: 0.18) { self.view.layoutIfNeeded() }
    }

    /// 齿轮菜单：刷新页面（网页改了不用重装）/ 改地址 / 恢复默认
    @objc func gearTapped() {
        let sheet = UIAlertController(title: appTitle + " " + (uaSuffix.components(separatedBy: "/").last ?? ""),
                                      message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "刷新页面（保留登录）", style: .default) { _ in
            self.log("手动刷新")
            self.clearCacheThenLoad()
        })
        sheet.addAction(UIAlertAction(title: "改地址…", style: .default) { _ in self.editEntry() })
        sheet.addAction(UIAlertAction(title: "恢复默认地址", style: .destructive) { _ in
            UserDefaults.standard.removeObject(forKey: "ql_entry")
            self.log("恢复默认 " + self.defaultURL)
            self.clearCacheThenLoad()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = gear
            pop.sourceRect = gear.bounds
        }
        present(sheet, animated: true)
    }

    /// 换域名 / 换地址：改完存本机，不用重装 App
    @objc func editEntry() {
        let alert = UIAlertController(title: "打开地址", message: "换域名了就在这改，存到本机，不用重装", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = self.entryURL
            tf.placeholder = self.defaultURL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "恢复默认", style: .destructive) { _ in
            UserDefaults.standard.removeObject(forKey: "ql_entry")
            self.log("恢复默认 " + self.defaultURL)
            self.clearCacheThenLoad()
        })
        alert.addAction(UIAlertAction(title: "保存并打开", style: .default) { _ in
            var v = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty {
                UserDefaults.standard.removeObject(forKey: "ql_entry")
            } else {
                if !v.lowercased().hasPrefix("http") { v = "https://" + v }
                UserDefaults.standard.set(v, forKey: "ql_entry")
            }
            self.log("地址改为 " + self.entryURL)
            self.clearCacheThenLoad()
        })
        present(alert, animated: true)
    }

    // MARK: - 清缓存（不动 localStorage / cookie，登录状态保留）
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
            DispatchQueue.main.async { self?.load() }
        }
    }

    func load() {
        hideRetry()
        let ts = Int(Date().timeIntervalSince1970)
        let sep = entryURL.contains("?") ? "&" : "?"
        guard let url = URL(string: entryURL + sep + "fresh=" + String(ts)) else { return }
        log("打开 " + url.absoluteString)
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 40)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.load(req)
    }

    // MARK: - 导航回调
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        log("开始导航")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        log("收到内容")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            log("HTTP \(http.statusCode) " + (http.url?.host ?? ""))
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideRetry()
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        log("完成")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error, tag: "didFail")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error, tag: "didFailProvisional")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("进程被回收，重载")
        load()
    }

    func fail(_ error: Error, tag: String) {
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        let e = error as NSError
        log("\(tag) 错误 [\(e.code)] \(e.localizedDescription)")
        showRetry("错误 \(e.code)：\(e.localizedDescription)")
    }

    // MARK: - 失败页（日志只在这里出现）
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
        btn2.setTitle("换个地址", for: .normal)
        btn2.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        btn2.setTitleColor(.darkGray, for: .normal)
        btn2.addTarget(self, action: #selector(editEntry), for: .touchUpInside)

        let tiny = UILabel()
        tiny.text = lines.suffix(6).joined(separator: "\n")
        tiny.numberOfLines = 0
        tiny.font = UIFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        tiny.textColor = UIColor(white: 0.62, alpha: 1)
        tiny.textAlignment = .left

        let stack = UIStackView(arrangedSubviews: [title, detail, btn, btn2, tiny])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -28),
            btn.heightAnchor.constraint(equalToConstant: 44),
            btn2.heightAnchor.constraint(equalToConstant: 34)
        ])
        view.addSubview(box)
        retryBox = box
    }

    @objc func retryTapped() { hideRetry(); clearCacheThenLoad() }
    func hideRetry() { retryBox?.removeFromSuperview(); retryBox = nil }

    // 外链交系统
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationRequestURL(navigationAction), let scheme = url.scheme?.lowercased(),
           scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func navigationRequestURL(_ a: WKNavigationAction) -> URL? { return a.request.url }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: - 左右滑动返回
    @objc func edgePan(_ g: UIScreenEdgePanGestureRecognizer) {
        guard g.state == .ended else { return }
        goBackSmart()
    }

    /// 先让网页关掉自己的弹层/退回列表；网页说没东西可关，再退浏览器历史
    func goBackSmart() {
        webView.evaluateJavaScript("(function(){try{return !!(window.__qlBack && window.__qlBack())}catch(e){return false}})()") { [weak self] r, _ in
            guard let self = self else { return }
            if let ok = r as? Bool, ok { return }
            if self.webView.canGoBack { self.webView.goBack() }
        }
    }

}

// MARK: - 保存图片到相册（网页调用 window.webkit.messageHandlers.saveImage）
extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "saveImage" else { return }
        guard let body = message.body as? [String: Any] else { return }
        if let dataUrl = body["dataUrl"] as? String, let img = WebViewController.imageFromDataURL(dataUrl) {
            WebViewController.saveToAlbum(img, webView: webView)
            return
        }
        if let urlStr = body["url"] as? String, let u = URL(string: urlStr) {
            URLSession.shared.dataTask(with: u) { data, _, _ in
                guard let data = data, let img = UIImage(data: data) else {
                    DispatchQueue.main.async { self.webView.evaluateJavaScript("window.__qlSaved && window.__qlSaved(false)") }
                    return
                }
                WebViewController.saveToAlbum(img, webView: self.webView)
            }.resume()
        }
    }

    static func imageFromDataURL(_ s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: d)
    }

    static func saveToAlbum(_ img: UIImage, webView: WKWebView) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async { webView.evaluateJavaScript("window.__qlSaved && window.__qlSaved(false)") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }) { ok, _ in
                DispatchQueue.main.async {
                    webView.evaluateJavaScript("window.__qlSaved && window.__qlSaved(\(ok ? "true" : "false"))")
                }
            }
        }
    }
}
