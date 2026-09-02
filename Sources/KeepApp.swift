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
                ChatScreen(onLogout: {
                    Keychain.token = nil
                    self.token = nil
                })
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
