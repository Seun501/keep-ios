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
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {   // .meta.below margin-top 4
            ForEach(Array(images.enumerated()), id: \.offset) { _, u in
                RemoteImage(src: u).frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RichText(attr: MD.xunNS(text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n\n")))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .textSelection(.enabled)
            }
            if !stamp.isEmpty {
                Text(stamp).font(Theme.round(12)).foregroundColor(Theme.muted)
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
            Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "clock").font(.system(size: 12))
                    Text(label).font(Theme.serif(13))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .foregroundColor(Theme.muted)
            }
            .buttonStyle(.plain)
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

struct AIRowView: View {
    let msg: Msg
    let showUsage: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {   // 照网页：.think 下空 4，.bubble 上下各 11，.metarow 再空 5
            let th = msg.cleanThinking
            if !th.isEmpty {
                ThinkView(text: th, label: msg.thinkSecs.map { "Thought for \(String(format: "%.1f", $0))s" } ?? "Thought")
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array((msg.images ?? []).enumerated()), id: \.offset) { _, u in
                    RemoteImage(src: u).frame(maxWidth: 260, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                if let c = msg.content, !c.isEmpty {
                    RichText(attr: MDWhole.make(c))
                }
            }
            .padding(.vertical, 11)
            if msg.toolCalls == nil {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TimeFmt.stamp(msg.ts)).font(Theme.round(12)).foregroundColor(Theme.muted)
                    if showUsage, let u = msg.usage, let it = u.inputTokens {
                        (Text("\(it) tokens · ").foregroundColor(Theme.muted)
                         + Text("cache \(u.cachedTokens ?? 0)").foregroundColor(Theme.cacheTint))
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

struct PingChipView: View {
    let msg: Msg
    var forceMeal = false
    var body: some View {
        VStack(spacing: 6) {
            if let u = msg.images?.first {
                RemoteImage(src: u).frame(maxWidth: 140, maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text((msg.rainNote == true ? "" : ((msg.meal == true || forceMeal) ? "🍚 " : "🌙 ")) + (msg.content ?? ""))
                .font(Theme.round(12.5)).foregroundColor(Theme.muted).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
