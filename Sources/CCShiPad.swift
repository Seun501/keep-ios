import SwiftUI

/// iPad 上的 Keep（11-24 寻定）：只用来和 CC师 干活，不显示克。
/// 排版照 Claude App：左边会话栏（左上角按钮收起／展开），右边对话居中成一栏、不铺满宽屏；横竖屏同一套。
/// 文件页盖在整屏上，一层层点进去、左上角退回。推送只收 CC师 的（登记带 scope=ccshi，网关发克的推送跳过这台）。
struct CCShiPadRoot: View {
    @State private var sel: String? = Preview.on && Preview.screen != "ipad" ? "p1" : nil
    @State private var side = Preview.screen != "ipadwide"   // 会话栏开着没有
    @State private var files: [String] = Preview.screen == "ipadfiles" ? [""] : []
    @ObservedObject private var viewer = ImageViewer.shared
    private func toggle() { withAnimation(.easeOut(duration: 0.22)) { side.toggle() } }

    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg.ignoresSafeArea()
                HStack(spacing: 0) {
                    if side {
                        CCShiListScreen(onBack: {}, onOpen: { sel = $0 }, onFiles: { files = [""] }, selected: sel, showBack: false, onSidebar: toggle, tinted: true)
                            .frame(width: min(340, max(290, g.size.width * 0.32)))   // 底色深一档代替分隔线（寻不喜欢描边）
                            .transition(.move(edge: .leading))
                    }
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
        .onReceive(NotificationCenter.default.publisher(for: .keepOpenCCShi)) { n in   // 点了「CC师」推送：右边换成那个会话
            if let sid = n.object as? String, !sid.isEmpty { files = []; sel = sid }
        }
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
