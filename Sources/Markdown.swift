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
           mono: Theme.uiMono(size * 0.86, weight: .regular), color: color, lineHeight: lineHeight,
           cjkLineHeight: Theme.uiCJK(size, weight: weight).lineHeight)
    }
    /// 寻的气泡与输入框：网页 body 那套字（Lora → 宋体 Songti SC，常规），18/1.5，段间 8（照网页 .user .bubble p{margin:8px 0}）
    private static let xunCache: NSCache<NSString, NSAttributedString> = { let c = NSCache<NSString, NSAttributedString>(); c.countLimit = 400; return c }()
    static func xunNS(_ s: String, size: CGFloat = 18) -> NSAttributedString {
        let key = "\(size)|\(s)" as NSString
        if let c = xunCache.object(forKey: key) { return c }
        // 09-21 寻报「我的气泡不认标题」：照网页 renderUserText——每行独立，`# 标题` 那行加大加粗
        // （.user .bubble h1 1.3em / h2 1.18 / h3 1.06 / h4 1 / h5 .92 / h6 .85 灰，650 字重，下空 6）
        let out = NSMutableAttributedString()
        for (i, line) in s.components(separatedBy: "\n").enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            if let (lv, t) = userHeading(line) {
                let hs = size * [1.3, 1.18, 1.06, 1.0, 0.92, 0.85][lv - 1]
                out.append(ns(t, base: Theme.uiUser(hs, bold: true), bold: Theme.uiUser(hs, bold: true),
                              mono: Theme.uiMono(hs * 0.86, weight: .semibold),
                              color: lv == 6 ? Theme.uiMuted : Theme.uiText, lineHeight: 1.35, paraSpacing: 6,
                              cjkLineHeight: Theme.uiSongti(hs, bold: true).lineHeight))
            } else {
                out.append(ns(line, base: Theme.uiUser(size), bold: Theme.uiUser(size, bold: true),
                              mono: Theme.uiMono(size * 0.86, weight: .regular),
                              color: Theme.uiText, lineHeight: 1.5, paraSpacing: 8, cjkLineHeight: Theme.uiSongti(size).lineHeight))
            }
        }
        xunCache.setObject(out, forKey: key)
        return out
    }
    private static func userHeading(_ line: String) -> (Int, String)? {
        var n = 0; var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#" { n += 1; idx = line.index(after: idx) }
        guard n >= 1, n <= 6, idx < line.endIndex, line[idx] == " " || line[idx] == "\t" else { return nil }
        let t = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (n, t)
    }
    static func ke(_ s: String, size: CGFloat = 18, weight: Font.Weight = .medium) -> AttributedString {
        styled(s, base: Theme.uiSerif(size, weight: weight), bold: Theme.uiSerif(size, weight: .bold),
               mono: Theme.uiMono(size * 0.86, weight: .regular), color: Theme.text)
    }
    static func xun(_ s: String, size: CGFloat = 17) -> AttributedString {
        styled(s, base: Theme.uiSys(size), bold: Theme.uiSys(size, weight: .semibold),
               mono: Theme.uiMono(size * 0.86, weight: .regular), color: Theme.text)
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
        // 09-21 寻报「克发列表渲染不出」：之前只认「- 」「1. 」顶格＋单个空格；照网页 `^[-*]\s+`/`^\d+\.\s+` 放宽成任意空白，
        // 另外多认前头带缩进的子项（克常在「1. 」底下缩两格写「- 」，网页也不认、App 至少要把它当列表画出来）。
        func heading(_ line: String) -> (Int, String)? {
            var n = 0; var idx = line.startIndex
            while idx < line.endIndex, line[idx] == "#" { n += 1; idx = line.index(after: idx) }
            guard n >= 1, n <= 6, idx < line.endIndex, line[idx] == " " || line[idx] == "\t" else { return nil }
            return (n, String(line[idx...]).trimmingCharacters(in: .whitespaces))
        }
        // 全程用 Substring：下标是共用原串的，一转成 String 下标就错位（sim-295：缩进的子项没认出来）
        func afterMarker(_ line: Substring, _ end: Substring.Index) -> String? {   // 记号后至少一个空白，取其后的正文
            guard end < line.endIndex, line[end] == " " || line[end] == "\t" else { return nil }
            var s = line[end...]; while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
            return String(s)
        }
        func olItem(_ line: String) -> (Int, String)? {
            let l = line.drop { $0 == " " || $0 == "\t" }
            guard let dot = l.firstIndex(of: "."), let n = Int(l[..<dot]), let s = afterMarker(l, l.index(after: dot)) else { return nil }
            return (n, s)
        }
        func ulItem(_ line: String) -> String? {
            let l = line.drop { $0 == " " || $0 == "\t" }
            guard let f = l.first, f == "-" || f == "*" else { return nil }
            return afterMarker(l, l.index(after: l.startIndex))
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
                Text(c).font(Theme.mono(13.5)).foregroundColor(Theme.text)
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
    /// 直播段（09-15）：打字机每帧都换一遍文本，链接探测＋按内容量宽这两道每帧各扫一遍全文，字一长主线程就掉帧
    /// （寻 09-13/09-15 反复报：克在回的时候收键盘、消息流下降慢；kb-hide 仪表最大空帧 450ms）。直播段一律撑满宽、不探链接，落成正史再照常
    var live = false
    func makeUIView(context: Context) -> UITextView {
        // TextKit 1：*斜体* 靠 .obliqueness 倾斜，TextKit 2 直接无视它（寻验 28「完全不渲染」——星号吃了、字没斜）
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false; tv.isSelectable = maxLines == 0; tv.isScrollEnabled = false
        // 长按选字老是没选上（寻 09-05，缩系统长按到 0.3s 没用）：自己挂一只 0.3s 长按——按到就选中手指下那个词、震一下、弹复制菜单，
        // 系统自带的那几只长按都让给它（要它失败才跑），网页 WebKit 的长按就是这个手感；选中后拉柄照旧能拖
        if tv.isSelectable {
            let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
            lp.minimumPressDuration = 0.3
            for g in tv.gestureRecognizers ?? [] where g is UILongPressGestureRecognizer { g.require(toFail: lp) }
            tv.addGestureRecognizer(lp)
        }
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero; tv.textContainer.lineFragmentPadding = 0
        if maxLines > 0 { tv.textContainer.maximumNumberOfLines = maxLines; tv.textContainer.lineBreakMode = .byTruncatingTail; tv.isUserInteractionEnabled = false }
        tv.dataDetectorTypes = live ? [] : [.link]
        tv.linkTextAttributes = [.foregroundColor: Theme.uiScrollTint]
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }
    func updateUIView(_ tv: UITextView, context: Context) {
        if !tv.attributedText.isEqual(to: attr) { tv.attributedText = attr; context.coordinator.cache = nil }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject {
        var cache: (w: CGFloat, size: CGSize)? = nil
        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let tv = g.view as? UITextView else { return }
            let pt = g.location(in: tv)
            guard let pos = tv.closestPosition(to: pt) else { return }
            let tk = tv.tokenizer
            let range = tk.rangeEnclosingPosition(pos, with: .word, inDirection: UITextDirection.storage(.backward))
                ?? tk.rangeEnclosingPosition(pos, with: .word, inDirection: UITextDirection.storage(.forward))
                ?? tk.rangeEnclosingPosition(pos, with: .character, inDirection: UITextDirection.storage(.forward))
            guard let range else { return }
            if !tv.isFirstResponder { tv.becomeFirstResponder() }
            tv.selectedTextRange = range
            UISelectionFeedbackGenerator().selectionChanged()
            if let emi = tv.interactions.first(where: { $0 is UIEditMenuInteraction }) as? UIEditMenuInteraction {
                emi.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: pt))
            }
        }
    }
    /// 键盘让位/滚动区改帧时 SwiftUI 每帧都来问尺寸——同宽同文就直接给上次算的（寻验 39：收键盘卡顿）
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let maxW = proposal.width ?? (UIScreen.main.bounds.width - 32)
        if let c = context.coordinator.cache, abs(c.w - maxW) < 0.5 { return c.size }
        // 按内容量宽：短句就窄气泡（寻验：全部撑满一样长了）；直播段省掉这一遍量宽
        let w: CGFloat
        if live { w = maxW } else {
            let r = attr.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            w = min(maxW, ceil(r.width) + 1)
        }
        let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let size = CGSize(width: w, height: h)
        context.coordinator.cache = (maxW, size)
        return size
    }
}


