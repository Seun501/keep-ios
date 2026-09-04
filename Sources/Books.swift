import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书架与新书上架（照 static/bookshelf-ui.js/.css：纸色、赤陶、衬线，不做后台面板）

struct Book: Decodable, Identifiable {
    var id: String
    var workId: String?
    var title: String?
    var author: String?
    var editionLabel: String?
    var category: String?
    var tags: [String]?
    var totalPages: Int?
    enum CodingKeys: String, CodingKey { case id, title, author, category, tags, workId = "work_id", editionLabel = "edition_label", totalPages = "total_pages" }
}
struct BooksPayload: Decodable { var books: [Book]?; var categories: [String]? }

struct Batch: Decodable {
    struct File: Decodable, Identifiable { var id: String; var filename: String?; var format: String?; var size: Int? }
    struct Report: Decodable {
        struct RBook: Decodable, Identifiable {
            struct Quality: Decodable { struct Ocr: Decodable { var pending: Int? }
                var status: String?; var visibleChars: Int?; var summary: String?; var ocr: Ocr?
                enum CodingKeys: String, CodingKey { case status, summary, ocr, visibleChars = "visible_chars" } }
            struct OcrReview: Decodable { var pending: Int? }
            var id: String; var title: String?; var sourceFilename: String?; var author: String?; var editionLabel: String?
            var totalPages: Int?; var quality: Quality?; var ocrReview: OcrReview?; var samples: [String: String]?
            enum CodingKeys: String, CodingKey { case id, title, author, quality, samples, sourceFilename = "source_filename", editionLabel = "edition_label", totalPages = "total_pages", ocrReview = "ocr_review" }
        }
        struct Comparison: Decodable { var to: String?; var charDelta: Int?; var paragraphOverlap: Double?
            enum CodingKeys: String, CodingKey { case to, charDelta = "char_delta", paragraphOverlap = "paragraph_overlap" } }
        struct Failed: Decodable { var filename: String?; var error: String? }
        var books: [RBook]?; var recommendedId: String?; var versionCount: Int?; var comparisons: [Comparison]?; var failedFiles: [Failed]?
        enum CodingKeys: String, CodingKey { case books, comparisons, recommendedId = "recommended_id", versionCount = "version_count", failedFiles = "failed_files" }
    }
    var id: String
    var status: String?
    var files: [File]?
    var error: String?
    var report: Report?
}
struct BatchWrap: Decodable { var batch: Batch? }
struct OcrItem: Decodable, Identifiable { var id: String; var text: String?; var reason: String?; var sourcePage: Int?
    enum CodingKeys: String, CodingKey { case id, text, reason, sourcePage = "source_page" } }
struct OcrPayload: Decodable { var items: [OcrItem]? }

@MainActor
final class BooksModel: ObservableObject {
    enum Mode { case shelf, upload, working(String, String), error(String, canReject: Bool), report, ocr(String) }
    @Published var books: [Book] = []
    @Published var categories: [String] = []
    @Published var mode: Mode = .shelf
    @Published var loaded = false
    @Published var category = "全部"
    @Published var batch: Batch? = nil
    @Published var pending: [(name: String, data: Data)] = []
    @Published var selected: Set<String> = []
    @Published var rejectArmed = false
    @Published var ocrItems: [OcrItem] = []
    @Published var ocrTexts: [String: String] = [:]
    private var run = 0

    static let supported: Set<String> = ["epub", "mobi", "azw", "azw3", "fb2", "pdf", "txt", "md"]

