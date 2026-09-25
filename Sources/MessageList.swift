import SwiftUI

/// 消息流本体（09-15 晚从 ChatScreen 拆出来）：只依赖 model 和 lift（录音浮层要垫的高）。
/// 为什么拆：收键盘那一两帧 100 多毫秒（仪表 kb-hide maxgap 40–170ms）＝键盘起收时 ChatScreen 那层的几个 @State 一变，
/// 整页连着五十来条富文本行一起重排；拆成自己的 View 后，父层状态怎么变，只要 model 没发布、lift 没变，这一层不重算。
struct MessageListBody: View {
    @ObservedObject var model: ChatModel
    var lift: CGFloat

    var body: some View {
        // 行距（09-09 寻验「工具+思考+工具+思考」第三四段叠在一起、直播工具行半截在输入框底下）：不再 spacing 22 + 负边距，
        // 改 spacing 0、每行自带上间距——负边距把版面缩成负数：内容高不含它、钉底钉不到、后一行叠上来
        VStack(spacing: 0) {
            // 正史包成一整块（09-25 夜，掉帧仪 09-25：17 点 56 帧、21 点 36 帧，越晚越卡）：ForEach 直接摊在外层 VStack 里，
            // 直播段每长高一行，外层就把当天攒下的几百行逐个重新问一遍尺寸、重新摆；包成一块后外层只有两个孩子，正史这块尺寸没变就整块照旧
            VStack(spacing: 0) {
                if model.renderFrom > 0 {
                    Button { model.loadOlderDay() } label: {
                        Text("· 更早 ·").font(Theme.round(12)).tracking(1).foregroundColor(Theme.muted)
                    }.buttonStyle(.plain).padding(.top, 4)
                }
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, r in
                    row(r.item, afterTools: i > 0 && Self.toolsOnly(model.items[i - 1].item), last: i == model.items.count - 1).padding(.top, gapBefore(i))
                }
            }
            // 直播段单独订阅 liveBox（09-25）：打字机每帧只重算它，上面七百行正史不动
            LiveSection(box: model.liveBox, afterHist: model.items.last.map { Self.toolsOnly($0.item) } ?? false, hasHist: !model.items.isEmpty)
        }
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 10 + lift)   // 网页 #messages padding-bottom 10；录音时再垫浮层高
    }

    /// 以工具行收尾的 AI 行（只有工具行，或正文后面跟着工具行——09-12 起工具行画在正文后）：下一行的行距要收（thought 打头 8＝视觉 10，正文打头 4-2+13≈15）
    static func toolsOnly(_ item: TimelineItem) -> Bool {
        if case .ai(_, let m, _) = item {
            return !(m.toolCalls ?? []).isEmpty
        }
        return false
    }
    private func gapBefore(_ i: Int) -> CGFloat {
        guard i > 0 else { return model.renderFrom > 0 ? 22 : 0 }
        guard Self.toolsOnly(model.items[i - 1].item) else { return 22 }
        // 09-13 寻：夹在文中的工具行上下太窄 → 工具行接正文 4→9、接思考头 8→12（连排工具行之间照旧 4）
        if case .ai(_, let m, _) = model.items[i].item { return m.cleanThinking.isEmpty ? 9 : 12 }
        return 22
    }
    @ViewBuilder private func row(_ item: TimelineItem, afterTools: Bool = false, last: Bool = false) -> some View {
        switch item {
        case .daySep(let d): DaySepView(day: d)
        case .user(let t, let s, let imgs, let p, let v): UserRowView(text: t, stamp: s, images: imgs, pick: p, voice: v)
        case .ai(_, let m, let u):
            AIRowView(msg: m, showUsage: u, afterTools: afterTools)
        case .toolChip(let n, let f): ToolChipView(name: n, done: true, first: f)
        case .ping(let m): PingChipView(msg: m)
        case .wakeChip(let hm): WakeChipView(hm: hm)
        case .knock(let t, let s): KnockRowView(text: t, stamp: s)
        }
    }

}

