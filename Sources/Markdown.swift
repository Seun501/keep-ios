import SwiftUI

/// 极简 Markdown，块级规则照网页 renderMarkdown：围栏代码、#标题、>引用、-/* 列表、1. 列表（带原序号）、表格、段落。
/// 行内交给系统（**粗体** *斜体* `代码` ~~删除线~~），只做行内、保留空白。
enum MD {
    enum Block: Identifiable {
        case para([String])                 // 行，段内换行照排
        case heading(Int, String)
        case code(String)
        case quote([String])
        case ul([String])
        case ol([(Int, String)])
        case table(head: [String], rows: [[String]])
        var id: String { UUID().uuidString }
    }

    static func inline(_ s: String) -> AttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    /// 行内 markdown → 逐段落字：SwiftUI 对自定义字体不会自己把 **粗体** 换字重（构建 13 寻验「没渲染」），
    /// 这里按 intent 显式给每段配字：正文 base，粗体升档，代码等宽，删除线画线。
    static func styled(_ s: String, base: UIFont, bold: UIFont, mono: UIFont, color: Color) -> AttributedString {
        var a = inline(s)
        a.font = base
        a.foregroundColor = color
        for run in a.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let r = run.range
            if intent.contains(.stronglyEmphasized) { a[r].font = bold }
            if intent.contains(.code) { a[r].font = mono }
            if intent.contains(.strikethrough) { a[r].strikethroughStyle = .single; a[r].foregroundColor = color.opacity(0.65) }
        }
        return a
    }
    /// 同上，但产出 NSAttributedString 给 UITextView（粗体/代码/删除线原生生效；精确选字）。lineHeight＝网页 line-height 倍数。
    /// 行内规则照网页 mdInline 那四条正则（`代码`、**粗**、~~紧贴删除线~~、*斜*），逐段落字。
    static func ns(_ s: String, base: UIFont, bold: UIFont, mono: UIFont, italic: UIFont? = nil, color: UIColor, lineHeight: CGFloat, paraSpacing: CGFloat = 0, cjkLineHeight: CGFloat? = nil) -> NSAttributedString {
        struct Run { var text: String; var kind: Character }   // kind: n/c/b/d/e
        var runs: [Run] = []
        let pats: [(String, Character)] = [
            ("`([^`]+)`", "c"),
            ("\\*\\*([^*]+)\\*\\*", "b"),
            ("~~(?=\\S)([^~\\n]*?\\S)~~", "d"),
            ("(?<![*])\\*([^*]+)\\*", "e"),
        ]
        func split(_ t: String, _ pi: Int) -> [Run] {
            if pi >= pats.count { return [Run(text: t, kind: "n")] }
            guard let re = try? NSRegularExpression(pattern: pats[pi].0) else { return split(t, pi + 1) }
            var out: [Run] = []; var last = 0
            let ns = t as NSString
            for mt in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                if mt.range.location > last { out += split(ns.substring(with: NSRange(location: last, length: mt.range.location - last)), pi + 1) }
                out.append(Run(text: ns.substring(with: mt.range(at: 1)), kind: pats[pi].1))
                last = mt.range.location + mt.range.length
            }
            if last < ns.length { out += split(ns.substring(from: last), pi + 1) }
            return out
        }
        runs = split(s, 0)
        let m = NSMutableAttributedString()
        let para = NSMutableParagraphStyle()
        // 行框固定＝网页 line-height（用 lineSpacing 补的那版首行中文顶被吞、行距忽宽忽窄——寻验 43：
        // 中文回落字体比拉丁基字高，行框按基字算就装不下）。固定行框里字会沉到底，用 baselineOffset 抬回正中。
        let natural = max(base.lineHeight, cjkLineHeight ?? 0)
        let lh = base.pointSize * lineHeight
        para.minimumLineHeight = lh
        para.maximumLineHeight = lh
        para.paragraphSpacing = paraSpacing
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color, .paragraphStyle: para,
                                                        .baselineOffset: max(0, (lh - natural) / 2)]
        for r in runs {
            var at = baseAttrs
            switch r.kind {
            case "b": at[.font] = bold
            case "c": at[.font] = mono
            case "d": at[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; at[.foregroundColor] = color.withAlphaComponent(0.65)
            case "e": if let italic { at[.font] = italic } else { at[.obliqueness] = 0.18 }   // 照她给的网页/App 对比截图折中（0.24 过了）
            default: break
            }
            m.append(NSAttributedString(string: r.text, attributes: at))
        }
        return m
    }
    /// 粗体用 600：网页自托管的思源宋体只有 400/500/600，**粗** 在网页上落到 600（寻验 36 对比图：App 的 700 太重）
    static func keNS(_ s: String, size: CGFloat = 18, weight: Font.Weight = .medium, color: UIColor = Theme.uiText, lineHeight: CGFloat = 1.6) -> NSAttributedString {
        ns(s, base: Theme.uiSerif(size, weight: weight), bold: Theme.uiSerif(size, weight: .semibold),
           mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: color, lineHeight: lineHeight,
           cjkLineHeight: Theme.uiCJK(size, weight: weight).lineHeight)
    }
    /// 寻的气泡与输入框：网页 body 那套字（Lora → 宋体 Songti SC，常规），18/1.5，段间 8（照网页 .user .bubble p{margin:8px 0}）
    private static let xunCache: NSCache<NSString, NSAttributedString> = { let c = NSCache<NSString, NSAttributedString>(); c.countLimit = 400; return c }()
    static func xunNS(_ s: String, size: CGFloat = 18) -> NSAttributedString {
        let key = "\(size)|\(s)" as NSString
        if let c = xunCache.object(forKey: key) { return c }
        let r = ns(s, base: Theme.uiUser(size), bold: Theme.uiUser(size, bold: true),
           mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular),
           color: Theme.uiText, lineHeight: 1.5, paraSpacing: 8, cjkLineHeight: Theme.uiSongti(size).lineHeight)
        xunCache.setObject(r, forKey: key)
        return r
    }
    static func ke(_ s: String, size: CGFloat = 18, weight: Font.Weight = .medium) -> AttributedString {
        styled(s, base: Theme.uiSerif(size, weight: weight), bold: Theme.uiSerif(size, weight: .bold),
               mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: Theme.text)
    }
    static func xun(_ s: String, size: CGFloat = 17) -> AttributedString {
        styled(s, base: UIFont.systemFont(ofSize: size), bold: UIFont.systemFont(ofSize: size, weight: .semibold),
               mono: UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular), color: Theme.text)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [String] = []
        var t = text
        // 围栏代码先抠出去
        while let r = t.range(of: "```") {
            guard let r2 = t.range(of: "```", range: r.upperBound..<t.endIndex) else { break }
            var code = String(t[r.upperBound..<r2.lowerBound])
            if code.hasPrefix("\n") { code.removeFirst() }
            if code.hasSuffix("\n") { code.removeLast() }
            blocks.append(code)
            t.replaceSubrange(r.lowerBound..<r2.upperBound, with: "\u{0}\(blocks.count - 1)\u{0}")
        }
        let lines = t.components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        func isTable(_ idx: Int) -> Bool {
            guard idx + 1 < lines.count, lines[idx].contains("|") else { return false }
            let sep = lines[idx + 1]
            return sep.contains("-") && sep.contains("|") && sep.allSatisfy { " |:-".contains($0) }
        }
        func codeIndex(_ line: String) -> Int? {
            guard line.hasPrefix("\u{0}"), line.hasSuffix("\u{0}"), line.count >= 3 else { return nil }
            return Int(line.dropFirst().dropLast())
        }
        func heading(_ line: String) -> (Int, String)? {
            var n = 0; var idx = line.startIndex
            while idx < line.endIndex, line[idx] == "#" { n += 1; idx = line.index(after: idx) }
            guard n >= 1, n <= 6, idx < line.endIndex, line[idx] == " " else { return nil }
            return (n, String(line[idx...]).trimmingCharacters(in: .whitespaces))
        }
        func olItem(_ line: String) -> (Int, String)? {
            guard let dot = line.firstIndex(of: "."), let n = Int(line[..<dot]),
                  line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " else { return nil }
            return (n, String(line[line.index(dot, offsetBy: 2)...]))
        }
        func ulItem(_ line: String) -> String? {
            (line.hasPrefix("- ") || line.hasPrefix("* ")) ? String(line.dropFirst(2)) : nil
        }
        func quoteLine(_ line: String) -> String? {
            guard line.hasPrefix(">") else { return nil }
            var s = String(line.dropFirst()); if s.hasPrefix(" ") { s.removeFirst() }; return s
        }
        func isSpecial(_ idx: Int) -> Bool {
            let l = lines[idx]
            return codeIndex(l) != nil || heading(l) != nil || quoteLine(l) != nil || ulItem(l) != nil || olItem(l) != nil || isTable(idx)
        }
        func cells(_ row: String) -> [String] {
            var r = row.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("|") { r.removeFirst() }
            if r.hasSuffix("|") { r.removeLast() }
            return r.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let line = lines[i]
            if let ci = codeIndex(line), ci < blocks.count { out.append(.code(blocks[ci])); i += 1; continue }
            if let (lv, s) = heading(line) { out.append(.heading(lv, s)); i += 1; continue }
            if quoteLine(line) != nil {
                var q: [String] = []
                while i < lines.count, let s = quoteLine(lines[i]) { q.append(s); i += 1 }
                out.append(.quote(q)); continue
            }
            if ulItem(line) != nil {
                var it: [String] = []
                while i < lines.count, let s = ulItem(lines[i]) { it.append(s); i += 1 }
                out.append(.ul(it)); continue
            }
            if olItem(line) != nil {
                var it: [(Int, String)] = []
                while i < lines.count, let s = olItem(lines[i]) { it.append(s); i += 1 }
                out.append(.ol(it)); continue
            }
            if isTable(i) {
                let head = cells(lines[i]); i += 2
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i])); i += 1
                }
                out.append(.table(head: head, rows: rows)); continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            var para: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !isSpecial(i) {
                para.append(lines[i]); i += 1
            }
            out.append(.para(para))
        }
        return out
    }
}

