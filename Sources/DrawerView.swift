import SwiftUI

/// 从抽屉出去的路（NavigationStack push：从右滑入、左缘右滑退回，寻定：不要淡入淡出/从下冒出）
enum Route: Hashable {
    case board(openLetter: String?)     // 来信到站点开信封＝直接落到那封信
    case books
    case album
    case mem
    case arch(day: String?, q: String?, no: Int?)   // 档案馆：某一天 / 搜一个词 / #N 直跳
    case web(String)
}

/// 抽屉（照网页 #drawerPanel）：左侧 78%（最宽 300）、暖白底、右缘细线；
/// 花体 Keep＋相遇天数 → 搜索框 → 书架/相册/留言板/记忆 疏朗列表 → 用量一行 → 月历钉底。
struct DrawerView: View {
    @Binding var shown: Bool
    var unread: Int
    let onLogout: () -> Void
    var onNavigate: (Route) -> Void = { _ in }
    @State private var q = ""
    // 日子和额度先用上次记下的（UserDefaults），拉到新的再换——通道慢时抽屉也别空着
    @State private var days: [String] = Preview.on ? [] : (UserDefaults.standard.stringArray(forKey: "cache.days") ?? [])   // 档案馆有记录的日子 yyyy-MM-dd
    @State private var ym: (Int, Int) = (Calendar.current.component(.year, from: Date()), Calendar.current.component(.month, from: Date()))
    @State private var usage = Preview.on ? "" : (UserDefaults.standard.string(forKey: "cache.usage") ?? "")
    @State private var notesBadge = 0

