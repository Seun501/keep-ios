import SwiftUI

// MARK: - 记忆页「近况」（寻 10-07：克写的 days/ 一篇篇列，是记忆页一栏、不是档案馆卡；10-08 六栏太多，并进日子栏底下）
// 接口 /api/recent：新的在前，每篇＝详细版＋短版（四天前那天他压的三五句，有才有）＋几点写的。只读。

struct RecentPayload: Decodable {
    struct Day: Decodable {
        var date: String; var text: String; var short: String?; var writtenAt: String?
        enum CodingKeys: String, CodingKey { case date, text, short, writtenAt = "written_at" }
    }
    var days: [Day]
}

@MainActor
final class RecentModel: ObservableObject {
    @Published var data: RecentPayload? = nil
    @Published var failed = false
    func load() async {
        if Preview.on {
            if let d = Preview.json("preview_recent"), let p = try? JSONDecoder().decode(RecentPayload.self, from: d) { data = p } else { failed = true }
            return
        }
        if data == nil, let c = NetCache.load("api/recent"), let p = try? JSONDecoder().decode(RecentPayload.self, from: c) { data = p }
        guard let (d, code) = await MemAPI.call("api/recent"), code == 200,
              let p = try? JSONDecoder().decode(RecentPayload.self, from: d) else { failed = data == nil; return }
        if NetCache.save("api/recent", d) || data == nil { data = p }
        failed = false
    }
}

struct RecentTab: View {
    @ObservedObject var m: RecentModel
    @State private var open: Set<String> = []
    var body: some View {
        // 接在日子栏「每年的」下面：按月分段，栏题「他写下的 · 十月 · 7 篇」；没写过/没拉到就整段不出，不打扰上面的日子
        if let d = m.data {
            ForEach(months(d.days)) { g in
                SecTitle("他写下的 · \(g.id) · \(g.days.count) 篇")
                ForEach(g.days, id: \.date) { day in card(day) }
            }
        }
    }
    /// 卡片同注入栏：只有抬头开合，正文可选字（寻 10-07）
    private func card(_ day: RecentPayload.Day) -> some View {
        let isOpen = open.contains(day.date)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title(day.date)).font(Theme.georgiaCJK(16)).tracking(0.16).foregroundColor(Theme.text).lineLimit(1)
                Spacer()
                Text(side(day)).font(Theme.round(11)).tracking(0.44).foregroundColor(Theme.muted)
                Text("›").font(Theme.cjk(13)).foregroundColor(Theme.muted).rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.vertical, 13).contentShape(Rectangle())
            .onTapGesture { if isOpen { open.remove(day.date) } else { open.insert(day.date) } }
            if isOpen {
                RichText(attr: MD.keNS(day.text, size: 14.2, weight: .regular, lineHeight: 1.65)).padding(.bottom, 13)
                if let s = day.short, !s.isEmpty {
                    Text("短版").font(Theme.cjk(12)).tracking(1.5).foregroundColor(Theme.muted).padding(.bottom, 4)
                    RichText(attr: MD.keNS(s, size: 13.5, weight: .regular, lineHeight: 1.6)).padding(.bottom, 13)
                }
            }
        }
        .padding(EdgeInsets(top: 0, leading: 15, bottom: 0, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.06), radius: 2, y: 1)
    }
    private static let cnMonth = ["", "一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]
    private struct Month: Identifiable { let id: String; var days: [RecentPayload.Day] }
    private func months(_ days: [RecentPayload.Day]) -> [Month] {
        var out: [Month] = []
        for d in days {
            let key = Self.cnMonth[Int(d.date.dropFirst(5).prefix(2)) ?? 0]
            if out.last?.id == key { out[out.count - 1].days.append(d) } else { out.append(Month(id: key, days: [d])) }
        }
        return out
    }
    /// 「2026-10-07」→「10月7日 周三」
    private func title(_ date: String) -> String {
        let mo = Int(date.dropFirst(5).prefix(2)) ?? 0, dd = Int(date.dropFirst(8).prefix(2)) ?? 0
        var c = DateComponents(); c.year = Int(date.prefix(4)); c.month = mo; c.day = dd
        let wd = Calendar(identifier: .gregorian).date(from: c).map { Calendar(identifier: .gregorian).component(.weekday, from: $0) } ?? 0
        let names = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return "\(mo)月\(dd)日 " + (wd > 0 ? names[wd] : "")
    }
    /// 右侧小字：「10/8 11:01 写 · 1.2k字」
    private func side(_ day: RecentPayload.Day) -> String {
        var s = ""
        if let w = day.writtenAt, w.count >= 16 {
            let mo = Int(w.dropFirst(5).prefix(2)) ?? 0, dd = Int(w.dropFirst(8).prefix(2)) ?? 0
            s = "\(mo)/\(dd) \(w.suffix(5)) 写 · "
        }
        return s + "\(day.text.count)字"
    }
}