/// 克的正文。
struct MarkdownView: View {
    let text: String
    var body: some View {
        let blocks = MD.parse(text)
        VStack(alignment: .leading, spacing: 16) {   // .ai .bubble p { margin: 16px 0 }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                block(b)
            }
        }
    }

    @ViewBuilder private func block(_ b: MD.Block) -> some View {
        switch b {
        case .para(let lines):
            RichText(attr: MD.keNS(lines.joined(separator: "\n")))
        case .heading(let lv, let s):
            RichText(attr: MD.keNS(s, size: lv <= 2 ? 21 : 18.5, weight: .semibold, lineHeight: 1.35))
        case .code(let c):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c).font(.system(size: 13.5, design: .monospaced)).foregroundColor(Theme.text)
                    .padding(10)
            }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .quote(let q):
            HStack(alignment: .top, spacing: 12) {
                Rectangle().fill(Theme.border).frame(width: 3)
                RichText(attr: MD.keNS(q.joined(separator: "\n"), color: Theme.uiMuted))
            }
        case .ul(let items):   // 网页 ul/ol：padding-left 2em、li 间 3
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Theme.serif(18, weight: .medium)).foregroundColor(Theme.muted).frame(width: 22, alignment: .trailing)
                        RichText(attr: MD.keNS(s))
                    }
                }
            }
        case .ol(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(it.0).").font(Theme.serif(18, weight: .medium)).foregroundColor(Theme.muted).frame(width: 22, alignment: .trailing)
                        RichText(attr: MD.keNS(it.1))
                    }
                }
            }
        case .table(let head, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) { ForEach(Array(head.enumerated()), id: \.offset) { _, c in
                        Text(MD.ke(c, size: 15, weight: .semibold)) } }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 14) { ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            Text(MD.ke(c, size: 15)) } }
                    }
                }
            }
        }
    }

    private func joined(_ lines: [String]) -> AttributedString {
        var out = AttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(AttributedString("\n")) }
            out.append(MD.ke(l))
        }
        return out
    }
}

