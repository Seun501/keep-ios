import SwiftUI

/// 入口。第一版＝原生壳：全屏承载 ke.seunk.cn，键盘由原生接管。
/// 口令页原生（09-02）：钥匙串里没口令→原生登录页；有→直接进壳，壳把口令种进网页 localStorage。
/// 后续原生页（聊天流/输入/推送）逐页替换壳里的网页，壳留作长尾页面的落脚处。
@main
struct KeepApp: App {
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushDelegate
    @State private var token: String? = Keychain.token

    var body: some Scene {
        WindowGroup {
            if let token {
                ShellView(token: token, onLogout: {
                    Keychain.token = nil
                    self.token = nil
                })
                .ignoresSafeArea()              // 网页自己按 env(safe-area-inset-*) 排版
                .ignoresSafeArea(.keyboard)     // 键盘避让由 WebShellController 自己算，不让 SwiftUI 插手
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
