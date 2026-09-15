import WidgetKit
import SwiftUI

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

/// 09-15 寻：就用 App 的图标（icon.imageset＝AppIcon 缩到 240）。彩色表盘上是原色；单色/染色表盘系统会把它染成主题色。
struct KeepComplicationView: View {
    @Environment(\.widgetFamily) private var family
    private var icon: some View { Image("icon").resizable().scaledToFill().clipShape(Circle()) }
    var body: some View {
        switch family {
        case .accessoryCircular:
            icon
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
            KeepComplicationView().containerBackground(for: .widget) { Color.clear }
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