    private func api(_ path: String, method: String = "GET", body: Data? = nil, json: Bool = false) async throws -> Data {
        guard let token = Keychain.token else { throw GatewayAPI.Failure.unauthorized }
        // 带 ?filename= 的地址不能走 appendingPathComponent——它会把 ? 编成 %3F 当路径，服务器答 Not Found（寻验 09-04：传 epub 显示 Not Found）
        let url: URL = path.contains("?") ? (URL(string: path, relativeTo: Gateway.home)?.absoluteURL ?? Gateway.home.appendingPathComponent(path))
                                          : Gateway.home.appendingPathComponent(path)
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if json { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        r.httpBody = body; r.timeoutInterval = 600
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw GatewayAPI.Failure.unauthorized }
        guard (200..<300).contains(code) else {
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            throw NSError(domain: "keep", code: code, userInfo: [NSLocalizedDescriptionKey: (j?["detail"] as? String) ?? (j?["error"] as? String) ?? "服务器返回 \(code)"])
        }
        return d
    }

    func loadBooks() async {
        if Preview.on {
            if let d = Preview.json("preview_books"), let p = try? JSONDecoder().decode(BooksPayload.self, from: d) { books = p.books ?? []; categories = p.categories ?? [] }
            loaded = true; mode = .shelf; return
        }
        do {
            let p = try JSONDecoder().decode(BooksPayload.self, from: try await api("api/books"))
            books = p.books ?? []; categories = p.categories ?? []; loaded = true; mode = .shelf
        } catch { mode = .error(error.localizedDescription, canReject: false) }
    }
    var workCount: Int { Set(books.map { $0.workId ?? $0.id }).count }
    /// 同一作品的多个版本归一组
    func groups(_ items: [Book]) -> [[Book]] {
        var order: [String] = []; var map: [String: [Book]] = [:]
        for b in items { let k = b.workId ?? b.id; if map[k] == nil { order.append(k); map[k] = [] }; map[k]!.append(b) }
        return order.map { map[$0]! }
    }

