import SwiftUI

// MARK: - 记忆页「桶」栏（寻 10-05 第十稿：临时给寻\记忆桶样稿.html）
// 只读翻克的记忆桶：搜索（边打边筛）、四域分类、月份格子；桶卡照留言板帖子（Georgia 题＋两行宋体），
// 分类是标题后的一枚线图标，受保护带赤陶锁；淡去的只露标题、整张变浅；点卡原地下拉，
// 底下两行小灰字（日期·谁记的 / 原文条号，条号赤陶，点了去档案馆那一条）。

struct BucketsPayload: Decodable {
    struct B: Decodable, Identifiable {
        var id: String
        var t: String
        var d: String
        var ev: String
        var c: String
        var hm: String?
        var faded: Bool
        var keep: Bool
        var no: [Int]
        var nd: [String]?
        var src: String
        var body: String
        /// 归哪天：事件日期写准了用它，否则用记下那天
        var day: String { ev.count == 10 && ev.hasPrefix("20") ? ev : c }
    }
    var items: [B]
}

@MainActor
final class BucketsModel: ObservableObject {
    @Published var items: [BucketsPayload.B]? = nil
    @Published var failed = false
    func load() async {
        if Preview.on {
            if let d = Preview.json("preview_buckets"), let p = try? JSONDecoder().decode(BucketsPayload.self, from: d) { items = p.items } else { failed = true }
            return
        }
        if items == nil, let c = NetCache.load("api/buckets"), let p = try? JSONDecoder().decode(BucketsPayload.self, from: c) { items = p.items }
        guard let (d, code) = await MemAPI.call("api/buckets"), code == 200,
              let p = try? JSONDecoder().decode(BucketsPayload.self, from: d) else { failed = items == nil; return }
        if NetCache.save("api/buckets", d) || items == nil { items = p.items }
        failed = false
    }
}

enum BucketStyle {
    static let domains: [(key: String, label: String, icon: String)] =
        [("事实", "事实", "tool-bookmark"), ("日常", "日常", "sun"), ("读书", "读书", "tool-book-open"), ("feel", "感受", "tool-heart")]
    static func icon(_ d: String) -> String? { domains.first { $0.key == d }?.icon }
    static let months = ["一月","二月","三月","四月","五月","六月","七月","八月","九月","十月","十一月","十二月"]
    static let thisYear = Calendar.current.component(.year, from: Date())
    /// 今年只写「十月」，往年「2025年 十月」（照留言板）
    static func monLabel(_ day: String) -> String {
        let y = Int(day.prefix(4)) ?? thisYear, m = Int(day.dropFirst(5).prefix(2)) ?? 1
        return (y != thisYear ? "\(y)年 " : "") + months[max(0, min(11, m - 1))]
    }
    static func md(_ day: String) -> String {
        let m = Int(day.dropFirst(5).prefix(2)) ?? 0, d = Int(day.dropFirst(8).prefix(2)) ?? 0
        return "\(m)/\(d)"
    }
    static func cnDate(_ day: String) -> String {
        let m = Int(day.dropFirst(5).prefix(2)) ?? 0, d = Int(day.dropFirst(8).prefix(2)) ?? 0
        return "\(m)月\(d)日"
    }
    /// 卡片右上那个日期：写准了「10/3」，「约2026-05中旬」写「约5月中旬」
    static func corner(_ b: BucketsPayload.B) -> String {
        if b.ev.hasPrefix("约"), b.ev.count >= 8 {
            let m = Int(b.ev.dropFirst(6).prefix(2)) ?? 0
            return "约\(m)月" + String(b.ev.dropFirst(8))
        }
        return md(b.day)
    }
    static func who(_ src: String) -> String {
        switch src {
        case "hold", "feel": return "克"
        case "book": return "读书"
        case "import": return "补录"          // 07-03 通读旧对话一次导进来的那批
        default: return "系统"                // grow / plan 这类系统代录
        }
    }
    static func byKe(_ src: String) -> Bool { src == "hold" || src == "feel" }
}

struct BucketsTab: View {
    @ObservedObject var m: BucketsModel
    var onArchive: (String, Int) -> Void
    @State private var q = Preview.on && Preview.screen == "membkq" ? "青羊" : ""
    @State private var qFocused = false
    @State private var dom = ""
    @State private var titleOnly = Preview.on && Preview.screen == "membkq"   // 只搜标题（寻 10-05）
    @State private var mine = false     // 只看克亲手记的（寻 10-05：标签就写一个「克」）
    @State private var mon = ""          // yyyy-MM
    @State private var monOpen = Preview.on && Preview.screen == "membkmon"
    @State private var year = BucketStyle.thisYear
    @State private var open: Set<String> = Preview.on && Preview.screen == "membkopen" ? ["p1", "p2"] : []
    private static let searchFont: UIFont = Theme.uiRound(14)

