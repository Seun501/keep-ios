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
        tv.tintColor = Theme.uiScrollTint.withAlphaComponent(0.85)  // 光标赤陶，比滚动条实（寻验 43：40% 太虚；09-04：65% 还虚，再实一点）
        tv.isScrollEnabled = false
        tv.keyboardDismissMode = .interactive
        tv.delegate = context.coordinator
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let ph = UILabel()
        ph.text = "Chat with…"; ph.font = UIFont.systemFont(ofSize: Self.size)   // 占位照原样系统字（寻验 43）
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

/// 单行输入（留言板回复等）：纯 UITextField——iOS 26 的 SwiftUI TextField 自带一圈玻璃发白晕，寻验 43 那圈「阴影边」就是它
struct PlainField: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var placeholder = ""
    var font = UIFont.systemFont(ofSize: 15)
    var align: NSTextAlignment = .natural          // 拨盘打字要居中（寻验 09-04）
    var returnKey: UIReturnKeyType = .send
    var keyboard: UIKeyboardType = .default
    var onSubmit: () -> Void = {}
    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.font = font; tf.textColor = Theme.uiText
        tf.backgroundColor = .clear; tf.borderStyle = .none
        tf.textAlignment = align; tf.keyboardType = keyboard
        tf.tintColor = Theme.uiScrollTint.withAlphaComponent(0.85)
        tf.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(red: 0x7E/255, green: 0x7D/255, blue: 0x77/255, alpha: 1), .font: font])
        tf.returnKeyType = returnKey
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return tf
    }
    func updateUIView(_ tf: UITextField, context: Context) {
        context.coordinator.parent = self
        if tf.text != text { tf.text = text }
        if focused != tf.isFirstResponder {
            DispatchQueue.main.async { if focused { tf.becomeFirstResponder() } else { tf.resignFirstResponder() } }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PlainField
        init(_ p: PlainField) { parent = p }
        @objc func changed(_ tf: UITextField) { if parent.text != tf.text ?? "" { parent.text = tf.text ?? "" } }
        func textFieldDidBeginEditing(_ tf: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ tf: UITextField) { if parent.focused { parent.focused = false } }
        func textFieldShouldReturn(_ tf: UITextField) -> Bool { parent.onSubmit(); return false }
    }
}
