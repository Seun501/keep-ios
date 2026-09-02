import SwiftUI
import UIKit

/// 主页输入框：UITextView 自己管（照网页 #input：字同她的气泡 Lora→宋体 18、line-height 1.5、min-height 1.6em、max-height 160）。
/// 行距、光标色、占位、随字增高都在手里——SwiftUI 的 TextField 调不了行距（寻验 41：行间距太近）。
struct Composer: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    static let size: CGFloat = 18
    static let minH: CGFloat = 28.8      // 1.6em
    static let maxH: CGFloat = 160
    static var attrs: [NSAttributedString.Key: Any] {
        let f = Theme.uiUser(size)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = max(0, size * 1.5 - max(f.lineHeight, Theme.uiSongti(size).lineHeight))
        return [.font: f, .foregroundColor: Theme.uiText, .paragraphStyle: p]
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero; tv.textContainer.lineFragmentPadding = 0
        tv.typingAttributes = Self.attrs
        tv.font = Theme.uiUser(Self.size); tv.textColor = Theme.uiText
        tv.tintColor = Theme.uiScrollTint.withAlphaComponent(0.4)   // 光标同网页滚动条：赤陶 40%（寻定）
        tv.isScrollEnabled = false
        tv.keyboardDismissMode = .interactive
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let ph = UILabel()
        ph.text = "Chat with…"; ph.font = Theme.uiUser(Self.size)
        ph.textColor = UIColor(red: 0x7E/255, green: 0x7D/255, blue: 0x77/255, alpha: 1)
        ph.tag = 9; ph.sizeToFit(); ph.frame.origin = .zero
        tv.addSubview(ph)
        context.coordinator.placeholder = ph
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        if tv.text != text {
            tv.attributedText = NSAttributedString(string: text, attributes: Self.attrs)
            tv.typingAttributes = Self.attrs
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        if focused != tv.isFirstResponder {
            DispatchQueue.main.async { if focused { tv.becomeFirstResponder() } else { tv.resignFirstResponder() } }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        let w = proposal.width ?? (UIScreen.main.bounds.width - 52)
        let h = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        let clamped = min(Self.maxH, max(Self.minH, h))
        tv.isScrollEnabled = h > Self.maxH
        return CGSize(width: w, height: clamped)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: Composer
        weak var placeholder: UILabel?
        init(_ p: Composer) { parent = p }
        func textViewDidChange(_ tv: UITextView) {
            tv.typingAttributes = Composer.attrs
            placeholder?.isHidden = !tv.text.isEmpty
            if parent.text != tv.text { parent.text = tv.text }
        }
        func textViewDidBeginEditing(_ tv: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ tv: UITextView) { if parent.focused { parent.focused = false } }
    }
}