    // MARK: 上架
    func openUpload() async {
        run += 1
        pending = []; batch = nil
        mode = .working("看看有没有没走完的上架工作…", "")
        do {
            let w = try JSONDecoder().decode(BatchWrap.self, from: try await api("api/books/staging/current"))
            batch = w.batch
            if let b = batch, b.status == "ready" { mode = .report; selected = [b.report?.recommendedId ?? ""] }
            else if let b = batch, b.status == "inspecting" { mode = .working("正在转换和验书…", ""); poll(b.id, run) }
            else if let b = batch, b.status == "error" { mode = .error(b.error ?? "验书没有完成", canReject: true) }
            else { mode = .upload }
        } catch { mode = .error(error.localizedDescription, canReject: false) }
    }
    private func poll(_ id: String, _ r: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, r == self.run, case .working = self.mode else { return }
            Task {
                do {
                    let b = try JSONDecoder().decode(Batch.self, from: try await self.api("api/books/staging/\(id)"))
                    self.batch = b
                    if b.status == "ready" { self.mode = .report; self.selected = [b.report?.recommendedId ?? ""] }
                    else if b.status == "error" { self.mode = .error(b.error ?? "验书没有完成", canReject: true) }
                    else { self.poll(id, r) }
                } catch { self.mode = .error(error.localizedDescription, canReject: true) }
            }
        }
    }
    var serverFiles: [Batch.File] { (batch.map { ["draft", "uploaded"].contains($0.status ?? "") } ?? false) ? (batch?.files ?? []) : [] }
    func addPending(_ urls: [URL]) {
        for u in urls {
            let ext = u.pathExtension.lowercased()
            guard Self.supported.contains(ext) else { continue }
            let ok = u.startAccessingSecurityScopedResource()
            defer { if ok { u.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: u), !pending.contains(where: { $0.name == u.lastPathComponent && $0.data.count == d.count }) {
                pending.append((u.lastPathComponent, d))
            }
        }
    }
    func removeServerFile(_ fid: String) async {
        guard let b = batch else { return }
        do { batch = try JSONDecoder().decode(Batch.self, from: try await api("api/books/staging/\(b.id)/file/\(fid)", method: "DELETE")) }
        catch { mode = .error(error.localizedDescription, canReject: true) }
    }
    func startInspection() async {
        guard !pending.isEmpty || !serverFiles.isEmpty else { return }
        run += 1; let r = run
        do {
            if !(batch.map { ["draft", "uploaded"].contains($0.status ?? "") } ?? false) {
                batch = try JSONDecoder().decode(Batch.self, from: try await api("api/books/staging", method: "POST"))
            }
            guard let b = batch else { return }
            for (i, f) in pending.enumerated() {
                mode = .working("正在收好原书…", "\(i + 1)/\(pending.count)　\(f.name)")
                _ = try await api("api/books/staging/\(b.id)/file?filename=" + (f.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? f.name), method: "PUT", body: f.data)
                if r != run { return }
            }
            pending = []
            await inspect()
        } catch { if r == run { mode = .error(error.localizedDescription, canReject: batch != nil) } }
    }
    func inspect() async {
        guard let b = batch else { await openUpload(); return }
        run += 1; let r = run
        mode = .working("正在转换和验书…", "排页、检查结构，也会对照不同版本")
        do {
            batch = try JSONDecoder().decode(Batch.self, from: try await api("api/books/staging/\(b.id)/inspect", method: "POST"))
            guard r == run else { return }
            mode = .report; selected = [batch?.report?.recommendedId ?? ""]
        } catch {
            guard r == run else { return }
            if let d = try? await api("api/books/staging/\(b.id)"), let bb = try? JSONDecoder().decode(Batch.self, from: d) { batch = bb }
            mode = .error(error.localizedDescription, canReject: true)
        }
    }
    func reject() async {
        guard let b = batch else { mode = .upload; return }
        if !rejectArmed { rejectArmed = true; return }
        mode = .working("正在把这批书退回暂存区…", "")
        do { _ = try await api("api/books/staging/\(b.id)/reject", method: "POST"); batch = nil; pending = []; rejectArmed = false; await loadBooks() }
        catch { mode = .error(error.localizedDescription, canReject: true) }
    }
    func publish(category: String, tags: String, sameWork: Bool) async -> String? {
        guard let b = batch else { return nil }
        if selected.isEmpty { return "至少勾选一个版本上架。" }
        let t = tags.components(separatedBy: CharacterSet(charactersIn: "，,")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        mode = .working("正在上架…", "原文件、书架页和验书结果都会收好")
        do {
            let body = try JSONSerialization.data(withJSONObject: ["selected_ids": Array(selected), "category": category, "tags": t, "same_work": sameWork])
            _ = try await api("api/books/staging/\(b.id)/publish", method: "POST", body: body, json: true)
            batch = nil; pending = []; await loadBooks(); return nil
        } catch { mode = .report; return error.localizedDescription }
    }
    func openOcr(_ bookId: String) async {
        guard let b = batch else { return }
        mode = .working("正在拿校对稿…", "")
        do {
            let p = try JSONDecoder().decode(OcrPayload.self, from: try await api("api/books/staging/\(b.id)/ocr/\(bookId)"))
            ocrItems = p.items ?? []; ocrTexts = Dictionary(uniqueKeysWithValues: ocrItems.map { ($0.id, $0.text ?? "") })
            mode = .ocr(bookId)
        } catch { mode = .error(error.localizedDescription, canReject: true) }
    }
    func saveOcr(_ bookId: String) async {
        guard let b = batch else { return }
        mode = .working("正在重新排书架页…", "校对内容会替换 OCR 初稿")
        do {
            let items = ocrItems.map { ["id": $0.id, "text": ocrTexts[$0.id] ?? ""] }
            let body = try JSONSerialization.data(withJSONObject: ["items": items])
            let w = try JSONDecoder().decode(BatchWrap.self, from: try await api("api/books/staging/\(b.id)/ocr/\(bookId)", method: "POST", body: body, json: true))
            if let nb = w.batch { batch = nb }
            mode = .report
        } catch { mode = .error(error.localizedDescription, canReject: true) }
    }
}

struct BooksScreen: View {
    var onBack: () -> Void
    @StateObject private var m = BooksModel()
    @State private var picking = false
    @State private var pubCategory = ""
    @State private var pubTags = ""
    @State private var pubSame = true
    @State private var pubError = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { back() } label: { Text("‹").font(.system(size: 26)).foregroundColor(Theme.muted).frame(width: 34, height: 34) }.buttonStyle(.plain).padding(.leading, -8)
                    Text(title).font(Theme.round(14)).foregroundColor(Theme.muted).lineLimit(1)
                    Spacer()
                    if case .shelf = m.mode {   // 新书上架
                        Button { Task { await m.openUpload() } } label: { Text("+").font(.system(size: 27, weight: .light)).foregroundColor(Theme.text).frame(width: 34, height: 34) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8).frame(minHeight: 52)
                OrangeScroll(name: "books") {
                    Group {
                        switch m.mode {
                        case .shelf: shelf
                        case .upload: picker
                        case .working(let t, let d): status(t, d)
                        case .error(let msg, let canReject): errorView(msg, canReject)
                        case .report: report
                        case .ocr(let id): ocr(id)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
                }
            }
        }
        .background(EdgeSwipe(onBack: back))
        .fileImporter(isPresented: $picking, allowedContentTypes: [.epub, .pdf, .plainText, UTType(filenameExtension: "mobi") ?? .data, UTType(filenameExtension: "azw3") ?? .data, UTType(filenameExtension: "fb2") ?? .data, UTType(filenameExtension: "md") ?? .plainText, .data], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { m.addPending(urls) }
        }
        .task {
            await m.loadBooks()
            if Preview.on && Preview.screen == "booksup" { m.mode = .upload }
        }
    }
    private var title: String {
        switch m.mode { case .shelf: return ""; case .ocr: return "校对扫描文字"; case .report: return "验书"; default: return "新书上架" }
    }
    private func back() {
        switch m.mode {
        case .shelf: onBack()
        case .ocr: m.mode = .report
        default: m.mode = .shelf
        }
    }

    // MARK: 书架
    @ViewBuilder private var shelf: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("书架").font(.system(size: 29, weight: .semibold)).foregroundColor(Theme.text)
            Text(m.books.isEmpty ? "给克，也给以后在这里读书的你" : "已经上架 \(m.workCount) 本书").font(Theme.round(13.5)).foregroundColor(Theme.muted).padding(.top, 5)
        }
        .padding(EdgeInsets(top: 8, leading: 2, bottom: 22, trailing: 2))
        .frame(maxWidth: .infinity, alignment: .leading)
        if m.books.isEmpty {
            if m.loaded { emptyBig("还没有书", "点右上角的＋，上架第一本吧") } else { status("正在翻书架…", "") }
        } else {
            let cats = ["全部"] + Array(NSOrderedSet(array: m.books.map { $0.category ?? "未分类" })).compactMap { $0 as? String }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(cats, id: \.self) { c in
                        let on = c == m.category
                        Text(c).font(Theme.round(12.5)).foregroundColor(on ? Theme.text : Theme.muted)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(on ? Theme.userBubble : .clear, in: Capsule())
                            .overlay(Capsule().stroke(on ? Theme.text : Theme.border, lineWidth: 1))
                            .onTapGesture { m.category = c }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 2)
            }
            .padding(.horizontal, -16).padding(.bottom, 20)
            let shown = m.category == "全部" ? m.books : m.books.filter { ($0.category ?? "未分类") == m.category }
            let byCat = Dictionary(grouping: m.groups(shown), by: { $0[0].category ?? "未分类" })
            let catOrder = Array(NSOrderedSet(array: m.groups(shown).map { $0[0].category ?? "未分类" })).compactMap { $0 as? String }
            ForEach(catOrder, id: \.self) { cat in
                VStack(alignment: .leading, spacing: 10) {
                    Text(cat).font(Theme.round(12)).tracking(1).foregroundColor(Theme.muted).padding(.horizontal, 2)
                    ForEach(Array((byCat[cat] ?? []).enumerated()), id: \.offset) { i, g in card(g, index: i) }
                }
                .padding(.bottom, 25)
            }
            if shown.isEmpty { emptyBig("这一格还是空的", "换个分类看看") }
        }
    }
    private func card(_ g: [Book], index: Int) -> some View {
        let b = g[0]
        var tags: [String] = []
        if g.count > 1 { tags.append("\(g.count) 个版本") }
        if let p = b.totalPages, p > 0 { tags.append("\(p) 页") }
        tags += (b.tags ?? []).prefix(2)
        let glyph = String((b.title ?? "书").replacingOccurrences(of: "[《》：:·\\s]", with: "", options: .regularExpression).prefix(1)).isEmpty ? "书" : String((b.title ?? "书").replacingOccurrences(of: "[《》：:·\\s]", with: "", options: .regularExpression).prefix(1))
        return HStack(spacing: 13) {
            Text(glyph).font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
                .frame(width: 52, height: 70)
                .background(index % 3 == 0 ? Color(red: 0x8C/255, green: 0x83/255, blue: 0x74/255) : Color(red: 0xB9/255, green: 0x79/255, blue: 0x62/255),
                            in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5, bottomTrailingRadius: 10, topTrailingRadius: 10))
                .overlay(alignment: .leading) { Rectangle().fill(Wax.ink.opacity(0.12)).frame(width: 4).clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5)) }
            VStack(alignment: .leading, spacing: 0) {
                Text(b.title ?? "未命名").font(.system(size: 16, weight: .semibold)).lineSpacing(3).foregroundColor(Theme.text)
                Text(b.author ?? b.editionLabel ?? "作者未录入").font(Theme.round(12.5)).foregroundColor(Theme.muted).padding(.top, 4)
                if !tags.isEmpty {
                    HStack(spacing: 5) { ForEach(tags, id: \.self) { t in Text(t).font(Theme.round(11)).foregroundColor(Theme.muted).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.bg, in: Capsule()) } }.padding(.top, 7)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .shadow(color: Wax.ink.opacity(0.05), radius: 2, y: 1)
    }
    private func emptyBig(_ a: String, _ b: String) -> some View {
        VStack(spacing: 5) { Text(a).font(.system(size: 19)).foregroundColor(Theme.text); Text(b).font(Theme.round(13)).foregroundColor(Theme.muted) }
            .frame(maxWidth: .infinity).padding(.top, UIScreen.main.bounds.height * 0.26)
    }
    private func status(_ t: String, _ d: String) -> some View {
        VStack(spacing: 0) {
            ProgressView().tint(Theme.accent).padding(.bottom, 15)
            Text(t).font(Theme.round(14)).lineSpacing(6).foregroundColor(Theme.muted)
            if !d.isEmpty { Text(d).font(Theme.round(12)).foregroundColor(Theme.muted).padding(.top, 7) }
        }
        .frame(maxWidth: 320).frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, UIScreen.main.bounds.height * 0.24)
    }
    private func lead(_ h: String, _ p: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(h).font(.system(size: 25, weight: .semibold)).foregroundColor(Theme.text)
            Text(p).font(Theme.round(13.5)).lineSpacing(5).foregroundColor(Theme.muted)
        }.padding(EdgeInsets(top: 7, leading: 2, bottom: 18, trailing: 2)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func btn(_ t: String, primary: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(Theme.round(14)).foregroundColor(primary ? .white : Theme.text)
                .frame(maxWidth: primary ? .infinity : nil).frame(minHeight: 44).padding(.horizontal, 18)
                .background(primary ? Theme.accent : .clear, in: Capsule())
                .overlay(Capsule().stroke(primary ? Theme.accent : Theme.border, lineWidth: 1))
                .opacity(disabled ? 0.4 : 1)
        }.buttonStyle(.plain).disabled(disabled)
    }
    private func errorView(_ msg: String, _ canReject: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            lead("这里需要看一眼", "正式书架没有被改动。")
            Text(msg).font(Theme.round(13)).lineSpacing(4).foregroundColor(Theme.dyn(0xA54E38, 0xE2A18B))
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15)).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            HStack(spacing: 9) {
                if canReject && m.batch != nil { btn(m.rejectArmed ? "确认打回" : "打回") { Task { await m.reject() } } }
                btn("再试一次", primary: true) { Task { await m.openUpload() } }
            }.padding(.top, 18)
        }
    }

    // MARK: 上架：挑文件
    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            lead("新书上架", "可以一次放进同一本书的多个版本。先转换验书，确认后才会出现在正式书架。")
            VStack(spacing: 0) {
                Text("+").font(.system(size: 35, weight: .light)).foregroundColor(Theme.accent)
                Text("选择电子书").font(.system(size: 16)).foregroundColor(Theme.text).padding(.top, 9)
                Text("EPUB · MOBI · AZW3 · FB2 · PDF · TXT\n单个不超过 120 MB，一次最多 8 个版本").font(Theme.round(12)).lineSpacing(4).multilineTextAlignment(.center).foregroundColor(Theme.muted).padding(.top, 5)
            }
            .frame(maxWidth: .infinity).frame(minHeight: 170).padding(EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20))
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundColor(Theme.border))
            .contentShape(Rectangle())
            .onTapGesture { picking = true }
            let files = m.serverFiles
            if !files.isEmpty || !m.pending.isEmpty {
                VStack(spacing: 8) {
                    ForEach(files) { f in fileRow(f.format ?? (f.filename ?? "").components(separatedBy: ".").last?.uppercased() ?? "", f.filename ?? "", f.size ?? 0) { Task { await m.removeServerFile(f.id) } } }
                    ForEach(Array(m.pending.enumerated()), id: \.offset) { i, f in fileRow(f.name.components(separatedBy: ".").last?.uppercased() ?? "", f.name, f.data.count) { m.pending.remove(at: i) } }
                }.padding(.top, 14)
            }
            HStack(spacing: 9) {
                if m.batch != nil { btn(m.rejectArmed ? "确认打回" : "打回") { Task { await m.reject() } } }
                btn("开始验书", primary: true, disabled: files.isEmpty && m.pending.isEmpty) { Task { await m.startInspection() } }
            }.padding(.top, 18)
        }
    }
    private func fileRow(_ fmt: String, _ name: String, _ size: Int, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(fmt).font(Theme.round(12)).foregroundColor(Theme.accent).frame(minWidth: 36, alignment: .leading)
            Text(name).font(.system(size: 13.5)).foregroundColor(Theme.text).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(sizeText(size)).font(Theme.round(11)).foregroundColor(Theme.muted)
            Button(action: remove) { Text("×").font(.system(size: 18)).foregroundColor(Theme.muted).padding(.horizontal, 4).padding(.vertical, 2) }.buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    private func sizeText(_ n: Int) -> String {
        if n < 1024 * 1024 { return "\(max(1, Int((Double(n) / 1024).rounded()))) KB" }
        let mb = Double(n) / 1024 / 1024
        return n > 10 * 1024 * 1024 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
    }

    // MARK: 验书报告
    @ViewBuilder private var report: some View {
        if let b = m.batch, let r = b.report {
            let ocrPending = (r.books ?? []).reduce(0) { $0 + ($1.ocrReview?.pending ?? 0) }
            let vc = r.versionCount ?? 1
            VStack(alignment: .leading, spacing: 0) {
                lead("验书完成", (vc > 1 ? "找到了 \(vc) 个版本。勾选真正想上架的版本；建议只是建议，你来定。" : "这本书已经转换成书架页，确认后才会正式上架。")
                     + ((r.failedFiles ?? []).isEmpty ? "" : "\n另有 \((r.failedFiles ?? []).count) 个版本未能转换，已单独标出。")
                     + (ocrPending > 0 ? "\n扫描版已经生成文字初稿；其中 \(ocrPending) 行被标为待校对，校对完成前不会误上架。" : ""))
                VStack(spacing: 10) {
                    ForEach(r.books ?? []) { bk in
                        VStack(alignment: .trailing, spacing: 7) {
                            versionCard(bk, recommended: bk.id == r.recommendedId)
                            if let p = bk.ocrReview?.pending, p > 0 {
                                Button { Task { await m.openOcr(bk.id) } } label: { Text("校对 \(p) 行").font(Theme.round(12.5)).foregroundColor(Theme.accent) }.buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(Array((r.failedFiles ?? []).enumerated()), id: \.offset) { _, f in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.filename ?? "未命名版本").font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                            Text("这个版本没有转换成功，不会妨碍其他版本继续上架。").font(Theme.round(12)).foregroundColor(Theme.muted)
                            Text(f.error ?? "文件可能已损坏").font(Theme.round(12)).foregroundColor(Theme.dyn(0xA54E38, 0xE2A18B))
                        }
                        .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 15)).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundColor(Theme.border))
                    }
                }
                if vc > 1, let cs = r.comparisons, !cs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(cs.enumerated()), id: \.offset) { _, c in
                            let other = (r.books ?? []).first { $0.id == c.to }
                            let delta = c.charDelta ?? 0
                            let overlap = c.paragraphOverlap.map { "完全相同段落约 \(Int(($0 * 100).rounded()))%" } ?? "无法按段落对齐"
                            (Text(other?.sourceFilename ?? other?.title ?? "另一个版本").bold() + Text("：比推荐版本\(delta >= 0 ? "多 " : "少 ")\(abs(delta)) 字，\(overlap)。"))
                                .font(Theme.round(12.5)).lineSpacing(4).foregroundColor(Theme.muted)
                        }
                    }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
                    .padding(.top, 13)
                }
                VStack(spacing: 0) {
                    ForEach(r.books ?? []) { bk in SampleDisclosure(bk: bk) }
                }.padding(.top, 15)
                VStack(alignment: .leading, spacing: 11) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("主要分类").font(Theme.round(12)).foregroundColor(Theme.muted).padding(.leading, 2)
                        Menu {
                            Button("未分类") { pubCategory = "" }
                            ForEach(m.categories, id: \.self) { c in Button(c) { pubCategory = c } }
                        } label: {
                            HStack { Text(pubCategory.isEmpty ? "未分类" : pubCategory).font(Theme.round(14)).foregroundColor(Theme.text); Spacer(); Text("▾").font(Theme.round(12)).foregroundColor(Theme.muted) }
                                .padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("标签（用逗号隔开）").font(Theme.round(12)).foregroundColor(Theme.muted).padding(.leading, 2)
                        PlainField(text: $pubTags, focused: .constant(false), placeholder: "例如：共读，唯识，待读", font: UIFont.systemFont(ofSize: 14))
                            .frame(height: 18).padding(EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    }
                    if vc > 1 {
                        HStack(spacing: 9) {
                            Image(systemName: pubSame ? "checkmark.square.fill" : "square").foregroundColor(pubSame ? Theme.accent : Theme.border)
                            Text("这些文件属于同一本作品的不同版本").font(Theme.round(12.5)).foregroundColor(Theme.muted)
                        }.contentShape(Rectangle()).onTapGesture { pubSame.toggle() }
                    }
                }.padding(.top, 20)
                if !pubError.isEmpty {
                    Text(pubError).font(Theme.round(13)).foregroundColor(Theme.dyn(0xA54E38, 0xE2A18B))
                        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15)).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous)).padding(.top, 16)
                }
                HStack(spacing: 9) {
                    btn(m.rejectArmed ? "确认打回" : "打回") { Task { await m.reject() } }
                    btn(ocrPending > 0 ? "待校对" : "上架", primary: true, disabled: ocrPending > 0) {
                        Task { pubError = await m.publish(category: pubCategory, tags: pubTags, sameWork: pubSame) ?? "" }
                    }
                }.padding(.top, 18)
            }
        } else { errorView("没有找到验书报告", true) }
    }
    private func versionCard(_ bk: Batch.Report.RBook, recommended: Bool) -> some View {
        let on = m.selected.contains(bk.id)
        let q = bk.quality
        return VStack(alignment: .leading, spacing: 3) {
            Text(bk.title ?? "未命名").font(.system(size: 16, weight: .semibold)).lineSpacing(3).foregroundColor(Theme.text)
            Text(bk.sourceFilename ?? "").font(Theme.round(12)).foregroundColor(Theme.muted)
            Text((bk.author ?? "作者未录入") + (bk.editionLabel.map { " · " + $0 } ?? "")).font(Theme.round(12)).foregroundColor(Theme.muted)
            if recommended { Text("建议采用").font(Theme.round(12)).foregroundColor(Theme.accent) }
            HStack(spacing: 6) {
                pill(q?.status ?? "未验", warn: q?.status == "有疑点", hint: q?.status == "有提示")
                pill("\(q?.visibleChars ?? 0) 字"); pill("\(bk.totalPages ?? 0) 页")
                if let p = q?.ocr?.pending, p > 0 { pill("待校 \(p) 行", warn: true) }
            }.padding(.top, 6)
            if let s = q?.summary, !s.isEmpty { Text(s).font(Theme.round(12)).lineSpacing(3).foregroundColor(Theme.muted) }
        }
        .padding(EdgeInsets(top: 14, leading: 15, bottom: 14, trailing: 42)).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            ZStack { RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent : .clear); RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.accent : Theme.border, lineWidth: 1.5); if on { Text("✓").font(.system(size: 13, weight: .semibold)).foregroundColor(.white) } }
                .frame(width: 20, height: 20).padding(.top, 15).padding(.trailing, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture { if on { m.selected.remove(bk.id) } else { m.selected.insert(bk.id) } }
    }
    private func pill(_ t: String, warn: Bool = false, hint: Bool = false) -> some View {
        Text(t).font(Theme.round(11)).foregroundColor(warn ? Theme.dyn(0xA54E38, 0xE2A18B) : (hint ? Color(red: 0x9A/255, green: 0x6A/255, blue: 0x3A/255) : Theme.muted))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(warn ? Theme.accent.opacity(0.10) : (hint ? Theme.cacheTint.opacity(0.14) : Theme.bg), in: Capsule())
    }

    // MARK: 校对扫描文字
    private func ocr(_ bookId: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            lead("校对可疑行", "这里只列识别把握较低、含梵文转写或可疑符号的行。改正后保存；没有错误的原样保留即可。")
            VStack(spacing: 12) {
                ForEach(m.ocrItems) { it in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("扫描页 \(it.sourcePage ?? 0) · \(it.reason ?? "待确认")").font(Theme.round(12)).foregroundColor(Theme.muted)
                        TextEditor(text: Binding(get: { m.ocrTexts[it.id] ?? "" }, set: { m.ocrTexts[it.id] = $0 }))
                            .font(.system(size: 14)).foregroundColor(Theme.text).scrollContentBackground(.hidden)
                            .frame(minHeight: 72).padding(6)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.border, lineWidth: 1))
                    }
                }
            }
            HStack(spacing: 9) {
                btn("稍后") { m.mode = .report }
                btn("保存这批校对", primary: true) { Task { await m.saveOcr(bookId) } }
            }.padding(.top, 18)
        }
    }
}

/// 抽样阅读（<details>）：开头/中间/结尾
struct SampleDisclosure: View {
    let bk: Batch.Report.RBook
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text((bk.sourceFilename ?? bk.title ?? "") + " · 抽样阅读").font(Theme.round(12.5)).foregroundColor(Theme.muted); Spacer(); Text(open ? "▾" : "▸").font(Theme.round(12)).foregroundColor(Theme.muted) }
                .contentShape(Rectangle()).onTapGesture { open.toggle() }
            if open {
                ForEach(["开头", "中间", "结尾"], id: \.self) { k in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Theme.text)
                        Text(bk.samples?[k] ?? "（没有提取到文字）").font(.system(size: 13.5)).lineSpacing(5).foregroundColor(Theme.text)
                    }.padding(.top, 9)
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
