import SwiftUI

/// 消息流里的一格。规则照网页 buildRangeFrag。
enum TimelineItem {
    case daySep(String)
    case user(text: String, stamp: String, images: [String])
    case ai(index: Int, msg: Msg, showUsage: Bool)
    case toolChip(String)
    case ping(Msg)
    case wakeChip(String)
    case knock(text: String, stamp: String)
}

/// 带稳定 id 的一格：id＝正史下标＋该条目内序号，重建后同一条还是同一个 id（ForEach 不抖）。
struct TimelineRow: Identifiable {
    let id: String
    let item: TimelineItem
}

extension TimelineItem {
    static func build(_ msgs: [Msg], from: Int, to: Int, lastUsageIdx: Int) -> [TimelineRow] {
        var rows: [TimelineRow] = []
        var out: [TimelineItem] = []
        var cur = from
        func flush() {
            for (k, it) in out.enumerated() { rows.append(TimelineRow(id: "\(cur)-\(k)", item: it)) }
            out.removeAll()
        }
        // 注意：这里不能用 defer——`return rows` 先求值、defer 后跑，最后一条永远进不了返回值
        //（构建 28 前一直如此：克的最新一条要等下一条来了才露面，寻验「克也不回复我」的病根）
        var prevDay = from > 0 ? msgs[from - 1].localDay : ""
        for i in from..<to {
            flush(); cur = i
            let m = msgs[i]
            if m.isWake {
                // 自由活动整段不上屏；只有 knock（克主动敲她的话）浮出来。
                if m.role == "assistant", let tcs = m.toolCalls {
                    for tc in tcs where tc.shortName == "knock" {
                        if let a = tc.function?.arguments, let d = a.data(using: .utf8),
                           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let kc = (j["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !kc.isEmpty {
                            out.append(.knock(text: kc, stamp: TimeFmt.stamp(m.ts)))
                        }
                    }
                }
                continue
            }
            let d = m.localDay
            if !d.isEmpty, d != prevDay { out.append(.daySep(d)); prevDay = d }
            if m.role == "assistant" {
                let hasText = !(m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasText || !m.cleanThinking.isEmpty {
                    out.append(.ai(index: i, msg: m, showUsage: i == lastUsageIdx))
                }
                if let tcs = m.toolCalls { for tc in tcs { out.append(.toolChip(tc.name)) } }
            } else if m.role == "user" {
                if m.isPing { out.append(.ping(m)) }
                else if m.knock == true {
                    out.append(.user(text: m.knockText ?? m.content ?? "", stamp: TimeFmt.stamp(m.ts) + " · Knock", images: []))
                } else {
                    out.append(.user(text: m.content ?? "", stamp: TimeFmt.stamp(m.ts), images: m.images ?? []))
                }
            }
        }
        flush()
        return rows
    }
}

extension Notification.Name { static let keepThinkToggled = Notification.Name("keep.thinkToggled") }

struct DaySepView: View {
    let day: String
    var body: some View {
        Text("· \(day) ·").font(Theme.round(12)).tracking(1).foregroundColor(Theme.muted)
            .frame(maxWidth: .infinity)
    }
}

struct UserRowView: View {
    let text: String
    let stamp: String
    let images: [String]
    var tagNo: String? = nil          // 档案馆条数开关：#N 贴时间旁（她的气泡时间顶右，编号从左边进）
    var flash = false                 // #N 直跳：编号闪几秒
    var highlight = ""                // 检索关键词标黄
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {   // .meta.below margin-top 4
            // 照网页 .row.user > img.att：图站在气泡外上方、素着不加修饰、贴右、圆角 26 同她的气泡、点开看大图；图下空 6
            ForEach(Array(images.enumerated()), id: \.offset) { _, u in
                StreamImage(src: u, maxW: 200, maxH: 200, radius: 26).padding(.bottom, 2)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let attr = MD.xunNS(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n"))   // 段间靠 paragraphSpacing 8，不空整行（寻验：段间太宽）
                RichText(attr: highlight.isEmpty ? attr : ArchiveScreen.highlight(attr, highlight))
                    .padding(.horizontal, 16).padding(.vertical, 10)   // 行框改自然高后上下对称，照网页 10/16
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .textSelection(.enabled)
            }
            if !stamp.isEmpty {
                HStack(spacing: 8) {
                    if let t = tagNo { NoTag(t, flash: flash) }
                    Text(stamp).font(Theme.round(12)).foregroundColor(Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, UIScreen.main.bounds.width * 0.16)   // max-width 84%
    }
}

/// 思考块：小时钟＋「Thought for Ns」，默认折叠，点开看全文。
struct ThinkView: View {
    let text: String
    let label: String
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 照网页 .think-head：小时钟＋一行字，没有箭头；整行都能点。不用 Button——按下会闪一下高亮（寻验 44：别花里胡哨）
            HStack(spacing: 7) {
                Image(systemName: "clock").font(.system(size: 12))
                Text(label).font(Theme.serif(13))
            }
            .foregroundColor(Theme.muted)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                open.toggle()
                NotificationCenter.default.post(name: .keepThinkToggled, object: nil)   // 折回去时若在底，列表要跟着落回底（寻验 44）
            }
            if open {
                HStack(alignment: .top, spacing: 14) {
                    Rectangle().fill(Theme.border).frame(width: 1.5).padding(.leading, 4)
                    RichText(attr: MD.ns(text, base: Theme.uiSerif(14), bold: Theme.uiSerif(14, weight: .semibold),
                                          mono: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular), color: Theme.uiMuted, lineHeight: 1.6))
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 档案馆的条数小签：赤陶橙 55%、字号同时间戳 12（寻验 09-04）；直跳时同一个色一明一暗闪几秒（原来暗到 12% 显得发白）
struct NoTag: View {
    let t: String
    var flash: Bool
    @State private var dim = false
    init(_ t: String, flash: Bool) { self.t = t; self.flash = flash }
    var body: some View {
        Text(t).font(Theme.round(12)).foregroundColor(Theme.accent.opacity(0.55)).opacity(flash && dim ? 0.3 : 1)
            .onAppear { if flash { withAnimation(.easeInOut(duration: 0.5).repeatCount(8, autoreverses: true)) { dim = true } } }
    }
}

struct AIRowView: View {
    let msg: Msg
    let showUsage: Bool
    var tagNo: String? = nil
    var flash = false
    var highlight = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {   // 照网页：.think 下空 4，.bubble 上下各 11，.metarow 再空 5
            let th = msg.cleanThinking
            if !th.isEmpty {
                ThinkView(text: th, label: msg.thinkSecs.map { "Thought for \(String(format: "%.1f", $0))s" } ?? "Thought")
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                // 照网页 .bubble img.att：克递来的相册照片 200 上限、圆角 12、点开看大图
                ForEach(Array((msg.images ?? []).enumerated()), id: \.offset) { _, u in
                    StreamImage(src: u, maxW: 200, maxH: 200, radius: 12)
                }
                if let c = msg.content, !c.isEmpty {
                    RichText(attr: highlight.isEmpty ? MDWhole.make(c) : ArchiveScreen.highlight(MDWhole.make(c), highlight))
                }
            }
            .padding(.vertical, 11)
            if msg.toolCalls == nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TimeFmt.stamp(msg.ts)).font(Theme.round(12)).foregroundColor(Theme.muted)
                    if let t = tagNo { NoTag(t, flash: flash) }
                    if showUsage, let u = msg.usage, let it = u.inputTokens {
                        (Text(String(it) + " tokens · ").foregroundColor(Theme.muted)   // 拼字符串：Text 插值 Int 会自动加千分逗号（寻：不要逗号）
                         + Text("cache " + String(u.cachedTokens ?? 0)).foregroundColor(Theme.cacheTint))
                            .font(Theme.round(11.5))
                    }
                }
                .padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolChipView: View {
    let name: String
    let done: Bool
    var body: some View {
        Text(name + (done ? " ✓" : ""))
            .font(Theme.round(12.5)).foregroundColor(Theme.muted)
            .padding(.horizontal, 13).padding(.vertical, 4)
            .background(Theme.panel, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 吃吃/睡眠/雨情小纸条（09-03 寻挑的「时间线」款）：不要底色，一行小字、前头一个线图标、两边各一截短线；
/// 图在字下面。多行时把宽度收到「行数不变的最窄」——最后一行不会只剩两三个字（寻问的）。
struct PingChipView: View {
    let msg: Msg
    var forceMeal = false
    private static let font = Theme.round(12.5)
    private static let uiFont: UIFont = {
        let d = UIFont.systemFont(ofSize: 12.5).fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: 12.5).fontDescriptor
        return UIFont(descriptor: d, size: 12.5)
    }()

    private var isMeal: Bool { msg.meal == true || forceMeal }
    private var icon: String { msg.rainNote == true ? "cloud" : (isMeal ? "bowl" : "moon") }

    /// 文案：吃吃「12:40-寻吃了午餐：一碗豆花饭」→「12:40 午餐 · 一碗豆花饭」；雨情去掉自带的 🌧/🌤 头
    private var line: String {
        let raw = (msg.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isMeal, raw.range(of: #"^\d{1,2}:\d{2}-寻吃"#, options: .regularExpression) != nil, let dash = raw.firstIndex(of: "-") {
            let time = String(raw[..<dash])
            var rest = String(raw[raw.index(after: dash)...])      // 寻吃了午餐：… / 寻吃过了：…
            var note = ""
            if let c = rest.firstIndex(of: "：") { note = String(rest[rest.index(after: c)...]); rest = String(rest[..<c]) }
            let kind = rest.hasPrefix("寻吃了") ? String(rest.dropFirst(3)) : "吃过了"
            return time + " " + kind + (note.isEmpty ? "" : " · " + note)
        }
        var s = raw
        while let f = s.unicodeScalars.first, (f.properties.isEmoji && f.value > 0x2000) || f.value == 0xFE0F || f.value == 0x200D || f == " " {
            s.unicodeScalars.removeFirst()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 行数不变的最窄宽度（二分）：字排得均匀，最后一行不孤零零
    private func balancedWidth(_ text: String, max maxW: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.uiFont]
        func lines(_ w: CGFloat) -> Int {
            let h = (text as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).height
            return max(1, Int((h / Self.uiFont.lineHeight).rounded()))
        }
        let n = lines(maxW)
        if n == 1 {   // 一行：就用它本来的宽，短线贴着字
            let w = (text as NSString).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil).width
            return ceil(w) + 1
        }
        var lo = maxW * 0.45, hi = maxW
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if lines(mid) > n { lo = mid } else { hi = mid }
        }
        return ceil(hi) + 1
    }

    var body: some View {
        let text = line
        let maxW = min(UIScreen.main.bounds.width, 430) * 0.88 - 32 - 48 - 23   // 消息区留白、两截短线、图标
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.border).frame(width: 14, height: 1)
                Image(icon).renderingMode(.template).resizable().frame(width: 13, height: 13).foregroundColor(Theme.muted)
                Text(text).font(Self.font).foregroundColor(Theme.muted).multilineTextAlignment(.center)
                    .frame(width: balancedWidth(text, max: maxW))
                Rectangle().fill(Theme.border).frame(width: 14, height: 1)
            }
            .fixedSize()
            if let u = msg.images?.first {   // 照网页 .pingchip img：宽 140 上限、圆角 10、点开看大图
                StreamImage(src: u, maxW: 140, maxH: 420, radius: 10)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct WakeChipView: View {
    let hm: String
    var body: some View {
        VStack(spacing: 2) {
            Text("——··自由时间··——").font(Theme.round(12)).tracking(1.5)
            if !hm.isEmpty { Text(hm).font(Theme.round(11)) }
        }
        .foregroundColor(Theme.muted.opacity(0.85))
        .frame(maxWidth: .infinity)
    }
}

/// 克敲她的话：按空行拆成多条气泡，靠左，淡陶土底。
struct KnockRowView: View {
    let text: String
    let stamp: String
    var body: some View {
        let segs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array((segs.isEmpty ? [text] : segs).enumerated()), id: \.offset) { _, s in
                Text(s).font(Theme.serif(18)).lineSpacing(4).foregroundColor(Theme.knockText)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.knockBg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .textSelection(.enabled)
            }
            if !stamp.isEmpty { Text(stamp).font(Theme.round(11)).foregroundColor(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 56)
    }
}

/// 图：dataURL 直接解，路径拼网关地址。
struct RemoteImage: View {
    let src: String
    var body: some View {
        if src.hasPrefix("data:"), let comma = src.firstIndex(of: ","),
           let data = Data(base64Encoded: String(src[src.index(after: comma)...])), let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFit()
        } else if let url = URL(string: src, relativeTo: Gateway.home) {
            AsyncImage(url: url) { phase in
                if let img = phase.image { img.resizable().scaledToFit() }
                else { Theme.panel }
            }
        } else {
            Theme.panel
        }
    }
}


/// 消息流里的图（她发的、克递的、纸条附图）：先拿到真图再按真实比例装进 maxW×maxH，圆角贴图边、贴右不居中；
/// 点一下全屏看（照网页 openImgView）。dataURL 直接解，/uploads 路径拼网关地址带口令头；解完进缓存不重解。
struct StreamImage: View {
    let src: String
    var maxW: CGFloat = 200
    var maxH: CGFloat = 200
    var radius: CGFloat = 26
    @State private var ui: UIImage?
    init(src: String, maxW: CGFloat = 200, maxH: CGFloat = 200, radius: CGFloat = 26) {
        self.src = src; self.maxW = maxW; self.maxH = maxH; self.radius = radius
        _ui = State(initialValue: StreamImageCache.peek(src: src))   // 缓存里有就第一帧直接画（LazyVStack 滚回来重建行，别闪占位块）
    }
    var body: some View {
        Group {
            if let ui {
                let s = min(maxW / max(ui.size.width, 1), maxH / max(ui.size.height, 1), 1)
                let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
                Image(uiImage: ui).resizable()
                    .frame(width: ui.size.width * s, height: ui.size.height * s)
                    .clipShape(shape).contentShape(shape)
                    .onTapGesture { ImageViewer.shared.image = ui }
            } else {
                Theme.panel.frame(width: min(maxW, 120), height: min(maxH, 90))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
        .task(id: src) {
            if let c = StreamImageCache.peek(src: src) { ui = c; return }
            ui = await StreamImageCache.load(src)
        }
    }
}

enum StreamImageCache {
    private static let cache: NSCache<NSString, UIImage> = { let c = NSCache<NSString, UIImage>(); c.countLimit = 200; return c }()
    static func peek(src: String) -> UIImage? { cache.object(forKey: src as NSString) }
    static func load(_ src: String) async -> UIImage? {
        let ui: UIImage?
        if src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") {
            let b64 = String(src[src.index(after: comma)...])
            ui = await Task.detached(priority: .userInitiated) { Data(base64Encoded: b64).flatMap(UIImage.init(data:)) }.value
        } else if let url = URL(string: src, relativeTo: Gateway.home) {
            var r = URLRequest(url: url)
            if let token = Keychain.token, url.host == Gateway.home.host { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
            ui = UIImage(data: d)
        } else { ui = nil }
        if let ui { cache.setObject(ui, forKey: src as NSString) }
        return ui
    }
}

/// 图片查看器（照网页 #imgView）：黑底 93%、图按原比例装满屏、轻点任意处关、左缘右滑关；捏合缩放同相册的看图。
@MainActor
final class ImageViewer: ObservableObject {
    static let shared = ImageViewer()
    @Published var image: UIImage? = nil
}

struct ImageViewerView: View {
    let image: UIImage
    var onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    var body: some View {
        ZStack {
            Color.black.opacity(0.93).ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(MagnificationGesture().onChanged { v in scale = min(6, max(1, lastScale * v)); if scale == 1 { offset = .zero; lastOffset = .zero } }
                    .onEnded { _ in lastScale = scale })
                .simultaneousGesture(DragGesture().onChanged { v in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + v.translation.width, height: lastOffset.height + v.translation.height)
                }.onEnded { _ in lastOffset = offset })
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) { if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }; lastScale = scale }
                }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { onClose() }
        .background(EdgeSwipe(onBack: onClose))
    }
}

/// dataURL 图按真实比例装进 maxW×maxH 的框里再切圆角（圆角贴着图边，不是贴着框）。
struct DataImage: View {
    let src: String
    var maxW: CGFloat = 200
    var maxH: CGFloat = 200
    var radius: CGFloat = 26
    var body: some View {
        if src.hasPrefix("data:"), let comma = src.firstIndex(of: ","),
           let data = Data(base64Encoded: String(src[src.index(after: comma)...])), let ui = UIImage(data: data) {
            let s = min(maxW / max(ui.size.width, 1), maxH / max(ui.size.height, 1), 1)
            Image(uiImage: ui).resizable()
                .frame(width: ui.size.width * s, height: ui.size.height * s)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            RemoteImage(src: src).frame(maxWidth: maxW, maxHeight: maxH)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
