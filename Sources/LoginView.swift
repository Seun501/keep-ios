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

    /// 09-15 寻定「试试 2」：口令页＝开屏那张的构图——Clawd 站在屏高 45%，欢迎语的位置换成一根输入线（居中打字、回车即进），
    /// 没有按钮；报错一行赤陶小字在线下固定占位。整块按屏幕坐标钉死、不随键盘挪（键盘起来线还在原处，iPhone 11 上线在键盘上方）。
    var body: some View {
        GeometryReader { g in
            let H = UIScreen.main.bounds.height
            let top = g.frame(in: .global).minY
            ZStack(alignment: .top) {
                Theme.bg.ignoresSafeArea()
                ClawdWeb(state: "idle", flip: false)
                    .frame(width: 150, height: 150)
                    .position(x: g.size.width / 2, y: ClawdModel.splashBoxTop(H) + 75 - top)
                VStack(spacing: 8) {
                    PlainField(text: $text, focused: $focused, placeholder: "口令", font: Theme.uiUser(17), align: .center, returnKey: .go,
                               secure: true, placeholderFont: Theme.uiUser(17), onSubmit: submit)
                        .frame(height: 24).padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Rectangle().fill(error.isEmpty ? (focused ? Theme.muted : Theme.border) : Theme.accent).frame(height: 1) }
                        .frame(width: 180)
                        .disabled(busy)
                    Text(busy ? "…" : error)
                        .font(Theme.serif(12.5))
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
        }
        .onChange(of: text) { _ in if !error.isEmpty { error = "" } }   // 再打字就把红线收回去
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
                case .ok: onSuccess(t)
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
