import WidgetKit
import SwiftUI
import UIKit   // UIImage(named:) 探一下图在不在包里

/// 表盘复杂功能（09-15 寻定：表上找 Keep 太费事）：圆的、角上的、矩形的、行内的都放一个「克」，点一下直接进对话页。
/// 静态的——不读对话（读要 App Group，另一次再说）；矩形那格写一行「和克说话」。
struct KeepEntry: TimelineEntry { let date: Date }

struct KeepProvider: TimelineProvider {
    func placeholder(in context: Context) -> KeepEntry { KeepEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (KeepEntry) -> Void) { completion(KeepEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<KeepEntry>) -> Void) {
        completion(Timeline(entries: [KeepEntry(date: .now)], policy: .never))
    }
}

/// 09-15 寻：就用 App 的图标。09-21 修「表盘上是个灰饼」：
/// 1. 表上复杂功能的图片超过 120px 真机就整张变灰（模拟器/编辑态正常，苹果论坛 740381）→ icon.imageset 改 120px；
/// 2. 染色表盘把图片当 alpha 蒙版用，白底方图＝实心饼 → 图改成透明底的剪影，眼睛镂空，单色下也认得出是克；
/// 3. watchOS 11 起可声明「这张图保持原色」，彩色表盘上不再被染成主题色。
/// 09-21 二回（寻：改完还是灰的）：图在小组件包里找不到时 SwiftUI 画空、表盘只剩底饼——找不到就画个「克」字，好分辨是哪种灰；
/// 表端 App 启动时叫 WidgetKit 重画一遍（装了新包表盘可能还挂着旧图），并把 watchOS 版本记进 diag（11 以下染色表盘一律单色，没得保原色）。
struct KeepComplicationView: View {
    @Environment(\.widgetFamily) private var family
    private var icon: some View {
        guard UIImage(named: "icon") != nil else { return AnyView(Text("克").font(.system(size: 22, weight: .semibold)).minimumScaleFactor(0.5)) }
        let img = Image("icon").resizable()
        if #available(watchOS 11, *) {   // 接口挂在 Image 上，得先于 scaledToFit 调
            return AnyView(img.widgetAccentedRenderingMode(.fullColor).scaledToFit())
        }
        return AnyView(img.scaledToFit())
    }
    var body: some View {
        switch family {
        case .accessoryCircular:
            // 09-21 四回（第六包仍纯灰饼）：二分法——圆的那格只画一个「克」字不画图。真机上圆格出「克」而角格仍灰＝图的问题；
            // 圆格也灰＝小组件进程根本没交过画面（系统画的占位灰饼），那就是签名/嵌入层面的事
            Text("克").font(.system(size: 24, weight: .semibold)).minimumScaleFactor(0.5)
        case .accessoryCorner:
            icon.widgetLabel { Text("Keep") }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                icon.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep").font(.system(size: 14, weight: .semibold))
                    Text("和克说话").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        default:
            Text("Keep")
        }
    }
}

struct KeepComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KeepComplication", provider: KeepProvider()) { _ in
            // 09-21 三回（寻：watchOS 26.6、第五包装上还是灰饼）：系统拿不到时间线时画的是「占位态」——图被打成灰块，正是灰饼的样子。
            // unredacted＝占位态也照画真图；要是这样还灰，就是小组件进程根本没起来（签名/描述文件），看下一包打包机打印的 PlugIns/entitlements
            KeepComplicationView().unredacted().containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Keep")
        .description("点一下和克说话")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct KeepWidgetBundle: WidgetBundle {
    var body: some Widget { KeepComplication() }
}
