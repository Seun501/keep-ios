import SwiftUI
import WebKit

/// 小 Clawd 的画：素材是带 CSS 动画的 SVG（呼吸/眨眼/打字），用一只透明 WKWebView 原样播。
struct ClawdWeb: UIViewRepresentable {
    let state: String
    let flip: Bool
    var onReady: (() -> Void)? = nil     // 画真正装好（含 SVG）才回调——开屏句子等它一起出
    func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady) }
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onReady: (() -> Void)?
        init(onReady: (() -> Void)?) { self.onReady = onReady }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.onReady?() }   // 等一帧真画上去
        }
    }

    static let files: [String: String] = [
        "idle": "clawd-mini-idle", "walk": "clawd-mini-crabwalk", "happy": "clawd-mini-happy",
        "sleep": "clawd-mini-sleep", "peek": "clawd-mini-peek", "typing": "clawd-mini-typing",
        "alert": "clawd-mini-alert", "grabbed": "clawd-mini-grabbed", "groove": "clawd-headphones-groove",
        "coffee": "clawd-coffee-hand", "carry": "clawd-working-carrying", "code": "clawd-working-typing",
        "wizard": "clawd-working-wizard", "dizzy": "clawd-dizzy", "collapse": "clawd-collapse-sleep",
    ]

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.isUserInteractionEnabled = false
        wv.navigationDelegate = context.coordinator
        let dir = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent;overflow:hidden}
        img{width:150px;height:150px;display:block}img.flip{transform:scaleX(-1)}</style></head>
        <body><img id="i" src="\(Self.files[state] ?? "clawd-mini-idle").svg" class="\(flip ? "flip" : "")"></body></html>
        """
        wv.loadHTMLString(html, baseURL: dir)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        let f = Self.files[state] ?? "clawd-mini-idle"
        wv.evaluateJavaScript("(function(){var i=document.getElementById('i');if(!i)return;var s='\(f).svg';if(!i.src.endsWith(s))i.src=s;i.className='\(flip ? "flip" : "")';})()")
    }
}

/// 小 Clawd 的脾气（照网页那段 IIFE）：idle↔散步，久了打盹，戳一下开心蹦，长按拎起来拖走；克生成时打字，出错警觉。
@MainActor
final class ClawdModel: ObservableObject {
    @Published var pos = CGPoint(x: 100, y: 100)
    @Published var state = "idle"
    @Published var flip = false
    @Published var hop = false
    var zone = CGRect(x: 8, y: 0, width: 200, height: 300)
    private var timer: Timer?
    private var lastTouch = Date()
    private var dragging = false
    var isDragging: Bool { dragging }
    private var placed = false
    private let theater = ["groove", "coffee", "carry", "code", "wizard", "dizzy", "collapse"]

    /// 开屏站位（网页：可见蟹身中心=屏高45%；素材可见中心≈盒高67%）→ 盒顶（屏幕坐标）
    static func splashBoxTop(_ screenH: CGFloat) -> CGFloat { screenH * 0.45 - 150 * 0.67 }

    func layout(area: CGSize, areaTop: CGFloat = 0) {
        let size: CGFloat = 150
        guard area.width > 200, area.height > 200 else { return }   // 还没量到真尺寸别落位（否则 clamp 到左上角）
        let y0 = -size * 0.42, y1 = max(y0, area.height - size + size * 0.11)
        zone = CGRect(x: 8, y: y0, width: max(0, area.width - size - 16), height: max(0, y1 - y0))
        if !placed {
            placed = true
            pos = CGPoint(x: zone.midX, y: clampY(Self.splashBoxTop(UIScreen.main.bounds.height) - areaTop))
            idle()
        } else if !dragging {
            pos = CGPoint(x: clampX(pos.x), y: clampY(pos.y))
        }
    }
    private func clampX(_ x: CGFloat) -> CGFloat { min(max(x, zone.minX), zone.maxX) }
    private func clampY(_ y: CGFloat) -> CGFloat { min(max(y, zone.minY), zone.maxY) }
    private func later(_ s: Double, _ fn: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { _ in Task { @MainActor in fn() } }
    }

    func idle() {
        if dragging { return }
        state = "idle"
        later(Double.random(in: 3...9)) { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastTouch) > 150 { self.state = "sleep"; self.later(Double.random(in: 60...120)) { self.idle() } }
            else if Double.random(in: 0..<1) < 0.22 { self.state = self.theater.randomElement()!; self.later(Double.random(in: 8...16)) { self.idle() } }
            else { self.walk() }
        }
    }
    private func walk() {
        if dragging { return }
        let tx = clampX(pos.x + CGFloat.random(in: -150...150))
        let ty = clampY(pos.y + CGFloat.random(in: -80...80))
        flip = tx < pos.x
        state = "walk"
        let dist = hypot(tx - pos.x, ty - pos.y)
        let dur = max(0.2, Double(dist / 40))   // 40 px/s，螃蟹步不着急
        withAnimation(.linear(duration: dur)) { pos = CGPoint(x: tx, y: ty) }
        later(dur) { [weak self] in self?.idle() }
    }
    func tap() {
        lastTouch = Date()
        if dragging { return }
        if state == "sleep" { state = "peek"; later(1.4) { [weak self] in self?.idle() }; return }
        state = "happy"; hop = false
        withAnimation(.easeOut(duration: 0.22)) { hop = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation(.easeIn(duration: 0.25)) { self.hop = false } }
        later(1.6) { [weak self] in self?.idle() }
    }
    func grab() { lastTouch = Date(); dragging = true; timer?.invalidate(); state = "grabbed"; flip = false }
    func drag(to p: CGPoint) { guard dragging else { return }; pos = CGPoint(x: clampX(p.x - 75), y: clampY(p.y - 150 * 0.62)) }
    func release() { lastTouch = Date(); if dragging { dragging = false; later(0.25) { [weak self] in self?.idle() } } }
    func busy(_ on: Bool) {
        if dragging { return }
        lastTouch = Date(); timer?.invalidate()
        if on { state = "typing"; flip = false } else { idle() }
    }
    func alert() { if dragging { return }; timer?.invalidate(); state = "alert"; later(2.6) { [weak self] in self?.idle() } }
    func touched() { lastTouch = Date() }
}

struct ClawdView: View {
    @ObservedObject var m: ClawdModel
    @State private var downAt: Date? = nil
    @State private var moved = false
    @State private var grabTimer: DispatchWorkItem? = nil
    var body: some View {
        ClawdWeb(state: m.state, flip: m.flip)
            .frame(width: 150, height: 150)
            .offset(y: m.hop ? -12 : 0)
            .contentShape(Rectangle())            // 只有蟹身这 150×150 吃触摸
            .gesture(
                // 自己计时（系统的长按/点按并用在这里不听话）：按住 ≥0.32s 拎起来拖，短按＝戳一下
                DragGesture(minimumDistance: 0, coordinateSpace: .named("clawdZone"))
                    .onChanged { v in
                        if downAt == nil {
                            downAt = Date(); moved = false
                            let w = DispatchWorkItem { m.grab() }
                            grabTimer = w
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: w)
                        }
                        if abs(v.translation.width) > 8 || abs(v.translation.height) > 8 { moved = true }
                        if m.isDragging { m.drag(to: v.location) }
                    }
                    .onEnded { _ in
                        grabTimer?.cancel()
                        let short = (downAt.map { Date().timeIntervalSince($0) } ?? 1) < 0.32
                        if m.isDragging { m.release() } else if short && !moved { m.tap() }
                        downAt = nil
                    }
            )
            .position(x: m.pos.x + 75, y: m.pos.y + 75)
    }
}

/// 读真实滚动位置（放在滚动内容的 background 里，进窗口后往上找到 UIScrollView 观察 contentOffset/contentSize），
/// 并在键盘升起时把内容跟着平移：原本钉着底就继续钉底。
struct ScrollObserver: UIViewRepresentable {
    var name: String? = nil            // 登记名：外面按名拿到 UIScrollView（精确滚到底）
    var bounce = true                  // 留言板列表要硬朗（寻定：不要拉空回弹）
    var onChange: (_ offsetY: CGFloat, _ contentH: CGFloat, _ viewportH: CGFloat) -> Void
    final class WeakBox { weak var sv: UIScrollView?; init(_ s: UIScrollView) { sv = s } }
    static var registry: [String: WeakBox] = [:]
    static func view(_ name: String) -> UIScrollView? { registry[name]?.sv }
    func makeUIView(context: Context) -> HookView {
        let v = HookView(); v.isUserInteractionEnabled = false
        let name = self.name, bounce = self.bounce
        v.onWindow = { [weak v] in if let v { context.coordinator.attach(from: v, name: name, bounce: bounce) } }
        return v
    }
    func updateUIView(_ uiView: HookView, context: Context) { context.coordinator.onChange = onChange }
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    final class Coordinator: NSObject {
        var onChange: (CGFloat, CGFloat, CGFloat) -> Void
        private var obs: [NSKeyValueObservation] = []
        private var kb: [NSObjectProtocol] = []
        private var atBottom = true
        private var lastDist: CGFloat = 0    // 视口底边以下还有多少内容——一直记着「键盘来之前」那个数（底边锚定，iMessage 做法）
        private var lastH: CGFloat = 0
        private var kbBusy = false
        private var bounce = true
        private weak var sv: UIScrollView? = nil
        private var name: String? = nil
        private var logged = 0
        init(onChange: @escaping (CGFloat, CGFloat, CGFloat) -> Void) { self.onChange = onChange }
        deinit { kb.forEach { NotificationCenter.default.removeObserver($0) } }
        func attach(from v: UIView, name: String?, bounce: Bool) {
            var s: UIView? = v
            while let cur = s, !(cur is UIScrollView) { s = cur.superview }
            guard let sv = s as? UIScrollView, obs.isEmpty else { return }
            self.sv = sv; self.name = name; self.bounce = bounce
            if let name { ScrollObserver.registry[name] = ScrollObserver.WeakBox(sv) }
            sv.delaysContentTouches = false          // 长按选字第一次就成
            sv.contentInsetAdjustmentBehavior = .never   // 系统往底部塞的 ~18pt 内边距不要（网页无此空）
            sv.contentInset = .zero
            // 原生指示条（网页那根就是 WebKit 的它）：轨道底端抬 22、贴右 2；颜色照网页 rgba(217,119,87,.4)
            sv.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
            let fire = { [weak self, weak sv] in
                guard let self, let sv else { return }
                if sv.bounces != self.bounce || sv.alwaysBounceVertical != self.bounce { sv.bounces = self.bounce; sv.alwaysBounceVertical = self.bounce }   // SwiftUI 会改回去，每次都按住
                self.tintIndicator(sv)
                let inset = sv.adjustedContentInset
                let vh = sv.bounds.height - inset.top - inset.bottom
                let y = sv.contentOffset.y + inset.top
                self.atBottom = (sv.contentSize.height - y - vh) < 40
                // 视口高度没在变的时候才更新「底边以下量」——系统让位先于我改帧，改帧后量到的数是错的（寻验 41：又不跟了）
                if !self.kbBusy, abs(sv.bounds.height - self.lastH) < 0.5 { self.lastDist = max(0, sv.contentSize.height - y - vh) }
                self.lastH = sv.bounds.height
                self.onChange(y, sv.contentSize.height, vh)
            }
            obs.append(sv.observe(\.contentOffset) { _, _ in fire() })
            obs.append(sv.observe(\.contentSize) { _, _ in fire() })
            // 键盘：系统让位把视口压矮/放高（它跑在我前面），我拿「键盘来之前底边以下的内容量」算出新偏移，
            // 用键盘同一条曲线同一时长把 contentOffset 动过去——底边锚定（iMessage 做法），和键盘一起走、不逐帧硬掰。
            for n in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
                kb.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                    guard let self, let sv = self.sv else { return }
                    let dur = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
                    let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
                    // 滚动本身交给 SwiftUI 的 scrollTo（ChatScreen 里做）：UIKit 改的 contentOffset 会被 SwiftUI 每帧布局写回抹掉（构建 43 快照实证）
                    _ = (dur, curve)
                    self.kbBusy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.15) { [weak self] in self?.kbBusy = false }
                    if n == UIResponder.keyboardWillShowNotification, self.logged < 4, self.name == "chat" { self.logged += 1; self.snapshot("kb-show", note); DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.snapshot("kb-after", note) } }
                })
            }
            fire()
        }
        /// 排查用：键盘前后滚动区的帧/内容高/偏移/底距，进服务器 diag 日志（一次会话最多四回）
        private func snapshot(_ tag: String, _ note: Notification) {
            guard let sv else { return }
            let f = sv.convert(sv.bounds, to: nil)
            let kf = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
            PushRegistrar.diag(String(format: "%@: frame=%.0f..%.0f inset=%.0f cs=%.0f off=%.0f kbTop=%.0f dist=%.0f safe=%.0f", tag, f.minY, f.maxY, sv.contentInset.bottom, sv.contentSize.height, sv.contentOffset.y, kf.minY, lastDist, sv.safeAreaInsets.bottom))
        }
        /// 把系统指示条染成赤陶 40%（指示条是私有子视图，每次滚动时补染——它会被重建）
        private func tintIndicator(_ sv: UIScrollView) {
            for v in sv.subviews where String(describing: type(of: v)).contains("ScrollIndicator") {
                if v.subviews.isEmpty { v.backgroundColor = Theme.uiScrollTint.withAlphaComponent(0.4); v.layer.cornerRadius = v.bounds.width / 2 }
                for pill in v.subviews where pill.backgroundColor != Theme.uiScrollTint.withAlphaComponent(0.4) {
                    pill.backgroundColor = Theme.uiScrollTint.withAlphaComponent(0.4)
                }
                // 按住拖动时系统把条加粗一倍多——压回一半，右缘不动（寻验 43：太粗）
                let w = v.bounds.width
                if w > 4.5 {
                    let s: CGFloat = 0.5
                    v.transform = CGAffineTransform(translationX: w * (1 - s) / 2, y: 0).scaledBy(x: s, y: 1)
                } else if v.transform != .identity { v.transform = .identity }
            }
        }
    }
}

/// 进了窗口才回调（UIViewRepresentable 的 makeUIView 时视图还没进层级）
final class HookView: UIView {
    var onWindow: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { onWindow?() } }
}

/// 系统级「点空白收键盘」：给窗口挂一只不吞触摸的点按识别器（SwiftUI 的 TapGesture 在滚动区里靠不住）。
struct KeyboardDismisser: UIViewRepresentable {
    func makeUIView(context: Context) -> HookView {
        let v = HookView(); v.isUserInteractionEnabled = false
        v.onWindow = { [weak v] in
            guard let w = v?.window, !(w.gestureRecognizers ?? []).contains(where: { $0.name == "keep.dismiss" }) else { return }
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
            tap.name = "keep.dismiss"; tap.cancelsTouchesInView = false; tap.delegate = context.coordinator
            w.addGestureRecognizer(tap)
        }
        return v
    }
    func updateUIView(_ uiView: HookView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @objc func tap(_ g: UITapGestureRecognizer) {
            var v = g.view?.hitTest(g.location(in: g.view), with: nil)
            while let cur = v {
                if let tv = cur as? UITextView, tv.isEditable { return }
                if cur is UITextField || cur is UIControl { return }
                v = cur.superview
            }
            g.view?.endEditing(true)
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith o: UIGestureRecognizer) -> Bool { true }
    }
}


/// 左缘右滑＝退回上一页（照网页 touchmove：起点 <26px、右移 >55px 就收掉最上面的页）。
/// 挂在窗口上一只屏缘手势，压在网页壳上也能接到；哪页在最上面就退哪页，页退光了手势就闲着。
struct EdgeSwipe: UIViewRepresentable {
    var onBack: () -> Void
    static var stack: [(id: ObjectIdentifier, fire: () -> Void)] = []
    func makeUIView(context: Context) -> HookView {
        let v = HookView(); v.isUserInteractionEnabled = false
        let co = context.coordinator
        v.onWindow = { [weak v] in
            guard let w = v?.window else { return }
            if !(w.gestureRecognizers ?? []).contains(where: { $0.name == "keep.edge" }) {
                let g = UIScreenEdgePanGestureRecognizer(target: EdgeSwipe.Sink.shared, action: #selector(EdgeSwipe.Sink.pan))
                g.edges = .left; g.name = "keep.edge"
                w.addGestureRecognizer(g)
            }
            if !EdgeSwipe.stack.contains(where: { $0.id == ObjectIdentifier(co) }) {
                EdgeSwipe.stack.append((ObjectIdentifier(co), { co.onBack() }))
            }
        }
        return v
    }
    func updateUIView(_ uiView: HookView, context: Context) { context.coordinator.onBack = onBack }
    static func dismantleUIView(_ uiView: HookView, coordinator: Coordinator) {
        EdgeSwipe.stack.removeAll { $0.id == ObjectIdentifier(coordinator) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onBack: onBack) }
    final class Coordinator { var onBack: () -> Void; init(onBack: @escaping () -> Void) { self.onBack = onBack } }
    final class Sink: NSObject {
        static let shared = Sink()
        private var fired = false
        @objc func pan(_ g: UIScreenEdgePanGestureRecognizer) {
            switch g.state {
            case .began: fired = false
            case .changed:
                if !fired, g.translation(in: g.view).x > 55 { fired = true; EdgeSwipe.stack.last?.fire() }
            default: break
            }
        }
    }
}
