import SwiftUI

/// 原生口令页（09-02 寻：网页那张难看）。只登一次，口令进钥匙串，此后开 App 直入。
/// 09-15 寻：灰底圆角输入框和大胶囊「进」太丑——照锁信那张口令行来：一根发丝线托着的输入行、右边一枚小胶囊钮，
/// 整行 230 宽居中；错误行固定占位不忽高忽低。配色走 Theme（纸色底、深暖棕字、赤陶钮），不描边。
struct LoginView: View {
    var onSuccess: (String) -> Void

    @State private var text = ""
    @State private var busy = false
    @State private var error = ""
    @State private var focused = false

    private var empty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    @State private var litAt: Date? = nil       // 口令对了：星座线从这一刻起 1.4 秒连完，再进屋
    @State private var pendingToken = ""
    private let here = StarSky.here()

    /// 09-15 寻定「试试 2」：口令页＝开屏那张的构图——Clawd 站在屏高 45%，欢迎语的位置换成一根输入线（回车即进），没有按钮；
    /// 报错一行赤陶小字在线下固定占位。整块按屏幕坐标钉死、不随键盘挪。底上是此刻头顶的真星图（StarSky.swift），入夜才出来。
    /// 口令是粘贴的长串（寻）：线上不显字，粘进来线由淡变深算作「有东西了」；对了星座线连起来，然后进屋。
    var body: some View {
        GeometryReader { g in
            let H = UIScreen.main.bounds.height
            let top = g.frame(in: .global).minY
            ZStack(alignment: .top) {
                Theme.bg.ignoresSafeArea()
                TimelineView(.animation(paused: litAt == nil)) { ctx in
                    let lit = litAt.map { min(1, ctx.date.timeIntervalSince($0) / 1.4) } ?? 0
                    let night = Preview.on ? 1 : StarSky.nightness(date: ctx.date, lat: here.0, lon: here.1)
                    StarSkyView(date: Preview.on ? Self.previewDate : ctx.date, lat: here.0, lon: here.1, night: night, lit: lit)
                }
                .ignoresSafeArea()
                ClawdWeb(state: "idle", flip: false)
                    .frame(width: 150, height: 150)
                    .position(x: g.size.width / 2, y: ClawdModel.splashBoxTop(H) + 75 - top)
                VStack(spacing: 8) {
                    PlainField(text: $text, focused: $focused, placeholder: "口令", font: Theme.uiUser(17), align: .center, returnKey: .go,
                               textColor: .clear, secure: true, placeholderFont: Theme.uiPixel(12), onSubmit: submit)   // 09-15 寻：文字试像素风（和 Clawd 一族）
                        .frame(height: 24).padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(!error.isEmpty ? Theme.accent : (empty ? Theme.border : Theme.muted)).frame(height: 1) }
                        .frame(width: 180)
                        .disabled(busy || litAt != nil)
                    Text(busy ? "…" : error)
                        .font(Theme.pixel(12))
                        .foregroundStyle(Theme.accent)
                        .frame(height: 18)
                }
                .offset(y: H * 0.51 - top)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
            if Preview.on, Preview.screen == "loginerr" { error = "口令不对" }
            if Preview.on, Preview.screen == "loginlit" { litAt = Date() }
        }
        .onChange(of: text) { _ in if !error.isEmpty { error = "" } }   // 再打字就把红线收回去
    }

    /// 截图班的天：2026-09-15 21:00 东八区
    private static var previewDate: Date {
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 15; c.hour = 21; c.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !busy else { return }
        busy = true; error = ""
        Task {
            let ok = await GatewayAuth.verify(token: t)
            await MainActor.run {
                busy = false
                switch ok {
                case .ok:
                    // 夜里：星座线连完（1.4 秒）再进屋；白天没星，直接进（寻 09-15）
                    focused = false
                    if StarSky.nightness(date: Date(), lat: here.0, lon: here.1) < 0.05 { onSuccess(t); return }
                    litAt = Date()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onSuccess(t) }
                case .wrong: error = "口令不对"
                case .tooMany: error = "试得太频繁，歇一会儿"
                case .offline: error = "连不上"
                }
            }
        }
    }
}

enum GatewayAuth {
    enum Result { case ok, wrong, tooMany, offline }

    static func verify(token: String) async -> Result {
        var req = URLRequest(url: Gateway.home.appendingPathComponent("api/verify"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .offline }
            switch http.statusCode {
            case 200..<300: return .ok
            case 429: return .tooMany
            default: return .wrong
            }
        } catch {
            return .offline
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
