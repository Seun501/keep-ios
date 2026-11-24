import SwiftUI

/// iPad 上的 Keep（11-24 寻定）：只用来和 CC师 干活，不显示克。
/// 排版照 Claude App：左边会话栏（左上角按钮收起／展开），右边对话居中成一栏、不铺满宽屏；横竖屏同一套。
/// 文件页盖在整屏上，一层层点进去、左上角退回。推送只收 CC师 的（登记带 scope=ccshi，网关发克的推送跳过这台）。
struct CCShiPadRoot: View {
    @State private var sel: String? = Preview.on && Preview.screen != "ipad" ? "p1" : nil
    @State private var side = Preview.screen != "ipadwide"   // 会话栏开着没有（按钮、点按看它；滑的那几层看 PadDrag.side）
    @State private var files: [String] = Preview.screen == "ipadfiles" ? [""] : []
    @ObservedObject private var viewer = ImageViewer.shared
    private let drag = PadDrag.shared                        // 跟手的位移放在小对象里，只有滑的那几层跟着重画（根不重画，对话不重排）
    /// 开关会话栏：只动平移，不重排（11-24 寻：开收两头读的那一栏一样宽，字不跑；顶栏跟着一起滑）
    private func setSide(_ v: Bool, _ anim: Animation = .easeOut(duration: 0.24)) {
        withAnimation(anim) { side = v; drag.side = v; drag.dx = 0 }
    }
    private func toggle() { setSide(!side) }

    /// 会话栏宽
    static func barW(_ W: CGFloat) -> CGFloat { min(340, max(290, W * 0.32)) }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg.ignoresSafeArea()
                let w = Self.barW(g.size.width)
                // 读的那一栏开收都一样宽＝开着时会话栏右边剩下的宽（不超过 780）：收着时它居中，开着时正好填满右边，挪 w/2 就到位
                let rw = min(780, g.size.width - w)
                ZStack(alignment: .topLeading) {
                    SideShift(w: w) {
                    EquatableBox(key: [sel ?? "", "\(Int(g.size.width))"]) {   // 开关会话栏不进 key：里面不重算
                    ZStack {
                        if let id = sel {
                            CCShiSessionScreen(id: id, onBack: {}, onOpen: { sel = $0 }, showBack: false, onSidebar: toggle, readWidth: rw).id(id)
                        } else {
                            VStack(spacing: 0) {
                                PadHeaderEdge { HStack { CCSidebarButton(action: toggle, collapsing: true); Spacer() } }
                                    .padding(.horizontal, 16).padding(.top, 12).frame(minHeight: 52)
                                Spacer()
                                Text("从左边挑一个会话，或者点 + 开一个。").font(Theme.round(14)).foregroundColor(Theme.muted)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.equatable()
                    }
                    SideSlide(w: w) {
                        CCShiListScreen(onBack: {}, onOpen: { sel = $0 }, onFiles: { files = [""] }, selected: sel, showBack: false, onSidebar: toggle, tinted: true)
                    }
                    .frame(width: w)   // 底色深一档代替分隔线（寻不喜欢描边）；收起时整块滑出屏外，不拆不建
                    .allowsHitTesting(side)
                }
                ForEach(Array(files.enumerated()), id: \.offset) { i, p in
                    CCFilesScreen(path: p, onBack: { files.removeLast() }, onOpenDir: { files.append($0) }).id(p)
                        .zIndex(Double(100 + i))
                        .transaction { $0.animation = nil }
                }
                if viewer.image != nil || viewer.gallery != nil || viewer.cc != nil {
                    ImageViewerView(image: viewer.image, gallery: viewer.gallery, cc: viewer.cc, onClose: { viewer.close() }).zIndex(300).transaction { $0.animation = nil }
                }
            }
            .onAppear { drag.w = Self.barW(g.size.width) }
            .onChange(of: g.size.width) { W in drag.w = Self.barW(W) }
        }
        // 跟手拉会话栏（11-24 寻：照 Claude App）：收着时从屏幕左边缘往右拖，会话栏跟着手指出来（只认左边 28pt 起手，正文中间的手势不算）；开着时在对话那边往左拖，跟着收回去。
        // 松手按拖了多远／甩的劲决定开还是退回
        .simultaneousGesture(DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { v in
                let w = drag.w
                let dx = v.translation.width
                guard abs(dx) > abs(v.translation.height) * 1.2 || drag.dx != 0 else { return }
                if !side, dx > 0, v.startLocation.x < 28 { drag.dx = min(dx, w) }
                else if side, dx < 0, v.startLocation.x > w { drag.dx = max(dx, -w) }
            }
            .onEnded { v in
                let w = drag.w
                let dx = drag.dx, fling = v.predictedEndTranslation.width
                guard dx != 0 else { return }
                if !side { setSide(dx > w / 3 || fling > w / 2, .easeOut(duration: 0.22)) }
                else { setSide(!(-dx > w / 3 || fling < -w / 2), .easeOut(duration: 0.22)) }
            })
        .background(KeyboardDismisser())   // 点空白收键盘（手机上挂在克那页，iPad 没那页，11-24 寻：悬浮小键盘点空白不收）
        .onAppear { PadJank.shared.start(); drag.side = side }
        .onChange(of: side) { v in PadJank.shared.flush(); PadJank.shared.sideOn = v }
        .onReceive(NotificationCenter.default.publisher(for: .keepOpenCCShi)) { n in   // 点了「CC师」推送：右边换成那个会话
            if let sid = n.object as? String, !sid.isEmpty { files = []; sel = sid }
        }
    }
}

/// 会话栏开没开、跟手的位移（拖着时实时变；松手归零）；滑的那几层只看它
final class PadDrag: ObservableObject {
    static let shared = PadDrag()
    @Published var dx: CGFloat = 0
    @Published var side = true
    var w: CGFloat = 340
    /// 会话栏露出多宽
    var shown: CGFloat { side ? w + min(0, dx) : max(0, dx) }
}

/// 会话栏那层
struct SideSlide<Content: View>: View {
    let w: CGFloat
    @ViewBuilder var content: () -> Content
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        content().offset(x: drag.shown - w)
    }
}

