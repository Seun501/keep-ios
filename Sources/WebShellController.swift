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

    private let token: String
    private let onLogout: () -> Void
    private var webView: WKWebView!

    init(token: String, onLogout: @escaping () -> Void) {
        self.token = token
        self.onLogout = onLogout
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { webView?.configuration.userContentController.removeScriptMessageHandler(forName: "keep") }
    /// 键盘上沿在本视图坐标系里的 y；nil＝键盘收着。
    private var keyboardTop: CGFloat?

    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // 键盘通知的观察者按登记先后依次被叫。这里必须赶在 WKWebView 之前登记：
        // 我先把窗口收到键盘上沿，WebKit 随后量「键盘盖住了多少」＝零，就不再给页面垫内边距——
        // 否则它垫一次、我收一次，页面被推两回（09-02 首包寻验：跳）。
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardDidChange(_:)),
                       name: UIResponder.keyboardDidShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardDidChange(_:)),
                       name: UIResponder.keyboardDidHideNotification, object: nil)

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default()               // localStorage 持久（草稿/已读等）
        cfg.applicationNameForUserAgent = "KeepShell/1"

        // 口令由原生登录页拿到，在页面任何脚本跑之前种进 localStorage——网页照旧读 token 直入，
        // 它的口令页不会出现。只对自家域注入。网页若把 token 清掉（登出/口令失效）会露出登录层，
        // 那时通知原生回到原生口令页。
        let seed = """
        (function(){
          try { localStorage.setItem("token", \(Self.jsString(token))); } catch(e) {}
          document.addEventListener("DOMContentLoaded", function(){
            var login = document.getElementById("login");
            if (!login) return;
            var seen = false;
            new MutationObserver(function(){
              var shown = getComputedStyle(login).display !== "none";
              if (shown && !seen && !localStorage.getItem("token")) {
                seen = true;
                window.webkit && window.webkit.messageHandlers.keep &&
                  window.webkit.messageHandlers.keep.postMessage({type:"logout"});
              }
            }).observe(login, {attributes:true, attributeFilter:["style","class"]});
          });
        })();
        """
        let uc = cfg.userContentController
        uc.addUserScript(WKUserScript(source: seed, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        uc.add(self, name: "keep")

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
        Self.removeInputAccessoryBar(from: wv)
        webView.load(URLRequest(url: Self.home))
    }

    /// 摘掉键盘上方那根 Safari 式「上一个/下一个/完成」辅助条（09-02 首包寻验）。
    /// WKWebView 没有公开开关；做法是给内容视图动态派生一个子类，把 inputAccessoryView 答成 nil。
    private static func removeInputAccessoryBar(from webView: WKWebView) {
        guard let target = webView.scrollView.subviews.first(where: {
            NSStringFromClass(type(of: $0)).hasPrefix("WKContent")
        }) else { return }
        let name = "KeepWKContentView_NoAccessory"
        if let cls = NSClassFromString(name) {
            object_setClass(target, cls)
            return
        }
        guard let superclass = object_getClass(target),
              let cls = objc_allocateClassPair(superclass, name, 0) else { return }
        let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        class_addMethod(cls, #selector(getter: UIResponder.inputAccessoryView),
                        imp_implementationWithBlock(block), "@@:")
        objc_registerClassPair(cls)
        object_setClass(target, cls)
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

    /// 键盘升完/收完再钉一次：WebKit 若还是垫了内边距，这里抹平，页面只认窗口高度。
    @objc private func keyboardDidChange(_ n: Notification) {
        let sv = webView.scrollView
        if sv.contentInset != .zero { sv.contentInset = .zero }
        if sv.verticalScrollIndicatorInsets != .zero { sv.verticalScrollIndicatorInsets = .zero }
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

    // MARK: - 工具

    /// 把字符串安全地写成 JS 字面量。
    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
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

extension WebShellController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "keep",
              let body = message.body as? [String: Any],
              body["type"] as? String == "logout" else { return }
        onLogout()
    }
}
