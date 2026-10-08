import SwiftUI

// MARK: - 改动单只读页（寻 10-03 要的，10-08 做）
// 打工机每天按「前天」原文起草的主文件改动，克批 / 改 / 驳 / 留，13:00 送过没动的默认放行。
// 入口在「主文件」栏顶上一张卡；点开整页推进来（同主文件那页）。只看，不在这里批——批是克的事。

struct ChangesPayload: Decodable {
    struct Item: Decodable {
        var id: Int; var op: String; var status: String
        var file: String?; var section: String?; var target: String?; var text: String?
        var date: String?; var title: String?; var quote: String?; var nos: [Int]?; var xun: Bool?
        var keep: String?; var fade: [String]?; var titles: [String: String]?
        var explicit: Bool?; var day: String?; var at: String?; var kind: String?
    }
    var open: [Item]
    var done: [Item]
}

@MainActor
final class ChangesModel: ObservableObject {
    @Published var data: ChangesPayload? = nil
    @Published var failed = false
    func load() async {
        if Preview.on {
            if let d = Preview.json("preview_changes"), let p = try? JSONDecoder().decode(ChangesPayload.self, from: d) { data = p } else { failed = true }
            return
        }
        if data == nil, let c = NetCache.load("api/changes"), let p = try? JSONDecoder().decode(ChangesPayload.self, from: c) { data = p }
        guard let (d, code) = await MemAPI.call("api/changes"), code == 200,
              let p = try? JSONDecoder().decode(ChangesPayload.self, from: d) else { failed = data == nil; return }
        if NetCache.save("api/changes", d) || data == nil { data = p }
        failed = false
    }
}

/// 主文件栏顶上那张入口卡：「改动单　等他批 2 · 近 30 天 135 条 ›」
struct ChangesEntry: View {
    @ObservedObject var m: ChangesModel
    var onOpen: () -> Void
    var body: some View {
        if let d = m.data {
            Button(action: onOpen) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("改动单").font(Theme.georgiaCJK(16)).foregroundColor(Theme.text)
                    Spacer(minLength: 6)
                    Text((d.open.isEmpty ? "" : "等他批 \(d.open.count) · ") + "近 30 天 \(d.open.count + d.done.count) 条")
                        .font(Theme.cjk(11)).foregroundColor(d.open.isEmpty ? Theme.muted : Theme.accent)
                    Text("›").font(Theme.cjk(13)).foregroundColor(Theme.muted)
                }
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card).shadow(color: Theme.text.opacity(0.06), radius: 1, y: 1))
            }.buttonStyle(.plain)
        }
    }
}

