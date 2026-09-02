import SwiftUI
import PhotosUI

/// 吃饭钮的横笺（照网页 #mealSheet/.strip）：暗幕、白笺 344 宽 16 圆角、赤陶碗＋粗宋「吃吃」、四餐横排、
/// 一行输入（Eating…）＋圆框＋＋赤陶圆钮；附图整张挂在笺底下，×撤掉。点笺外退出。
struct MealSheet: View {
    @Binding var shown: Bool
    var onSent: (String) -> Void          // 就地回显那行文案
    @State private var kind = ""
    @State private var text = ""
    @State private var image: String? = nil
    @State private var pick: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    private let strip = Color(red: 0xFC/255, green: 0xFA/255, blue: 0xF6/255)

    var body: some View {
        ZStack {
            Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.38).ignoresSafeArea()
                .onTapGesture { shown = false }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Image("bowl").renderingMode(.template).resizable().frame(width: 19, height: 19).foregroundColor(Theme.accent)
                        Text("吃吃").font(Theme.cjk(16.5, weight: .bold)).tracking(1.6).foregroundColor(Theme.text)
                    }
                    HStack {
                        ForEach(["早餐", "午餐", "晚餐", "零食"], id: \.self) { k in
                            let sel = kind == k
                            Button { kind = sel ? "" : k } label: {
                                Text(k).font(Theme.cjk(13.5, weight: sel ? .bold : .regular))
                                    .foregroundColor(sel ? Theme.accent : Theme.muted)
                                    .padding(.horizontal, 1).padding(.vertical, 2)
                                    .overlay(alignment: .bottom) { Rectangle().fill(sel ? Theme.accent : .clear).frame(height: 1) }
                            }.buttonStyle(.plain)
                            if k != "零食" { Spacer() }
                        }
                    }
                    .padding(.horizontal, 4).padding(.top, 13).padding(.bottom, 6)
                    HStack(spacing: 10) {
                        TextField("", text: $text, prompt: Text("Eating…").foregroundColor(Theme.muted.opacity(0.6)))
                            .font(Theme.round(13.5)).foregroundColor(Theme.text)
                            .focused($focused)
                            .padding(.vertical, 7).padding(.horizontal, 2)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        PhotosPicker(selection: $pick, maxSelectionCount: 1, matching: .images) {
                            Text("＋").font(.system(size: 16)).foregroundColor(Theme.muted)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                        }
                        Button(action: send) {
                            Image("mealSend").renderingMode(.template).resizable().frame(width: 14, height: 14).foregroundColor(.white)
                                .frame(width: 28, height: 28).background(Theme.accent, in: Circle())
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(EdgeInsets(top: 19, leading: 21, bottom: 18, trailing: 21))
                .frame(width: min(UIScreen.main.bounds.width * 0.88, 344), alignment: .leading)
                .background(strip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .shadow(color: Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.26), radius: 24, y: 16)

                if let image {
                    ZStack(alignment: .topTrailing) {
                        DataImage(src: image, maxW: 150, maxH: 130, radius: 16)
                            .shadow(color: Color(red: 48/255, green: 45/255, blue: 39/255).opacity(0.22), radius: 15, y: 10)
                        Button { self.image = nil } label: {
                            Text("×").font(Theme.round(12)).foregroundColor(Theme.bg)
                                .frame(width: 18, height: 18).background(Theme.text, in: Circle())
                        }.offset(x: 6, y: -6)
                    }
                    .padding(.leading, 6)
                }
            }
        }
        .onChange(of: pick) { _ in Task { await loadPick() } }

    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any] = ["text": t, "kind": kind]
        if let image { body["image"] = image }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let line = f.string(from: Date()) + (kind.isEmpty ? "-寻吃过了" : "-寻吃了\(kind)") + (t.isEmpty ? "" : "：\(t)")
        shown = false
        Task {
            guard let token = Keychain.token else { return }
            var r = URLRequest(url: Gateway.home.appendingPathComponent("api/meal"))
            r.httpMethod = "POST"
            r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: r)
            onSent(line)
        }
    }

    private func loadPick() async {
        guard let p = pick.first, let data = try? await p.loadTransferable(type: Data.self), let ui = UIImage(data: data) else { pick = []; return }
        let L: CGFloat = 1568
        let s = min(1, L / max(ui.size.width, ui.size.height))
        let size = CGSize(width: (ui.size.width * s).rounded(), height: (ui.size.height * s).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in ui.draw(in: CGRect(origin: .zero, size: size)) }
        if let jpg = img.jpegData(compressionQuality: 0.85) { image = "data:image/jpeg;base64," + jpg.base64EncodedString() }
        pick = []
    }
}