/// 对话那层：读的那一栏开收一样宽，会话栏露出多少，它就挪一半（收着居中→开着填满右边），只平移不重排
struct SideShift<Content: View>: View {
    let w: CGFloat
    @ViewBuilder var content: () -> Content
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        content().offset(x: drag.shown / 2)
    }
}

/// 顶栏（和右上角弹的小卡）在 iPad 上顶满「会话栏右边到屏幕右边」：对话整层挪了 shown/2，顶栏两头各收 shown/2 抵回来；手机上不动
struct PadHeaderEdge<Content: View>: View {
    var leading = true
    var trailing = true
    @ViewBuilder var content: () -> Content
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        if UIDevice.isPad {
            content().padding(.leading, leading ? drag.shown / 2 : 0).padding(.trailing, trailing ? drag.shown / 2 : 0)
        } else { content() }
    }
}

/// 只在 key 变了才重算里面（拖动时外层每帧重画，里面的对话不跟着重算）
struct EquatableBox<Content: View>: View, Equatable {
    let key: [String]
    @ViewBuilder var content: () -> Content
    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    var body: some View { content() }
}

/// iPad 掉帧仪（11-24 寻：开着会话栏就卡）：一直数帧，每 20 秒有卡帧就报一行 diag（会话栏开没开、卡帧数、最长一帧），一次启动最多 30 行
final class PadJank {
    static let shared = PadJank()
    var sideOn = true
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0, t0: CFTimeInterval = 0
    private var big = 0, frames = 0, maxGap = 0.0, sent = 0
    func start() {
        guard link == nil, !Preview.on else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick(_:))); l.add(to: .main, forMode: .common); link = l
    }
    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 { let g = (l.timestamp - last) * 1000; frames += 1; if g > 50 { big += 1 }; if g > maxGap { maxGap = g } } else { t0 = l.timestamp }
        last = l.timestamp
        if l.timestamp - t0 > 20 { flush() }
    }
    func flush() {
        if big > 0 && sent < 30 && UIApplication.shared.applicationState == .active {
            sent += 1
            PushRegistrar.diag(String(format: "ipad-jank side=%d frames=%d big=%d max=%.0fms", sideOn ? 1 : 0, frames, big, maxGap))
        }
        big = 0; frames = 0; maxGap = 0; last = 0
    }
}

/// 收起／展开会话栏（Lucide panel-left）
struct CCSidebarButton: View {
    var action: () -> Void
    var collapsing = false   // 对话顶栏那只：会话栏开着时收起（开着时按钮在会话栏里），跟着滑的进度一起淡出、让位
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        let p = collapsing ? min(1, max(0, drag.shown / max(1, drag.w))) : 0
        Button(action: action) {
            Image("tool-panel-left").renderingMode(.template).resizable().frame(width: 19, height: 19)
                .foregroundColor(Theme.text).frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .frame(width: 34 * (1 - p), alignment: .leading).clipped()
        .opacity(1 - p)
        .allowsHitTesting(p < 0.5)
        .padding(.leading, -6 * (1 - p))
        .padding(.trailing, -12 * p)   // 顶栏 HStack 间距 12 一起让掉
    }
}

extension View {
    /// scrollBounceBehavior 要 16.4；寻的 iPad 停在 16.2（11-24），那儿退回系统默认
    @ViewBuilder func bounceVertical(_ always: Bool) -> some View {
        if #available(iOS 16.4, *) { scrollBounceBehavior(always ? .always : .basedOnSize, axes: .vertical) } else { self }
    }
}

extension UIDevice {
    static var isPad: Bool { current.userInterfaceIdiom == .pad }
}

/// 小 Clawd 在 iPad 上：会话栏开着就隐身（留白被会话栏占了），跟着滑的进度淡入淡出（11-24 寻）
struct PadClawdFade<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        if UIDevice.isPad {
            let p = min(1, max(0, drag.shown / max(1, drag.w)))
            content().opacity(1 - p).allowsHitTesting(p < 0.5)
        } else { content() }
    }
}
