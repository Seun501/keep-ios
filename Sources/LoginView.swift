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

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Text("克")
                    .font(.custom("Songti SC", size: 44).weight(.bold))
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, 38)

                HStack(spacing: 14) {
                    PlainField(text: $text, focused: $focused, placeholder: "口令", font: Theme.uiSys(16), returnKey: .go, secure: true, onSubmit: submit)
                        .frame(height: 22).padding(.vertical, 6).padding(.horizontal, 2)
                        .overlay(alignment: .bottom) { Rectangle().fill(focused ? Theme.muted : Theme.border).frame(height: 1) }
                    Button(action: submit) {
                        Text(busy ? "…" : "进").font(Theme.round(13)).tracking(1.8).foregroundColor(.white)
                            .padding(.horizontal, 15).padding(.vertical, 5)
                            .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || empty)
                    .opacity(empty ? 0.45 : 1)
                }
                .frame(maxWidth: 230)

                Text(error)
                    .font(Theme.round(12.5))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 22)
                    .padding(.top, 10)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
            if Preview.on, Preview.screen == "loginerr" { error = "口令不对" }
        }
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
