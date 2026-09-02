import UIKit
import WebKit

/// 原生壳的全部机关都在这一个控制器里：
/// 1. 键盘接管——键盘升起时把 WKWebView 的高度收到键盘上沿（跟随系统动画曲线），
///    页面得到的是真实的窗口变矮（innerHeight / svh / dvh 全部同步），不再靠 visualViewport 猜；
///    键盘收起时整块还原。这是 Web 端九连败的病根所在，原生一行 frame 就够。
/// 2. User-Agent 尾巴 `KeepShell/1`——网页可据此关掉自己那套键盘补丁。
/// 3. 站外链接交给系统浏览器，window.open 同样外开，壳里永远只有自家页面。
/// 4. 网页进程被系统回收时自动重载。
final class WebShellController: UIViewController {

    static let home = URL(string: "https://ke.seunk.cn/")!
    static let ownHosts: Set<String> = ["ke.seunk.cn"]

    private var webView: WKWebView!
    /// 键盘上沿在本视图坐标系里的 y；nil＝键盘收着。
    private var keyboardTop: CGFloat?

    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()               // 口令/localStorage 持久，登一次就行
        cfg.applicationNameForUserAgent = "KeepShell/1"

        let wv = WKWebView(frame: view.bounds, configuration: cfg)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsLinkPreview = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.scrollView.bounces = false                    // 文档层不橡皮筋；页内滚动容器不受影响
        wv.scrollView.keyboardDismissMode = .interactive
        wv.backgroundColor = .systemBackground
        wv.isOpaque = true
        if #available(iOS 15.0, *) {
            wv.underPageBackgroundColor = .systemBackground
        }
        view.addSubview(wv)
        webView = wv
        webView.load(URLRequest(url: Self.home))

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutWeb(animated: false)
    }

    // MARK: - 键盘

    @objc private func keyboardWillChange(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let inView = view.convert(end, from: nil)
        // 键盘整个滑到屏幕之外＝收起；浮动/分离键盘（iPad 才有）不在考虑内。
        keyboardTop = inView.minY >= view.bounds.height - 1 ? nil : inView.minY
        animate(with: n)
    }

    @objc private func keyboardWillHide(_ n: Notification) {
        keyboardTop = nil
        animate(with: n)
    }

    private func animate(with n: Notification) {
        let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curveRaw = n.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        layoutWeb(animated: true, duration: duration,
                  options: UIView.AnimationOptions(rawValue: curveRaw << 16))
    }

    private func layoutWeb(animated: Bool, duration: Double = 0, options: UIView.AnimationOptions = []) {
        var frame = view.bounds
        if let top = keyboardTop { frame.size.height = max(0, top) }
        guard webView.frame != frame else { return }
        let apply = { self.webView.frame = frame }
        if animated {
            UIView.animate(withDuration: duration, delay: 0,
                           options: options.union(.beginFromCurrentState), animations: apply)
        } else {
            apply()
        }
    }

    // MARK: - 站外链接

    private func isOwn(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return true }   // about:blank 之类放行
        return Self.ownHosts.contains(host)
    }
}

extension WebShellController: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .linkActivated, !isOwn(url), let url {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// target=_blank / window.open：壳里不开新窗，交给系统浏览器。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isOwn(url) { webView.load(navigationAction.request) } else { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
