import SwiftUI

/// 抽屉（照网页 #drawerPanel）：左侧 78%（最宽 300）、暖白底、右缘细线；
/// 花体 Keep＋相遇天数 → 搜索框 → 书架/相册/留言板/记忆 疏朗列表 → 用量一行 → 月历钉底。
struct DrawerView: View {
    @Binding var shown: Bool
    var unread: Int
    let onLogout: () -> Void
    @State private var q = ""
    @State private var days: [String] = []          // 档案馆有记录的日子 yyyy-MM-dd
    @State private var ym: (Int, Int) = (Calendar.current.component(.year, from: Date()), Calendar.current.component(.month, from: Date()))
    @State private var usage = ""
    @State private var notesBadge = 0
    @State private var target: Target? = nil
    @State private var showBoard = false

    struct Target: Identifiable { let id = UUID(); let link: String }

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("Keep").font(.custom("Snell Roundhand", size: 34).weight(.semibold)).tracking(1).foregroundColor(Theme.text)
                    Text("\(metDays)").font(.custom("Snell Roundhand", size: 26).weight(.semibold)).foregroundColor(Theme.accent)
                        .baselineOffset(-8).padding(.leading, 2)
                }
                .padding(.bottom, 6)

                HStack(spacing: 0) {
                    TextField("", text: $q, prompt: Text("Search…").foregroundColor(Color(red: 0x7E/255, green: 0x7D/255, blue: 0x77/255)))
                        .font(Theme.round(14)).foregroundColor(Theme.text)
                        .padding(.vertical, 10).padding(.horizontal, 12)
                        .submitLabel(.search).onSubmit(search)
                    Button(action: search) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 13).frame(maxHeight: .infinity)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }.padding(3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.bg, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .padding(.top, 6)

                VStack(spacing: 0) {
                    row("书架") { target = Target(link: "#books") }
                    hair
                    row("相册") { target = Target(link: "#album") }
                    hair
                    row("留言板", badge: notesBadge) { showBoard = true }
                    hair
                    row("记忆") { target = Target(link: "#mem") }
                }
                .padding(.top, 10)

                Spacer(minLength: 0)

                Text(usage).font(Theme.round(12)).foregroundColor(Theme.muted)
                    .frame(maxWidth: .infinity).offset(y: 6).frame(height: 0)

                calendar
            }
            .padding(EdgeInsets(top: 20, leading: 22, bottom: 10, trailing: 22))
            .frame(width: min(UIScreen.main.bounds.width * 0.78, 300))
            .frame(maxHeight: .infinity)
            .background(Theme.boardBg.ignoresSafeArea())
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1).ignoresSafeArea() }
            .transition(.move(edge: .leading))
        }
        .task { await load() }
        .fullScreenCover(item: $target) { t in WebShellScreen(onLogout: onLogout, openDrawer: false, deepLink: t.link) }
        .fullScreenCover(isPresented: $showBoard) { BoardScreen(onLogout: onLogout) }
    }

    private var hair: some View { Rectangle().fill(Theme.dyn(0x302D27, 0xFFFFFF).opacity(0.07)).frame(height: 1) }

    private func row(_ label: String, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(Theme.cjk(16, weight: .medium)).foregroundColor(Theme.text)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(Theme.round(12)).foregroundColor(.white)
                        .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 6)
                        .background(Theme.accent, in: Capsule())
                }
            }
            .padding(EdgeInsets(top: 14, leading: 10, bottom: 14, trailing: 2))
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
        return VStack(spacing: 4) {
            HStack {
                Button { shift(-1) } label: { Text("‹").font(.system(size: 20)).foregroundColor(Theme.accent).padding(.horizontal, 12) }
                Spacer()
                Text("\(y) 年 \(m) 月").font(Theme.round(13.5)).foregroundColor(Theme.text)
                Spacer()
                Button { shift(1) } label: { Text("›").font(.system(size: 20)).foregroundColor(Theme.accent).padding(.horizontal, 12) }
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(["日","一","二","三","四","五","六"], id: \.self) { w in
                    Text(w).font(Theme.round(11)).foregroundColor(Theme.muted.opacity(0.6)).padding(.vertical, 2)
                }
                ForEach(0..<firstWd, id: \.self) { _ in Color.clear.frame(height: 26) }
                ForEach(1...n, id: \.self) { d in
                    let on = has.contains(d)
                    Text("\(d)").font(Theme.round(13, weight: on ? .medium : .regular))
                        .foregroundColor(on ? Theme.text : Theme.muted.opacity(0.45))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(on ? Theme.dyn(0xF1EFEB, 0x34332F).opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .onTapGesture { if on { target = Target(link: String(format: "#arch:%04d-%02d-%02d", y, m, d)) } }
                }
            }
        }
        .padding(.top, 12)
    }

    private func shift(_ d: Int) {
        var (y, m) = ym; m += d
        if m < 1 { m = 12; y -= 1 }; if m > 12 { m = 1; y += 1 }
        ym = (y, m)
    }
    private func search() {
        let s = q.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        target = Target(link: "#search:" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s))
    }
    private func close() { withAnimation(.easeIn(duration: 0.18)) { shown = false } }

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
            if let last = days.last, let y = Int(last.prefix(4)), let m = Int(last.dropFirst(5).prefix(2)) { ym = (y, m) }
        }
        if let u = await u, let fh = (u["five_hour"] as? [String: Any])?["pct"] as? Double, let sd = (u["seven_day"] as? [String: Any])?["pct"] as? Double {
            usage = "5h \(Int(fh))% · week \(Int(sd))%"
        }
        let nb = (await nts)?["unread"] as? Int ?? 0
        let lb = (await ls)?["badge"] as? Int ?? 0
        notesBadge = nb + lb
    }
}