/// 寻的气泡：每个换行即独立段落（仿 A 社），行内 markdown，#标题也认。
struct UserTextView: View {
    let text: String
    var body: some View {
        let paras = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                RichText(attr: MD.xunNS(p))   // 寻定：她的气泡用系统默认；18/1.5 照网页
            }
        }
    }
}


/// 系统文本视图承载富文本：粗体/代码/删除线是真的，长按能精确选字复制（SwiftUI 的 Text 只能整段复制）。
struct RichText: UIViewRepresentable {
    let attr: NSAttributedString
    var maxLines = 0          // >0＝最多几行、尾部省略（留言卡两行预览）
    func makeUIView(context: Context) -> UITextView {
        // TextKit 1：*斜体* 靠 .obliqueness 倾斜，TextKit 2 直接无视它（寻验 28「完全不渲染」——星号吃了、字没斜）
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false; tv.isSelectable = maxLines == 0; tv.isScrollEnabled = false
        // 长按选字老是没选上（寻 09-05）：系统长按要按满 0.5 秒，手指稍一动外面的滚动区就把手势抢走；把 UITextView 自带的长按缩到 0.3 秒
        for g in tv.gestureRecognizers ?? [] { if let lp = g as? UILongPressGestureRecognizer, lp.minimumPressDuration > 0.3 { lp.minimumPressDuration = 0.3 } }
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero; tv.textContainer.lineFragmentPadding = 0
        if maxLines > 0 { tv.textContainer.maximumNumberOfLines = maxLines; tv.textContainer.lineBreakMode = .byTruncatingTail; tv.isUserInteractionEnabled = false }
        tv.dataDetectorTypes = [.link]
        tv.linkTextAttributes = [.foregroundColor: Theme.uiScrollTint]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        if !tv.attributedText.isEqual(to: attr) { tv.attributedText = attr; context.coordinator.cache = nil }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var cache: (w: CGFloat, size: CGSize)? = nil }
    /// 键盘让位/滚动区改帧时 SwiftUI 每帧都来问尺寸——同宽同文就直接给上次算的（寻验 39：收键盘卡顿）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let maxW = proposal.width ?? (UIScreen.main.bounds.width - 32)
        if let c = context.coordinator.cache, abs(c.w - maxW) < 0.5 { return c.size }
        // 按内容量宽：短句就窄气泡（寻验：全部撑满一样长了）
        let r = attr.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let w = min(maxW, ceil(r.width) + 1)
        let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let size = CGSize(width: w, height: h)
        context.coordinator.cache = (maxW, size)
        return size
    }
}


