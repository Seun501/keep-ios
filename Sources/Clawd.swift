import SwiftUI
import WebKit

/// 小 Clawd 的画：素材是带 CSS 动画的 SVG（呼吸/眨眼/打字），用一只透明 WKWebView 原样播。
struct ClawdWeb: UIViewRepresentable {
    let state: String
    let flip: Bool

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
    var onChange: (_ offsetY: CGFloat, _ contentH: CGFloat, _ viewportH: CGFloat) -> Void
    func makeUIView(context: Context) -> HookView {
        let v = HookView(); v.isUserInteractionEnabled = false
        v.onWindow = { [weak v] in if let v { context.coordinator.attach(from: v) } }
        return v
    }
    func updateUIView(_ uiView: HookView, context: Context) { context.coordinator.onChange = onChange }
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    final class Coordinator: NSObject {
        var onChange: (CGFloat, CGFloat, CGFloat) -> Void
        private var obs: [NSKeyValueObservation] = []
        private var kb: NSObjectProtocol? = nil
        private var atBottom = true
        init(onChange: @escaping (CGFloat, CGFloat, CGFloat) -> Void) { self.onChange = onChange }
        deinit { if let kb { NotificationCenter.default.removeObserver(kb) } }
        func attach(from v: UIView) {
            var s: UIView? = v
            while let cur = s, !(cur is UIScrollView) { s = cur.superview }
            guard let sv = s as? UIScrollView, obs.isEmpty else { return }
            sv.delaysContentTouches = false          // 长按选字第一次就成
            sv.contentInsetAdjustmentBehavior = .never   // 系统往底部塞的 ~18pt 内边距不要（网页无此空）
            sv.contentInset = .zero
            let fire = { [weak self, weak sv] in
                guard let self, let sv else { return }
                let inset = sv.adjustedContentInset
                let vh = sv.bounds.height - inset.top - inset.bottom
                let y = sv.contentOffset.y + inset.top
                self.atBottom = (sv.contentSize.height - y - vh) < 40
                self.onChange(y, sv.contentSize.height, vh)
            }
            obs.append(sv.observe(\.contentOffset) { _, _ in fire() })
            obs.append(sv.observe(\.contentSize) { _, _ in fire() })
            fire()
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


/// 导航条一隐藏，系统的「左缘右滑返回」就被关了；这里把手势重新打开（寻定：每个页面都要右滑退出）。
struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        DispatchQueue.main.async { enable(from: vc) }
        return vc
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) { enable(from: vc) }
    private func enable(from vc: UIViewController) {
        var p = vc.parent
        while let cur = p, !(cur is UINavigationController) { p = cur.parent }
        if let nav = p as? UINavigationController ?? vc.navigationController {
            nav.interactivePopGestureRecognizer?.delegate = nil
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}
