import UIKit
import WebKit
import Photos

/// 尤雾排单 WebView 壳 v1.4.0
/// - v1.4.0：文件（ipa/zip/xlsx…）不再在网页里打开成一页 HTML；改成 App 内下载 → 系统分享面板（可选「存储到文件」/用别的 App 打开）
/// - 左下角悬浮「‹ 返回」：只有网页真的转过页（canGoBack）时才出现
/// - 右上角一个很淡的齿轮：刷新 / 换地址用
class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {

    // 每个 App 只改这三行
    let defaultURL = "https://youwutu.top/f?gid=162&pw=1"
    let appTitle = "尤雾排单"
    let uaSuffix = "YouwuPindan/1.4.0"
    var entryURL: String { return UserDefaults.standard.string(forKey: "ql_entry") ?? defaultURL }

    var webView: WKWebView!
    var gear: UIButton!
    var backBtn: UIButton!
    var webBottom: NSLayoutConstraint!
    var retryBox: UIView?
    var hud: UIView?
    var lines: [String] = []

    /// 这些后缀一律当「文件下载」，不在网页里打开
    static let dlExts: Set<String> = [
        "ipa", "apk", "zip", "rar", "7z", "exe", "dmg", "msi", "pkg", "deb",
        "mobileprovision", "plist", "gz", "tar", "tgz", "bz2", "xz", "iso",
        "xlsx", "xls", "doc", "docx", "ppt", "pptx", "csv", "numbers", "pages", "key",
        "mp3", "mp4", "mov", "m4a", "wav", "amr"
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        /* 网页调用 window.webkit.messageHandlers.* ：保存图片到相册 / 下载文件 */
        let ucc = cfg.userContentController
        ucc.add(self, name: "saveImage")
        ucc.add(self, name: "downloadFile")
        if #available(iOS 14.0, *) {
            cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 系统边缘手势关掉（网页是单页应用，退历史没意义；返回交给左下角的悬浮按钮）
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false     // 长按别弹系统预览，二级菜单自己做

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

        /* v1.4.0 左下角悬浮「‹ 返回」：网页真转过页才出现（1.3.1 去掉边缘手势后，进到文件页/外链页就退不回来） */
        backBtn = UIButton(type: .system)
        backBtn.setTitle("‹", for: .normal)
        backBtn.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .semibold)
        backBtn.setTitleColor(.white, for: .normal)
        backBtn.backgroundColor = UIColor(white: 0, alpha: 0.45)
        backBtn.layer.cornerRadius = 19
        backBtn.translatesAutoresizingMaskIntoConstraints = false
        backBtn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backBtn.isHidden = true
        view.addSubview(backBtn)
        NSLayoutConstraint.activate([
            backBtn.widthAnchor.constraint(equalToConstant: 38),
            backBtn.heightAnchor.constraint(equalToConstant: 38),
            backBtn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            backBtn.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        webView.addObserver(self, forKeyPath: "canGoBack", options: [.new], context: nil)

        log("启动 v1.4.0 · " + entryURL)
        clearCacheThenLoad()
    }

    deinit {
        webView?.removeObserver(self, forKeyPath: "canGoBack")
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "canGoBack" { updateBack() }
    }

    func updateBack() {
        let on = webView.canGoBack
        backBtn.isHidden = !on
        backBtn.alpha = on ? 1 : 0
    }

    @objc func backTapped() {
        if webView.canGoBack { webView.goBack() } else { updateBack() }
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
        updateBack()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse {
            log("HTTP \(http.statusCode) " + (http.url?.host ?? ""))
            /* v1.4.0：网页显示不了的东西（ipa / zip / xlsx…）不让它进 webview，改成 App 内下载 + 分享面板 */
            let disp = (http.value(forHTTPHeaderField: "content-disposition") ?? "").lowercased()
            let isFile = !navigationResponse.canShowMIMEType
                || disp.contains("attachment")
                || WebViewController.isDownloadURL(http.url)
            if isFile {
                decisionHandler(.cancel)
                if let u = http.url {
                    startDownload(u, name: WebViewController.filename(from: http, url: u, fallback: nil))
                } else {
                    alert("下载失败", "拿不到文件地址")
                }
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hideRetry()
        if let rc = webView.scrollView.refreshControl, rc.isRefreshing { rc.endRefreshing() }
        updateBack()
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
        /* 我们主动 cancel 掉一次导航（去下载）时会报 -999，这不是错误 */
        if e.code == NSURLErrorCancelled { return }
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

    // 外链交系统；文件类地址不导航，直接下载
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationRequestURL(navigationAction), let scheme = url.scheme?.lowercased(),
           scheme != "http", scheme != "https", scheme != "about", scheme != "blob", scheme != "data" {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }
        if let url = navigationRequestURL(navigationAction), WebViewController.isDownloadURL(url) {
            decisionHandler(.cancel)
            startDownload(url, name: nil)
            return
        }
        decisionHandler(.allow)
    }

    func navigationRequestURL(_ a: WKNavigationAction) -> URL? { return a.request.url }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            /* target=_blank 的文件链接（聊天里的 ipa/zip…）→ 下载，不再塞进同一个 webview 变成一页 */
            if WebViewController.isDownloadURL(url) {
                startDownload(url, name: nil)
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    // MARK: - 文件下载 → 系统分享面板（可选「存储到文件」/ 用别的 App 打开）
    static func isDownloadURL(_ url: URL?) -> Bool {
        guard let url = url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && dlExts.contains(ext)
    }

    static func filename(from resp: URLResponse?, url: URL, fallback: String?) -> String {
        var name = (fallback ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty, let http = resp as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition") {
            if let r = cd.range(of: "filename*=UTF-8''") {
                let tail = String(cd[r.upperBound...])
                let raw = (tail.components(separatedBy: ";").first ?? tail)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                if let d = raw.removingPercentEncoding, !d.isEmpty { name = d }
            }
            if name.isEmpty, let r = cd.range(of: "filename=\"") {
                let tail = String(cd[r.upperBound...])
                if let end = tail.firstIndex(of: "\"") { name = String(tail[..<end]) }
            }
            if name.isEmpty, let r = cd.range(of: "filename=") {
                let tail = String(cd[r.upperBound...])
                name = (tail.components(separatedBy: ";").first ?? tail)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
        }
        if name.isEmpty { name = url.lastPathComponent }
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if name.isEmpty || name == "/" { name = "文件" }
        return name
    }

    func startDownload(_ url: URL, name: String?) {
        log("下载 " + url.lastPathComponent)
        showHUD("正在下载…")
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        let sess = URLSession(configuration: cfg)
        sess.downloadTask(with: url) { tmp, resp, err in
            DispatchQueue.main.async {
                self.hideHUD()
                guard let tmp = tmp else {
                    self.alert("下载失败", err?.localizedDescription ?? "网络错误")
                    return
                }
                let fname = WebViewController.filename(from: resp, url: url, fallback: name)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ql-dl", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dst = dir.appendingPathComponent(fname)
                try? FileManager.default.removeItem(at: dst)
                do {
                    try FileManager.default.moveItem(at: tmp, to: dst)
                } catch {
                    /* 换名字失败就用原文件名 */
                    let alt = dir.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: alt)
                    do { try FileManager.default.moveItem(at: tmp, to: alt) }
                    catch { self.alert("下载失败", error.localizedDescription); return }
                    self.shareFile(alt)
                    return
                }
                self.shareFile(dst)
            }
        }.resume()
    }

    func shareFile(_ url: URL) {
        log("分享 " + url.lastPathComponent)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 1, height: 1)
        }
        present(av, animated: true)
    }

    func showHUD(_ text: String) {
        hideHUD()
        let box = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 84))
        box.center = view.center
        box.backgroundColor = UIColor(white: 0, alpha: 0.72)
        box.layer.cornerRadius = 14
        let sp = UIActivityIndicatorView(style: .medium)
        sp.color = .white
        sp.frame = CGRect(x: 76, y: 12, width: 28, height: 28)
        sp.startAnimating()
        let l = UILabel(frame: CGRect(x: 8, y: 46, width: 164, height: 24))
        l.text = text
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 13)
        l.textAlignment = .center
        box.addSubview(sp)
        box.addSubview(l)
        view.addSubview(box)
        hud = box
    }

    func hideHUD() { hud?.removeFromSuperview(); hud = nil }

    func alert(_ title: String, _ msg: String) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

}

// MARK: - 网页调原生（保存图片 / 下载文件）
extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "downloadFile" {
            guard let body = message.body as? [String: Any], let s = body["url"] as? String, let u = URL(string: s) else { return }
            let nm = (body["name"] as? String) ?? ""
            startDownload(u, name: nm.isEmpty ? nil : nm)
            return
        }
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
