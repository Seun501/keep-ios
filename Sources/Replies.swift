import SwiftUI

/// 克的「选项卡」（09-13 寻与克定的）：他在回复里写 [reply: 甲 | 乙 | 丙]，App 把这一段从正文里摘出来画成可点的选项；
/// 点一个＝把那句当她的消息发出去。正史里存的是他的原文（网关不动；他回看自己的话、档案馆重排都还认得）。
/// 冒号、竖线全角半角都认；空项、重复项剔掉；一条里写了几段都收进同一排。
enum Replies {
    final class Parsed { let text: String; let options: [String]; init(_ t: String, _ o: [String]) { text = t; options = o } }
    private static let re = try! NSRegularExpression(pattern: #"\[\s*reply\s*[:：]([^\[\]]*)\]"#, options: [.caseInsensitive])
    private static let cache: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 400; return c }()

    static func split(_ s: String) -> Parsed {
        if let c = cache.object(forKey: s as NSString) { return c }
        let ns = s as NSString
        var options: [String] = []
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            for part in ns.substring(with: m.range(at: 1)).components(separatedBy: CharacterSet(charactersIn: "|｜")) {
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !options.contains(t) { options.append(t) }
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        let p = Parsed(options.isEmpty ? s : out.trimmingCharacters(in: .whitespacesAndNewlines), options)
        cache.setObject(p, forKey: s as NSString)
        return p
    }
    /// 流式：尾巴上刚开了个 [reply: 还没闭合——先藏起来，别把半截格式打在屏上
    static func hidePartial(_ s: String) -> String {
        guard let r = s.range(of: #"\[\s*reply\s*[:：]?[^\]]*$"#, options: [.regularExpression, .caseInsensitive]) else { return s }
        return String(s[..<r.lowerBound])
    }
}

/// 选项那一排：照她的气泡裁小一号（同底色、同字、圆角 20），短的并排、长的自己折行；
/// 末尾一格「自己说…」＝一个都不选，把焦点给输入框（寻定：这一格必须留）。
/// active＝false（档案馆、聊天里已经回过的旧条）：只看不点、淡一档，留个「他当时给过什么」的痕迹。
struct ReplyChips: View {
    let options: [String]
    var active = true
    var onPick: (String) -> Void = { _ in }
    var onOwn: () -> Void = {}
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                chip(o, fg: Theme.text)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .onTapGesture { if active { onPick(o) } }
            }
            if active {
                chip("自己说…", fg: Theme.muted).contentShape(Rectangle()).onTapGesture { onOwn() }
            }
        }
        .opacity(active ? 1 : 0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chip(_ s: String, fg: Color) -> some View {
        Text(s).font(Font(Theme.uiUser(15))).lineSpacing(3).foregroundColor(fg)
            .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 从左到右排、放不下换行（iOS 16 的 Layout）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? (UIScreen.main.bounds.width - 32), subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(bounds.width, subviews)
        for (i, p) in a.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: ProposedViewSize(a.sizes[i]))
        }
    }
    private func arrange(_ maxW: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint], sizes: [CGSize]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        var pts: [CGPoint] = [], sizes: [CGSize] = []
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            if x > 0, x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y)); sizes.append(sz)
            x += sz.width + spacing; rowH = max(rowH, sz.height); w = max(w, x - spacing)
        }
        return (CGSize(width: w, height: y + rowH), pts, sizes)
    }
}