/// 克的正文（09-21 寻：表格要像平时看到的 md 表格）：没有表格＝整条一份富文本（MDWhole，能跨段选字）；
/// 有表格＝表格前后各一份富文本、表格本身画成格子（MDTable）。直播段也走这里。
struct KeMarkdown: View {
    let text: String
    var highlight = ""
    var live = false
    var body: some View {
        let blocks = MD.parse(text)
        if !blocks.contains(where: { if case .table = $0 { return true }; return false }) {
            rich(MDWhole.make(text))
        } else {
            VStack(alignment: .leading, spacing: 10) {   // 网页 table margin 10
                ForEach(Array(MDWhole.groups(blocks).enumerated()), id: \.offset) { gi, g in
                    switch g {
                    case .text(let bs): rich(MDWhole.make(blocks: bs, key: "\(text)|\(gi)"))
                    case .table(let h, let r): MDTable(head: h, rows: r)
                    }
                }
            }
        }
    }
    private func rich(_ a: NSAttributedString) -> some View {
        RichText(attr: highlight.isEmpty ? a : ArchiveScreen.highlight(a, highlight), live: live)
    }
}

/// md 表格（照网页 .ai .bubble table：14px、格线 1px --border、格内 6/10、表头 --think-bg 底 600 字重；宽了横向滚）
struct MDTable: View {
    let head: [String]
    let rows: [[String]]
    private var cols: Int { max(head.count, rows.map(\.count).max() ?? 0) }
    private var widths: [CGFloat] {
        let all = [head] + rows
        return (0..<cols).map { c in
            var w: CGFloat = 0
            for r in all where c < r.count { w = max(w, MD.keNS(r[c], size: 15, weight: .semibold, lineHeight: 1.4).size().width) }
            return min(220, ceil(w) + 20)   // 超过 220 的格子在格内折行
        }
    }
    var body: some View {
        let ws = widths
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                row(head, ws, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Theme.border).frame(height: 1)
                    row(r, ws, header: false)
                }
            }
            .overlay(Rectangle().stroke(Theme.border, lineWidth: 1))
            .padding(1)
        }
    }
    private func row(_ r: [String], _ ws: [CGFloat], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { c in
                if c > 0 { Rectangle().fill(Theme.border).frame(width: 1) }
                Text(MD.ke(c < r.count ? r[c] : "", size: 15, weight: header ? .semibold : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    .frame(width: ws[c], alignment: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(header ? Theme.text.opacity(0.05) : Color.clear)   // 网页 --think-bg: rgba(48,45,39,.05)
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
        let r = build(MD.parse(text), size: size)
        cache.setObject(r, forKey: key)
        return r
    }
    /// 一段不含表格的块（KeMarkdown 把表格前后的块各合成一份）；key 由调用方给（原文＋段序），同样走缓存
    static func make(blocks: [MD.Block], key: String, size: CGFloat = 18) -> NSAttributedString {
        let k = "\(size)|g|\(key)" as NSString
        if let c = cache.object(forKey: k) { return c }
        let r = build(blocks, size: size)
        cache.setObject(r, forKey: k)
        return r
    }
    /// 表格前后拆段：表格自己是一张 SwiftUI 格子（画线、表头底色），其余块照旧合成一份富文本
    enum Group { case text([MD.Block]); case table(head: [String], rows: [[String]]) }
    static func groups(_ blocks: [MD.Block]) -> [Group] {
        var out: [Group] = []; var run: [MD.Block] = []
        for b in blocks {
            if case .table(let h, let r) = b {
                if !run.isEmpty { out.append(.text(run)); run = [] }
                out.append(.table(head: h, rows: r))
            } else { run.append(b) }
        }
        if !run.isEmpty { out.append(.text(run)) }
        return out
    }
    private static func build(_ blocks: [MD.Block], size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
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
                    .font: Theme.uiMono(13.5, weight: .regular), .foregroundColor: Theme.uiText,
                    .backgroundColor: Theme.uiDyn(0xF2EDE3, 0x2A2A27), .paragraphStyle: p]))
            case .table(let head, let rows):
                // 表格正常由 KeMarkdown 拆出去画成格子（MDTable）；这里只是兜底（直接拿 make(text) 的调用方）：制表位对齐
                let cols = max(head.count, rows.map(\.count).max() ?? 0)
                let all = [head] + rows
                let pt: CGFloat = 14
                let widths: [CGFloat] = (0..<cols).map { c in
                    var w: CGFloat = 0
                    for r in all where c < r.count { w = max(w, MD.keNS(r[c], size: pt, weight: .semibold, lineHeight: 1.4).size().width) }
                    return ceil(w) + 18
                }
                var stops: [NSTextTab] = []; var x: CGFloat = 0
                for w in widths.dropLast() { x += w; stops.append(NSTextTab(textAlignment: .left, location: x)) }
                for (k, r) in all.enumerated() {
                    let line = NSMutableAttributedString()
                    for c in 0..<cols {
                        if c > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: Theme.uiSerif(pt)])) }
                        line.append(MD.keNS(c < r.count ? r[c] : "", size: pt, weight: k == 0 ? .semibold : .regular, lineHeight: 1.4))
                    }
                    let p = NSMutableParagraphStyle(); p.tabStops = stops; p.defaultTabInterval = 0
                    p.minimumLineHeight = pt * 1.4; p.maximumLineHeight = pt * 1.4
                    p.paragraphSpacing = k == all.count - 1 ? (last ? 0 : 16) : (k == 0 ? 4 : 2)
                    line.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: line.length))
                    out.append(line); if k < all.count - 1 { out.append(NSAttributedString(string: "\n")) }
                }
            }
        }
        return out
    }
}