/// 克的整条正文合成一个 NSAttributedString：段落/标题/引用/列表/代码块全在一个文本视图里 → 能跨段精确选字复制。
/// 块级规则与间距照网页：p 间 16、li 间 3、ul/ol 左缩 2em、引用左线 3px 灰、代码块等宽淡底、标题加大加粗。
enum MDWhole {
    private static let cache: NSCache<NSString, NSAttributedString> = { let c = NSCache<NSString, NSAttributedString>(); c.countLimit = 400; return c }()
    /// 每次重绘都会来要（滚动阈值、流式每帧……），同文同号直接给缓存的（寻验 39：卡）
    static func make(_ text: String, size: CGFloat = 18) -> NSAttributedString {
        let key = "\(size)|\(text)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let r = build(text, size: size)
        cache.setObject(r, forKey: key)
        return r
    }
    private static func build(_ text: String, size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = MD.parse(text)
        func para(_ ns: NSAttributedString, before: CGFloat, after: CGFloat, indent: CGFloat = 0, head: CGFloat = 0) {
            let m = NSMutableAttributedString(attributedString: ns)
            m.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: m.length)) { v, r, _ in
                let p = (v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                p.paragraphSpacingBefore = before; p.paragraphSpacing = after
                p.headIndent = indent; p.firstLineHeadIndent = head
                m.addAttribute(.paragraphStyle, value: p, range: r)
            }
            out.append(m)
        }
        for (i, b) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            let last = i == blocks.count - 1
            switch b {
            case .para(let lines):
                para(MD.keNS(lines.joined(separator: "\n"), size: size), before: 0, after: last ? 0 : 16)
            case .heading(let lv, let t):
                para(MD.keNS(t, size: lv <= 2 ? size + 3 : size + 0.5, weight: .semibold, lineHeight: 1.35), before: 0, after: last ? 0 : 10)
            case .quote(let q):
                let ns = MD.keNS(q.joined(separator: "\n"), size: size, color: Theme.uiMuted)
                para(ns, before: 0, after: last ? 0 : 16, indent: 15, head: 15)
            case .ul(let items):
                for (k, it) in items.enumerated() {
                    let ns = NSMutableAttributedString(attributedString: MD.keNS("•\t" + it, size: size))
                    let p = NSMutableParagraphStyle(); p.tabStops = [NSTextTab(textAlignment: .left, location: 2 * size)]
                    p.headIndent = 2 * size; p.firstLineHeadIndent = 0.9 * size
                    p.minimumLineHeight = size * 1.6; p.maximumLineHeight = size * 1.6
                    p.paragraphSpacing = (k == items.count - 1 && !last) ? 16 : 3
                    ns.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: ns.length))
                    out.append(ns); if k < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
                }
            case .ol(let items):
                for (k, it) in items.enumerated() {
                    let ns = NSMutableAttributedString(attributedString: MD.keNS("\(it.0).\t" + it.1, size: size))
                    let p = NSMutableParagraphStyle(); p.tabStops = [NSTextTab(textAlignment: .left, location: 2 * size)]
                    p.headIndent = 2 * size; p.firstLineHeadIndent = 0.6 * size
                    p.minimumLineHeight = size * 1.6; p.maximumLineHeight = size * 1.6
                    p.paragraphSpacing = (k == items.count - 1 && !last) ? 16 : 3
                    ns.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: ns.length))
                    out.append(ns); if k < items.count - 1 { out.append(NSAttributedString(string: "\n")) }
                }
            case .code(let c):
                let p = NSMutableParagraphStyle(); p.paragraphSpacing = last ? 0 : 16; p.headIndent = 10; p.firstLineHeadIndent = 10
                out.append(NSAttributedString(string: c, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular), .foregroundColor: Theme.uiText,
                    .backgroundColor: Theme.uiDyn(0xF2EDE3, 0x2A2A27), .paragraphStyle: p]))
            case .table(let head, let rows):
                var lines = [head.joined(separator: "  |  ")]
                for r in rows { lines.append(r.joined(separator: "  |  ")) }
                para(MD.keNS(lines.joined(separator: "\n"), size: 15), before: 0, after: last ? 0 : 16)
            }
        }
        return out
    }
}
