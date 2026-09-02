import SwiftUI

/// SwiftUI 与 UIKit 之间的一层薄桥。WKWebView 的键盘/滚动细节在 UIKit 侧才管得住。
struct ShellView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebShellController {
        WebShellController()
    }

    func updateUIViewController(_ uiViewController: WebShellController, context: Context) {}
}
