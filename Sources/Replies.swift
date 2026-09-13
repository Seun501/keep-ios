import SwiftUI

/// 克的「选项卡」（09-13 寻与克定的）：他在回复**最末尾**写 [reply: 甲 | 乙 | 丙]，App 把这一段从正文里摘出来画成可点的选项；
/// 点一个＝把那句当她的消息发出去。正史里存的是他的原文（网关不动；他回看自己的话、档案馆重排都还认得）。
/// 只认收尾那一段（寻 09-13：正文中间出现的可能只是在和她聊这个格式，不算）；冒号、竖线全角半角都认；空项、重复项剔掉。
enum Replies {
    final class Parsed { let text: String; let options: [String]; init(_ t: String, _ o: [String]) { text = t; options = o } }
    private static let re = try! NSRegularExpression(pattern: #"\[\s*reply\s*[:：]([^\[\]]*)\]\s*$"#, options: [.caseInsensitive])
    private static let cache: NSCache<NSString, Parsed> = { let c = NSCache<NSString, Parsed>(); c.countLimit = 400; return c }()

    static func split(_ s: String) -> Parsed {
        if let c = cache.object(forKey: s as NSString) { return c }
        let ns = s as NSString
        var options: [String] = []
        var text = s
        if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
            for part in ns.substring(with: m.range(at: 1)).components(separatedBy: CharacterSet(charactersIn: "|｜")) {
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !options.contains(t) { options.append(t) }
            }
            if !options.isEmpty { text = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let p = Parsed(text, options)
        cache.setObject(p, forKey: s as NSString)
        return p
    }
    /// 流式：尾巴上刚开了个 [reply: 还没闭合——先藏起来，别把半截格式打在屏上
    static func hidePartial(_ s: String) -> String {
        guard let r = s.range(of: #"\[\s*reply\s*[:：]?[^\]]*$"#, options: [.regularExpression, .caseInsensitive]) else { return s }
        return String(s[..<r.lowerBound])
    }
}

/// 选项卡（09-13 寻定：照 claude.ai 那种，从输入卡上方长出来，和输入框是同一张卡）：
/// 一行一个选项——序号 A/B/C 坐在半透明赤陶的小圆上（寻 09-13 三稿：圆底用我们本来的橙，行本身不铺底、不画分隔线）、
/// 克的宋体字、右端细箭头；没有标题没有×，底下就是原来的输入行（占位照旧）——不选就直接打字。点一项＝那句当她的消息发出去。
struct ReplyCard: View {
    let options: [String]
    var onPick: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                HStack(alignment: .center, spacing: 12) {
                    // 序号：Cascadia、她气泡的底色、不带橙（寻 09-13 四稿）
                    Text(Self.mark(i)).font(Theme.mono(12.5, weight: .medium)).foregroundColor(Theme.text)
                        .frame(width: 26, height: 26).background(Theme.userBubble, in: Circle())
                    Text(o).font(Theme.serif(16)).lineSpacing(3).foregroundColor(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image("chev").renderingMode(.template).resizable().frame(width: 13, height: 13).rotationEffect(.degrees(-90))
                        .foregroundColor(Theme.muted.opacity(0.7))
                }
                .padding(.horizontal, 2).padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { onPick(o) }
            }
        }
        .padding(.top, -4).padding(.bottom, 4)
    }
    /// A、B、C…；超过 26 个用数字
    static func mark(_ i: Int) -> String { i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : String(i + 1) }
}

/// 他的话下面淡掉的一排（聊天里回过的旧条、档案馆）：只看不点，留个「他当时给过什么」的痕迹
struct ReplyChips: View {
    let options: [String]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                Text(o).font(Font(Theme.uiUser(15))).lineSpacing(3).foregroundColor(Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .opacity(0.55)
        .frame(maxWidth: .infinity, alignment: .leading)
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