struct ChangesPage: View {
    @ObservedObject var m: ChangesModel
    var onBack: () -> Void
    var body: some View {
        ZStack {
            Theme.boardBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { onBack() } label: { BackChevron() }.buttonStyle(.plain).padding(.leading, -8)
                    Text("改动单").font(Theme.georgiaCJK(17)).foregroundColor(Theme.text)
                    Spacer()
                    Text("系统起草，他来批").font(Theme.cjk(12)).foregroundColor(Theme.muted)
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
                OrangeScroll(name: "changes") {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let d = m.data {
                            if !d.open.isEmpty {
                                SecTitle("等他批 · \(d.open.count) 条")
                                ForEach(d.open, id: \.id) { row($0) }
                            }
                            // 了结的按天分段（最后变动那天）
                            ForEach(byDay(d.done)) { g in
                                SecTitle(dayTitle(g.id))
                                ForEach(g.items, id: \.id) { row($0) }
                            }
                            if d.open.isEmpty && d.done.isEmpty { MemEmpty("近 30 天没有改动单") }
                        } else if m.failed { MemEmpty("没拿到改动单，退出来再进一次试试") }
                        else { MemEmpty("加载中…") }
                    }
                    .padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 30)
                }
            }
        }
        .background(EdgeSwipe(onBack: onBack))
    }

    private func row(_ x: ChangesPayload.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: "\(x.id)").font(Theme.mono(10.5)).foregroundColor(Theme.muted)
                if x.explicit == true { Text("★").font(Theme.cjk(11)).foregroundColor(Theme.accent) }
                Text(opName(x)).font(Theme.cjk(12)).foregroundColor(Theme.muted)
                if let f = x.file, !f.isEmpty { Text(f).font(Theme.cjk(12)).foregroundColor(Theme.muted).lineLimit(1) }
                Spacer(minLength: 6)
                let (label, strong) = statusName(x.status)
                Text(label).font(Theme.cjk(11.5))
                    .foregroundColor(strong ? MemColor.xun : Theme.muted)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(strong ? MemColor.softXun : Theme.panel, in: Capsule())
                    .fixedSize()
            }
            bodyText(x)
            if let q = x.quote, !q.isEmpty {
                let src = x.xun == true ? "寻在问寻卡里答" : "原话" + (x.nos ?? []).map { " #\($0)" }.joined()
                Text("\(src)：「\(q)」").font(Theme.cjk(12)).lineSpacing(3).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 15, bottom: 12, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }

    @ViewBuilder private func bodyText(_ x: ChangesPayload.Item) -> some View {
        let main = Theme.serif(14.5)
        switch x.op {
        case "CHANGE", "MOVE":
            VStack(alignment: .leading, spacing: 4) {
                Text(x.target ?? "").font(main).foregroundColor(Theme.muted).lineSpacing(4)
                Text("→ " + (x.text ?? "")).font(main).foregroundColor(Theme.text).lineSpacing(4)
            }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case "FADE":
            Text(x.target ?? "").font(main).foregroundColor(Theme.text).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case "DATE":
            Text(dateLine(x)).font(main).foregroundColor(Theme.text)
        case "MERGE":
            let t = x.titles ?? [:]
            Text("留「\(t[x.keep ?? ""] ?? "")」，淡去" + (x.fade ?? []).map { "「\(t[$0] ?? "")」" }.joined(separator: "、")
                 + ((x.text ?? "").isEmpty ? "" : "——" + (x.text ?? "")))
                .font(main).foregroundColor(Theme.text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        default:
            Text(x.text ?? "").font(main).foregroundColor(Theme.text).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func opName(_ x: ChangesPayload.Item) -> String {
        switch x.op {
        case "ADD": return (x.section ?? "").isEmpty ? "新增" : "词条"
        case "CHANGE": return "改"
        case "PAST": return "进以前"
        case "FADE": return "挪进以前"
        case "MOVE": return "挪成词条"
        case "MERGE": return "合并桶"
        case "DATE": return "日子"
        default: return x.op
        }
    }
    /// (字, 是否用赤陶淡底)：等他批的醒目，了结的灰
    private func statusName(_ s: String) -> (String, Bool) {
        switch s {
        case "pending": return ("等他批", true)
        case "held": return ("他说留着", true)
        case "approved": return ("他批了", false)
        case "edited": return ("他改过", false)
        case "passed": return ("默认放行", false)
        case "rejected": return ("驳了", false)
        default: return (s, false)
        }
    }
    private func dateLine(_ x: ChangesPayload.Item) -> String {
        let d = x.date ?? ""
        let mo = Int(d.dropFirst(5).prefix(2)) ?? 0, dd = Int(d.dropFirst(8).prefix(2)) ?? 0
        return (mo > 0 ? "\(mo)月\(dd)日　" : "") + (x.title ?? "")
    }
    private struct DayGroup: Identifiable { let id: String; var items: [ChangesPayload.Item] }
    private func byDay(_ items: [ChangesPayload.Item]) -> [DayGroup] {
        var out: [DayGroup] = []
        for x in items {
            let k = String((x.at ?? "").prefix(10))
            if out.last?.id == k { out[out.count - 1].items.append(x) } else { out.append(DayGroup(id: k, items: [x])) }
        }
        return out
    }
    private func dayTitle(_ d: String) -> String {
        let mo = Int(d.dropFirst(5).prefix(2)) ?? 0, dd = Int(d.dropFirst(8).prefix(2)) ?? 0
        return mo > 0 ? "\(mo)月\(dd)日 了结" : "了结的"
    }
}