    private var rows: [BucketsPayload.B] {
        let all = m.items ?? []
        let k = q.trimmingCharacters(in: .whitespaces)
        return all.filter { b in
            (dom.isEmpty || b.d == dom) && (mon.isEmpty || b.day.hasPrefix(mon)) && (!mine || BucketStyle.byKe(b.src))
                && (k.isEmpty || b.t.contains(k) || (!titleOnly && b.body.contains(k)))
        }.sorted { $0.day > $1.day }
    }

    var body: some View {
        if m.failed { MemEmpty("没拿到记忆桶，退出来再进一次试试") }
        else if m.items == nil { MemEmpty("加载中…") }
        else {
            let list = rows
            search(list.count)
            chips
            if monOpen { monthGrid }
            if list.isEmpty { MemEmpty("没有对得上的桶\n换个词，或少选几样", top: 0.12) }
            ForEach(groups(list), id: \.0) { label, arr in
                SecTitle(label)
                ForEach(arr) { card($0) }
            }
        }
    }

    // 搜索框照抽屉：定高、Search… 贴左（圆体那一档：字母数字走 Cascadia）、条数同字体；边打边筛，不要按钮
    private func search(_ n: Int) -> some View {
        HStack(spacing: 8) {
            PlainField(text: $q, focused: $qFocused, placeholder: "Search…", font: Self.searchFont, returnKey: .done,
                       selectAllOnFocus: true, onSubmit: { qFocused = false })   // 照抽屉：有字时再点＝全选
                .frame(height: 20)
            Text(verbatim: String(n)).font(Theme.round(14)).foregroundColor(Theme.muted)
        }
        .padding(.horizontal, 14).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.card).shadow(color: Theme.text.opacity(0.06), radius: 1, y: 1))
    }

    private var chips: some View {
        HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {   // 搜索时多一枚「标题」，窄屏装不下就横着滑；加号钉在右边
            HStack(spacing: 5) {
            ForEach(BucketStyle.domains, id: \.key) { d in
                let on = dom == d.key
                Button { dom = on ? "" : d.key } label: {
                    HStack(spacing: 2) {
                        Image(d.icon).renderingMode(.template).resizable().frame(width: 12, height: 12)
                        Text(d.label).font(Theme.cjk(12))
                    }
                    .foregroundColor(on ? Theme.knockText : Theme.muted)
                    .padding(.horizontal, 8).frame(height: 25)
                    .background(on ? Theme.knockBg : Theme.panel, in: Capsule())
                }.buttonStyle(.plain)
            }
            Button { mine.toggle() } label: {
                Text("克").font(Theme.cjk(12)).foregroundColor(mine ? Theme.knockText : Theme.muted)
                    .padding(.horizontal, 8).frame(height: 25)
                    .background(mine ? Theme.knockBg : Theme.panel, in: Capsule())
            }.buttonStyle(.plain)
            if !q.trimmingCharacters(in: .whitespaces).isEmpty {   // 「只搜标题」：搜索框有字才出现（寻 10-05）
                Button { titleOnly.toggle() } label: {
                    Text("题").font(Theme.cjk(12)).foregroundColor(titleOnly ? Theme.knockText : Theme.muted)
                        .padding(.horizontal, 8).frame(height: 25)
                        .background(titleOnly ? Theme.knockBg : Theme.panel, in: Capsule())
                }.buttonStyle(.plain)
            }
            }
            }
            Spacer(minLength: 0)
            Button { withAnimation(.easeOut(duration: 0.2)) { monOpen.toggle() } } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: monOpen ? "minus" : "plus").font(.system(size: 11, weight: .medium))
                        .foregroundColor(monOpen ? Theme.knockText : Theme.muted)
                        .frame(width: 25, height: 25)
                        .background(monOpen ? Theme.knockBg : Theme.panel, in: Circle())
                    if !mon.isEmpty && !monOpen { Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: 1, y: -1) }
                }
            }.buttonStyle(.plain)
        }
    }

    /// 月份格子照抽屉月历：‹ 2026 › 居中；有桶的淡米底中粗字，没桶的极淡；选中＝赤陶 13% 淡橙底；再点取消
    private var monthGrid: some View {
        let have = Set((m.items ?? []).map { String($0.day.prefix(7)) })
        let years = Set(have.compactMap { Int($0.prefix(4)) })
        return VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { year -= 1 } label: { Text("‹").font(Theme.ui(21)).foregroundColor(Theme.accent).padding(.horizontal, 12) }
                    .buttonStyle(.plain).opacity((years.min() ?? year) < year ? 1 : 0.25).disabled((years.min() ?? year) >= year)
                Text(String(year)).font(.custom("Georgia", size: 15)).foregroundColor(Theme.text).frame(minWidth: 52)
                Button { year += 1 } label: { Text("›").font(Theme.ui(21)).foregroundColor(Theme.accent).padding(.horizontal, 12) }
                    .buttonStyle(.plain).opacity(year < BucketStyle.thisYear ? 1 : 0.25).disabled(year >= BucketStyle.thisYear)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(1...12, id: \.self) { i in
                    let k = String(format: "%d-%02d", year, i)
                    let has = have.contains(k), on = mon == k
                    Button { if has { mon = on ? "" : k } } label: {
                        Text("\(i)").font(Theme.round(14, weight: has ? .medium : .regular))
                            .foregroundColor(has ? Theme.text : Theme.muted.opacity(0.45))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .background {
                                if on { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent).opacity(0.13) }
                                else if has { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.dyn(0xF1EFEB, 0x34332F)).opacity(0.55) }
                            }
                    }.buttonStyle(.plain).disabled(!has)
                }
            }
        }
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 10, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card).shadow(color: Theme.text.opacity(0.06), radius: 1, y: 1))
    }

    private func groups(_ arr: [BucketsPayload.B]) -> [(String, [BucketsPayload.B])] {
        var out: [(String, [BucketsPayload.B])] = []
        for b in arr {
            let l = BucketStyle.monLabel(b.day)
            if let last = out.last, last.0 == l { out[out.count - 1].1.append(b) } else { out.append((l, [b])) }
        }
        return out
    }

    private func card(_ b: BucketsPayload.B) -> some View {
        let isOpen = open.contains(b.id)
        return BucketCard(b: b, isOpen: isOpen, onArchive: onArchive)
            .onTapGesture { withAnimation(.easeOut(duration: 0.22)) { if isOpen { open.remove(b.id) } else { open.insert(b.id) } } }
    }
}

