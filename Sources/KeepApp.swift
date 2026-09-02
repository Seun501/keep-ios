import SwiftUI

/// 入口。第一版＝原生壳：全屏承载 ke.seunk.cn，键盘由原生接管。
/// 后续原生页（聊天流/输入/推送）逐页替换壳里的网页，壳留作长尾页面的落脚处。
@main
struct KeepApp: App {
    var body: some Scene {
        WindowGroup {
            ShellView()
                .ignoresSafeArea()              // 网页自己按 env(safe-area-inset-*) 排版
                .ignoresSafeArea(.keyboard)     // 键盘避让由 WebShellController 自己算，不让 SwiftUI 插手
        }
    }
}
