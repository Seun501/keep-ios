import SwiftUI

/// iPad 上的 Keep（11-24 寻定）：只用来和 CC师 干活，不显示克。
/// 排版照 Claude App：左边会话栏（左上角按钮收起／展开），右边对话居中成一栏、不铺满宽屏；横竖屏同一套。
/// 文件页盖在整屏上，一层层点进去、左上角退回。推送只收 CC师 的（登记带 scope=ccshi，网关发克的推送跳过这台）。
struct CCShiPadRoot: View {
    @State private var sel: String? = Preview.on && Preview.screen != "ipad" ? "p1" : nil
    @State private var side = Preview.screen != "ipadwide"   // 会话栏开着没有（按钮、滑动动画看它）
    @State private var inset: CGFloat? = nil                  // 对话那边让出来的宽：不跟着动画变（每帧重排整条消息流会卡，11-24 寻），滑完/滑前一次到位
    @State private var files: [String] = Preview.screen == "ipadfiles" ? [""] : []
    @ObservedObject private var viewer = ImageViewer.shared
    @State private var dragPrepped = false                   // 往左拖着收：开拖那一下对话先铺满（同按钮收起）
    private let drag = PadDrag.shared                        // 跟手的位移放在小对象里，只有会话栏那层跟着重画（根不重画，对话不重排）
    /// 开：会话栏先盖着对话滑进来，滑完对话再一次让位；关：对话先一次铺满（被会话栏挡着看不见），会话栏再滑走
    private func toggle() {
        let noAnim = Transaction(animation: nil)
        if side {
            withTransaction(noAnim) { inset = 0 }
            withAnimation(.easeOut(duration: 0.24)) { side = false }
        } else {
            withAnimation(.easeOut(duration: 0.24)) { side = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { if side { withTransaction(noAnim) { inset = nil } } }
        }
    }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg.ignoresSafeArea()
                let w = min(340, max(290, g.size.width * 0.32))
                let pad = inset ?? (side ? w : 0)
                ZStack(alignment: .topLeading) {
                    // 对话跟着会话栏一起滑（11-24 寻：推着走）：滑的时候只平移，不改宽（不重排）；EquatableBox 挡住拖动时的重算
                    SideShift(w: w, side: side, pad: pad) {
                    EquatableBox(key: [sel ?? "", side ? "1" : "0", "\(pad)", "\(Int(g.size.width))"]) {
                    ZStack {
                        if let id = sel {
                            CCShiSessionScreen(id: id, onBack: {}, onOpen: { sel = $0 }, showBack: false, onSidebar: side ? nil : toggle, readWidth: 780).id(id)   // 读的一栏不铺满、顶栏顶满（Claude App 同款）
                        } else {
                            VStack(spacing: 0) {
                                HStack { if !side { CCSidebarButton(action: toggle) }; Spacer() }
                                    .padding(.horizontal, 16).padding(.top, 12).frame(minHeight: 52)
                                Spacer()
                                Text("从左边挑一个会话，或者点 + 开一个。").font(Theme.round(14)).foregroundColor(Theme.muted)
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.leading, pad)
                    }.equatable()
                    }
                    SideSlide(w: w, side: side) {
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
        }
        // 跟手拉会话栏（11-24 寻：照 Claude App）：收着时从屏幕左边缘往右拖，会话栏跟着手指出来（只认左边 28pt 起手，正文中间的手势不算，11-24 寻）；开着时在对话那边往左拖，跟着收回去。
        // 松手按拖了多远／甩的劲决定开还是退回
        .simultaneousGesture(DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onChanged { v in
                let w = min(340, max(290, UIScreen.main.bounds.width * 0.32))
                let dx = v.translation.width
                guard abs(dx) > abs(v.translation.height) * 1.2 || drag.dx != 0 else { return }
                if !side, dx > 0, v.startLocation.x < 28 { drag.dx = min(dx, w) }
                else if side, dx < 0, v.startLocation.x > w {
                    if !dragPrepped { dragPrepped = true; withTransaction(Transaction(animation: nil)) { inset = 0 } }
                    drag.dx = max(dx, -w)
                }
            }
            .onEnded { v in
                let w = min(340, max(290, UIScreen.main.bounds.width * 0.32))
                let dx = drag.dx, fling = v.predictedEndTranslation.width
                defer { dragPrepped = false }
                guard dx != 0 else { return }
                if !side {
                    if dx > w / 3 || fling > w / 2 { withAnimation(.easeOut(duration: 0.22)) { drag.dx = 0 }; toggle() }
                    else { withAnimation(.easeOut(duration: 0.2)) { drag.dx = 0 } }
                } else {
                    if -dx > w / 3 || fling < -w / 2 { withAnimation(.easeOut(duration: 0.22)) { drag.dx = 0; side = false } }
                    else {
                        withAnimation(.easeOut(duration: 0.2)) { drag.dx = 0 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { if side { withTransaction(Transaction(animation: nil)) { inset = nil } } }
                    }
                }
            })
        .background(KeyboardDismisser())   // 点空白收键盘（手机上挂在克那页，iPad 没那页，11-24 寻：悬浮小键盘点空白不收）
        .onAppear { PadJank.shared.start() }
        .onChange(of: side) { v in PadJank.shared.flush(); PadJank.shared.sideOn = v }
        .onReceive(NotificationCenter.default.publisher(for: .keepOpenCCShi)) { n in   // 点了「CC师」推送：右边换成那个会话
            if let sid = n.object as? String, !sid.isEmpty { files = []; sel = sid }
        }
    }
}

/// 会话栏跟手的位移（拖着时实时变；松手归零）
final class PadDrag: ObservableObject {
    static let shared = PadDrag()
    @Published var dx: CGFloat = 0
}

/// 会话栏那层：只它看 PadDrag，拖的时候只重画这一层
struct SideSlide<Content: View>: View {
    let w: CGFloat
    let side: Bool
    @ViewBuilder var content: () -> Content
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        content().offset(x: side ? min(0, drag.dx) : min(0, -w + max(0, drag.dx)))
    }
}

/// 对话那层的平移：会话栏露出多宽，对话就比它眼下的左边距多挪多少
struct SideShift<Content: View>: View {
    let w: CGFloat
    let side: Bool
    let pad: CGFloat
    @ViewBuilder var content: () -> Content
    @ObservedObject private var drag = PadDrag.shared
    var body: some View {
        let shown = side ? w + min(0, drag.dx) : max(0, drag.dx)
        content().offset(x: shown - pad)
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
    var body: some View {
        Button(action: action) {
            Image("tool-panel-left").renderingMode(.template).resizable().frame(width: 19, height: 19)
                .foregroundColor(Theme.text).frame(width: 34, height: 34)
        }
        .buttonStyle(.plain).padding(.leading, -6)
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