/// 桶卡（桶栏和主文件页浮卡共用）：Georgia 题＋分类线图标（受保护的染赤陶）＋右上 Georgia 小日期；
/// 两行宋体正文；淡去只露标题、整张变浅；展开后正文全出，底下空一行接两行圆体小灰字（日期·谁记的 / 条号）。
struct BucketCard: View {
    let b: BucketsPayload.B
    var isOpen: Bool
    var pop = false          // 主文件页里浮起来的那张：照留言板浮卡放大留白、题更大、题与正文空得更开（寻 10-05）
    var onArchive: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let ic = BucketStyle.icon(b.d) {   // 分类图标放标题最前（寻 10-05）
                        Image(ic).renderingMode(.template).resizable().frame(width: 13, height: 13)
                            .foregroundColor(b.keep ? Theme.accent : Theme.muted)   // 受保护＝图标染赤陶（寻 10-05，不要锁）
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    }
                    Text(b.t).font(Theme.georgiaCJK(pop ? 18 : 16)).foregroundColor(Theme.text)
                }
                Spacer(minLength: 4)
                Text(BucketStyle.corner(b)).font(.custom("Georgia", size: 12)).foregroundColor(Theme.muted)
            }
            if !b.faded || isOpen {
                Text(b.body).font(Theme.serif(pop ? 14.8 : 14.5)).lineSpacing(pop ? 7 : 4).foregroundColor(Theme.text.opacity(0.85))
                    .lineLimit(isOpen ? nil : 2).fixedSize(horizontal: false, vertical: isOpen)
                    .textSelection(.enabled)   // 长按能选字复制（寻 10-05）
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, pop ? 14 : 8)
            }
            if isOpen { meta.padding(.top, 18) }
        }
        .padding(pop ? EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
                     : EdgeInsets(top: 14, leading: 15, bottom: b.faded && !isOpen ? 13 : 15, trailing: 15))
        .background(RoundedRectangle(cornerRadius: pop ? 18 : 14, style: .continuous).fill(Theme.card).shadow(color: Theme.text.opacity(0.06), radius: 1, y: 1))
        .opacity(b.faded && !pop ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    /// 照相册照片底下那两行：圆体小灰字，比正文小；条号赤陶（不带「聊天」二字），点了去档案馆
    private var meta: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: [BucketStyle.md(b.c), b.hm ?? "", BucketStyle.who(b.src)].filter { !$0.isEmpty }.joined(separator: " · "))   // 10/2·19:31·克
            if !b.no.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(b.no.enumerated()), id: \.offset) { i, n in
                        if i > 0 { Text(" ") }
                        let day = (b.nd ?? []).indices.contains(i) ? b.nd![i] : ""
                        Text(verbatim: "#\(n)").foregroundColor(Theme.accent)
                            .onTapGesture { if !day.isEmpty { onArchive(day, n) } }
                    }
                }
            }
        }
        .font(Theme.round(11.5)).lineSpacing(1).foregroundColor(Theme.muted)   // 和相册照片底下那几行同号
    }
}
