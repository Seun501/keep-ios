import SwiftUI

/// 原生口令页（09-02 寻：网页那张难看）。只登一次，口令进钥匙串，此后开 App 直入。
/// 配色照网页 :root——纸色底 #F9F9F7 / 夜 #20201F，深暖棕字，赤陶色钮；不描边（寻不喜欢）。
struct LoginView: View {
    var onSuccess: (String) -> Void

    @State private var text = ""
    @State private var busy = false
    @State private var error = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var bg: Color { scheme == .dark ? Color(hex: 0x20201F) : Color(hex: 0xF9F9F7) }
    private var fg: Color { scheme == .dark ? Color(hex: 0xE8E2D6) : Color(hex: 0x302D27) }
    private var muted: Color { scheme == .dark ? Color(hex: 0x98907F) : Color(hex: 0x9B9183) }
    private var field: Color { scheme == .dark ? Color(hex: 0x2A2A27) : Color(hex: 0xF1EDE7) }
    private let accent = Color(hex: 0xC96442)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                Text("克")
                    .font(.custom("Songti SC", size: 44).weight(.bold))
                    .foregroundStyle(fg)
                    .padding(.bottom, 34)

                SecureField("", text: $text, prompt: Text("口令").foregroundColor(muted.opacity(0.7)))
                    .font(.system(size: 17))
                    .foregroundStyle(fg)
                    .multilineTextAlignment(.center)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.vertical, 14)
                    .frame(maxWidth: 260)
                    .background(field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(accent)
                    .frame(height: 30)

                Button(action: submit) {
                    Text(busy ? "…" : "进")
                        .font(.custom("Songti SC", size: 17).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 44)
                        .background(accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.55 : 1)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 32)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
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