/// 直播段（09-25 从 MessageListBody 拆出）：只订阅 liveBox，打字机每帧只重算这一块。
/// afterHist＝正史末行是不是「只有工具行」（行距要收）；hasHist＝正史有没有行（第一段上间距）
struct LiveSection: View {
    @ObservedObject var box: LiveBox
    var afterHist: Bool
    var hasHist: Bool

    var body: some View {
        if let live = box.turn {
            VStack(alignment: .leading, spacing: 0) { liveView(live) }.padding(.top, liveTopGap(live)).id("live")
        }
    }
    private func liveTopGap(_ live: LiveTurn) -> CGFloat {
        guard hasHist else { return 0 }
        guard afterHist else { return 22 }
        if case .seg(let s)? = live.items.first { return Self.hasThinking(s) ? 12 : 9 }
        return 9
    }
    private static func hasThinking(_ s: LiveSeg) -> Bool { !s.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 直播段之间的行距：连排工具行 4；工具行→thought 8（+2＝10）；工具行→正文 4（正文顶 0 + 13 顶空≈15）；
    /// 正文→下一段 22（正文自带底 11）；thought→工具行 8（+2＝10）；空段 0
    private static func liveGap(prev: LiveItem, thisIsChip: Bool, thinking: Bool) -> CGFloat {
        switch prev {
        case .chip: return thisIsChip ? 4 : (thinking ? 12 : 9)
        case .seg(let p):
            if p.error != nil || p.shown > 0 { return 22 }
            return hasThinking(p) ? 8 : 0
        }
    }
    /// 直播段（09-09 重排）：不再有任何负边距（136/138 两版负边距都留了病：工具行只露半截、段落叠在一起），
    /// 行距全由 liveGap 按前后段给；第一段的上间距由 liveTopGap 按正史末行给
    @ViewBuilder private func liveView(_ live: LiveTurn) -> some View {
        ForEach(Array(live.items.enumerated()), id: \.offset) { idx, it in
            let prev: LiveItem? = idx > 0 ? live.items[idx - 1] : nil
            switch it {
            case .chip(let n, let d):
                ToolChipView(name: n, done: d, inRow: true)
                    .padding(.top, prev.map { Self.liveGap(prev: $0, thisIsChip: true, thinking: false) } ?? 0)
            case .seg(let s):
                let thinking = Self.hasThinking(s)
                let afterChip = prev.map { if case .chip = $0 { return true } else { return false } } ?? afterHist
                VStack(alignment: .leading, spacing: 6) {
                    if thinking {
                        ThinkView(text: s.thinking.trimmingCharacters(in: .whitespacesAndNewlines),
                                  label: s.thinkSecs.map { "Thought for \(String(format: "%.1f", $0))s" } ?? "Thinking…")
                    }
                    if let e = s.error {
                        Text(e).font(Theme.serif(15)).foregroundColor(.red)
                    } else if s.shown > 0 {
                        // 紧跟工具行的正文：顶 0（行距 4 + 宋体 13 顶空≈15，同正史）；其余照网页 .bubble 上下 11
                        // 直播里 [reply: …] 不上屏（半截的先藏、整段的摘掉）；说完落成正史那条再画成选项卡
                        KeMarkdown(text: Replies.split(Replies.hidePartial(s.shownText)).text, live: true).padding(.top, (afterChip && !thinking) ? 0 : 11).padding(.bottom, 11)
                    }   // 还没吐字：什么都不画（照网页；寻：没有 thinking 就别显示 thought）
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, prev.map { Self.liveGap(prev: $0, thisIsChip: false, thinking: thinking) } ?? 0)
            }
        }
    }
}

/// 只盯直播段的小哨兵（09-25）：live 拆出 ChatModel 后 ChatScreen 那层不再随打字机每帧重算，
/// 「新段落出现就到底」「字长出来就钉底」这两只 onChange 搬到这里，闭包里读的还是 ChatScreen 的状态
struct LiveWatch: View {
    @ObservedObject var box: LiveBox
    var onItems: () -> Void
    var onEvent: () -> Void
    var body: some View {
        Color.clear
            .onChange(of: box.turn?.items.count ?? 0) { _ in onItems() }
            .onChange(of: box.turn?.events ?? 0) { _ in onEvent() }
    }
}
