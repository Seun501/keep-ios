import SwiftUI

/// 入口。钥匙串里没口令→原生登录页；有→原生聊天页（09-02 起）。
/// 长尾页（书架/相册/留言板/记忆/档案）从聊天页左上角进网页壳。
@main
struct KeepApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushDelegate
    @State private var token: String? = Preview.on ? "preview" : Keychain.token

    init() {
        // 选中高亮/把手/光标全局同滚动条色（寻 09-02：三者一个色）
        UIView.appearance().tintColor = Theme.uiScrollTint
    }

    var body: some Scene {
        WindowGroup {
            if token != nil {
                // 聊天页装在自己的宿主控制器里：键盘让位交给系统（曲线与键盘一致），
                // 吃吃笺/抽屉打字时用宿主的 safeAreaRegions 开关把让位关掉——主页纹丝不动
                HostBox(content: ChatScreen(onLogout: {
                    Keychain.token = nil
                    self.token = nil
                }))
                .ignoresSafeArea()
            } else {
                LoginView { t in
                    Keychain.token = t
                    self.token = t
                    PushRegistrar.registerIfAuthorized()
                }
            }
        }
    }
}

/// 键盘让位总开关（主页自己的键盘＝开；吃吃笺/抽屉/别的页的键盘＝关）
@MainActor
final class KeyboardAvoid: ObservableObject {
    static let shared = KeyboardAvoid()
    @Published var on = true
}

/// 自己的 UIHostingController：能拨 safeAreaRegions（iOS 16.4+），SwiftUI 顶层的 WindowGroup 宿主拨不到。
struct HostBox<Content: View>: UIViewControllerRepresentable {
    let content: Content
    @ObservedObject private var kb = KeyboardAvoid.shared
    init(content: Content) { self.content = content }
    func makeUIViewController(context: Context) -> UIHostingController<Content> {
        let vc = UIHostingController(rootView: content)
        vc.view.backgroundColor = .clear
        return vc
    }
    func updateUIViewController(_ vc: UIHostingController<Content>, context: Context) {
        vc.rootView = content
        if #available(iOS 16.4, *) {
            let want: SafeAreaRegions = kb.on ? .all : .container
            if vc.safeAreaRegions != want { vc.safeAreaRegions = want }
        }
    }
}
