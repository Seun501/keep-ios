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
        img{width:100vw;height:100vh;display:block}img.flip{transform:scaleX(-1)}</style></head>
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
    private var placed = false
    private let theater = ["groove", "coffee", "carry", "code", "wizard", "dizzy", "collapse"]

    func layout(area: CGSize, headerBottomInset: CGFloat = 0) {
        let size: CGFloat = 150
        let y0 = -size * 0.42, y1 = max(y0, area.height - size + size * 0.11)
        zone = CGRect(x: 8, y: y0, width: max(0, area.width - size - 16), height: max(0, y1 - y0))
        if !placed {
            placed = true
            pos = CGPoint(x: zone.midX, y: clampY(UIScreen.main.bounds.height * 0.45 - size * 0.67 - 60))
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
    @GestureState private var pressing = false
    var body: some View {
        ClawdWeb(state: m.state, flip: m.flip)
            .frame(width: 150, height: 150)
            .offset(y: m.hop ? -12 : 0)
            .position(x: m.pos.x + 75, y: m.pos.y + 75)
            .contentShape(Rectangle())
            .onTapGesture { m.tap() }
            .gesture(
                LongPressGesture(minimumDuration: 0.32)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("clawdZone")))
                    .onChanged { v in
                        switch v {
                        case .first(true): m.grab()
                        case .second(true, let d?): m.drag(to: d.location)
                        default: break
                        }
                    }
                    .onEnded { _ in m.release() }
            )
    }
}