    var body: some View {
        let w = min(UIScreen.main.bounds.width * 0.78, 300)
        ZStack(alignment: .leading) {
            Color.black.opacity(shown ? 0.35 : 0).ignoresSafeArea()
                .allowsHitTesting(shown).onTapGesture { close() }
                .animation(nil, value: shown)                       // 暗幕不淡入淡出（寻定）
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("Keep").font(.custom("Snell Roundhand", size: 34).weight(.semibold)).tracking(1).foregroundColor(Theme.text)
                    Text("\(metDays)").font(.custom("Snell Roundhand", size: 26).weight(.semibold)).foregroundColor(Theme.accent)
                        .baselineOffset(-8).padding(.leading, 2)
                }
                .padding(.bottom, 6)

                HStack(spacing: 0) {
                    TextField("", text: $q, prompt: Text("Search…").foregroundColor(Color(red: 0x7E/255, green: 0x7D/255, blue: 0x77/255)))
                        .textFieldStyle(.plain)
                        .font(Theme.round(14)).foregroundColor(Theme.text).tint(Theme.scrollTint)
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .submitLabel(.search).onSubmit(search)
                    Button(action: search) {
                        Image("search").renderingMode(.template).resizable().frame(width: 15, height: 15).foregroundColor(.white)
                            .padding(.horizontal, 13).frame(maxHeight: .infinity)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain).padding(3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border, lineWidth: 0.7))
                .padding(.top, 6)

                VStack(spacing: 0) {
                    row("书架") { onNavigate(.books) }
                    hair
                    row("相册") { onNavigate(.album) }
                    hair
                    row("留言板", badge: notesBadge) { onNavigate(.board(openLetter: nil)) }
                    hair
                    row("记忆") { onNavigate(.mem) }
                }
                .padding(.top, 10)

                Spacer(minLength: 0)

                calendar
                    .padding(EdgeInsets(top: 12, leading: 8, bottom: 10, trailing: 8))
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.05), radius: 2, y: 1)
                    .id("\(ym.0)-\(ym.1)")                              // 换月＝换身份：不插值、不动画
                    .transaction { $0.animation = nil }

                // 额度一行：日历下 10、字 16 高、离屏底 24（伸进底部安全区，照网页；寻验 36：下面留空还是多）
                Text(usage).font(Theme.round(12)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity).frame(height: 16).padding(.top, 10)
            }
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 14, trailing: 22))   // 寻验 38：日历下面再收窄
            .frame(width: w)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .background(Theme.boardBg.ignoresSafeArea())
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1).ignoresSafeArea() }
            .transaction { $0.animation = nil }                    // 面板内容一律不动画（额度/角标晚到不挪位）
            .offset(x: shown ? 0 : -w - 8)                          // 只从左滑出/滑回
            .animation(.easeOut(duration: 0.22), value: shown)
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in if v.translation.width < -50 { close() } })
        }
        .allowsHitTesting(shown)
        .task(id: shown) { if shown { await load() } }
    }

    private var hair: some View { Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1) }

    private func row(_ label: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(Theme.cjk(15, weight: .medium)).tracking(1.2).foregroundColor(Theme.text)   // 照网页 .nb-label letter-spacing .08em（寻验 44：字挤）
                Spacer()
                if badge > 0 {   // 照网页 #notesBadge：20 高、最小 20 宽 → 一位数就是正圆（寻定：小圆圈）
                    Text("\(badge)").font(Theme.round(12)).foregroundColor(.white)
                        .padding(.horizontal, 6).frame(minWidth: 20).frame(height: 20)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .padding(EdgeInsets(top: 17, leading: 10, bottom: 17, trailing: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 月历（照 .cal-card）：‹ 年 月 ›；有记录的日子灰米色块 55% 透明＋半粗数字；点日子去档案馆那天
    private var calendar: some View {
        let cal = Calendar.current
        let (y, m) = ym
        let first = cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
        let firstWd = cal.component(.weekday, from: first) - 1
        let n = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let has = Set(days.filter { $0.hasPrefix(String(format: "%04d-%02d", y, m)) }.compactMap { Int($0.suffix(2)) })
        // 寻验 32：整体放大一圈（格 34、字 14）；行数随月（固定六行留空她不要）；
        // 切月不动画：整张日历换身份（.id）——新月份直接落在最终位置，没有任何东西可插值
        let cellH: CGFloat = 34
        return VStack(spacing: 8) {
            HStack {
                Button { shift(-1) } label: { Text("‹").font(.system(size: 21)).foregroundColor(Theme.accent).padding(.horizontal, 12) }
                Spacer()
                Text("\(String(y)) 年 \(m) 月").font(Theme.round(14.5)).foregroundColor(Theme.text)
                Spacer()
                Button { shift(1) } label: { Text("›").font(.system(size: 21)).foregroundColor(Theme.accent).padding(.horizontal, 12) }
            }
            .buttonStyle(.plain)
            // 非懒排：整月一次量完（LazyVGrid 换月时先按旧高度排、下一帧再改，箭头会「升起来」）
            let total = Int(ceil(Double(firstWd + n) / 7)) * 7
            let cells: [Int] = Array(repeating: 0, count: firstWd) + Array(1...n) + Array(repeating: 0, count: total - firstWd - n)
            let rows = stride(from: 0, to: total, by: 7).map { Array(cells[$0..<$0 + 7]) }
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    ForEach(["日","一","二","三","四","五","六"], id: \.self) { w in
                        Text(w).font(Theme.round(12)).foregroundColor(Theme.muted.opacity(0.6)).padding(.vertical, 2).frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 3) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, d in
                            if d == 0 {
                                Color.clear.frame(maxWidth: .infinity).frame(height: cellH)
                            } else {
                                let on = has.contains(d)
                                ZStack {
                                    if on { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.dyn(0xF1EFEB, 0x34332F)).opacity(0.55) }
                                    Text(String(d)).font(Theme.round(14, weight: on ? .medium : .regular))
                                        .foregroundColor(on ? Theme.text : Theme.muted.opacity(0.45))
                                }
                                .frame(maxWidth: .infinity).frame(height: cellH)
                                .contentShape(Rectangle())
                                .onTapGesture { if on { onNavigate(.arch(day: String(format: "%04d-%02d-%02d", y, m, d), q: nil, no: nil)) } }
                            }
                        }
                    }
                }
            }
        }
    }

    private func shift(_ d: Int) {
        var (y, m) = ym; m += d
        if m < 1 { m = 12; y -= 1 }; if m > 12 { m = 1; y += 1 }
        ym = (y, m)
    }
    private func search() {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        onNavigate(.arch(day: nil, q: s, no: nil))
    }
    private func close() { shown = false }

    private var metDays: Int {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let start = c.date(from: DateComponents(year: 2026, month: 5, day: 2)) ?? Date()
        return (c.dateComponents([.day], from: c.startOfDay(for: start), to: c.startOfDay(for: Date())).day ?? 0) + 1
    }

    private func load() async {
        if Preview.on { days = ["2026-08-20", "2026-08-28", "2026-09-01"]; ym = (2026, 9); usage = "5h 19% · week 5%"; notesBadge = 1; return }
        guard let token = Keychain.token else { return }
        func get(_ path: String) async -> [String: Any]? {
            var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        async let a = get("api/archive/days")
        async let u = get("api/usage")
        async let nts = get("api/notes")
        async let ls = get("api/letters")
        if let a = await a, let arr = a["days"] as? [[String: Any]] {
            days = arr.compactMap { $0["date"] as? String }
            UserDefaults.standard.set(days, forKey: "cache.days")
            if let last = days.last, let y = Int(last.prefix(4)), let m = Int(last.dropFirst(5).prefix(2)) { ym = (y, m) }
        }
        if let u = await u, let fh = (u["five_hour"] as? [String: Any])?["pct"] as? Double, let sd = (u["seven_day"] as? [String: Any])?["pct"] as? Double {
            usage = "5h \(Int(fh))% · week \(Int(sd))%"
            UserDefaults.standard.set(usage, forKey: "cache.usage")
        }
        let nb = (await nts)?["unread"] as? Int ?? 0
        let lb = (await ls)?["badge"] as? Int ?? 0
        notesBadge = nb + lb
    }
}
