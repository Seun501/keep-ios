import UIKit

/// 掉帧仪（09-25 寻「有时候有点卡顿，开其他软件也没 Keep 卡」）：克回话那段和她滑动那段各挂一只 CADisplayLink 量帧间隔，
/// 一段结束就把时长 / 最大空帧 / 超 50ms 的帧数写进诊断（journal 里 `[apns-diag] iPhone: jank …`）。
/// 只量不改：先看清到底是流式重算在卡还是滑动在卡，改完还能前后对比。滑动那段短于半秒或一帧没掉的不报，别刷日志。
final class JankMeter {
    static let shared = JankMeter()
    private var link: CADisplayLink?
    private var tag = ""
    private var last: CFTimeInterval = 0
    private var start: CFTimeInterval = 0
    private var maxGap = 0.0, big = 0, frames = 0
    private var scrollStop: DispatchWorkItem?

    /// 克在回话（sending 起落）
    func streaming(_ on: Bool) {
        if on { begin("stream") } else if tag == "stream" { end() }   // 滑动那段在量就不管
    }
    /// 滚动区每次偏移变化叫一声；0.4 秒没再叫＝滑完了
    func scrolled() {
        if tag.isEmpty { begin("scroll") }
        guard tag == "scroll" else { return }
        scrollStop?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.end() }
        scrollStop = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func begin(_ t: String) {
        guard link == nil else { return }
        tag = t; maxGap = 0; big = 0; frames = 0; last = 0; start = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }
    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 {
            let gap = (l.timestamp - last) * 1000
            if gap > maxGap { maxGap = gap }
            if gap > 50 { big += 1 }
        }
        last = l.timestamp; frames += 1
    }
    private func end() {
        guard let l = link else { return }
        l.invalidate(); link = nil
        let dur = CACurrentMediaTime() - start
        if tag == "stream" || (dur >= 0.5 && big > 0) {
            PushRegistrar.diag(String(format: "jank %@: %.1fs maxgap=%.0fms big=%d frames=%d", tag, dur, maxGap, big, frames))
        }
        tag = ""
    }
}
