import Foundation

/// 网关接口。口令从钥匙串取；流式回复走 SSE（事件与网页同一套：start/thinking/tool/tool_done/delta/done/error）。
enum GatewayAPI {
    enum Failure: Error { case unauthorized, door(until: String, note: String), http(Int), offline }

    private static func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let token = Keychain.token else { throw Failure.unauthorized }
        var r = URLRequest(url: Gateway.home.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 15      // 断流 15 秒就算失败（09-03：出站通道卡住时 30 秒太久，脉搏也被挡着）
        return r
    }

    private static func raw(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: try request(path, method: method, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(code) else { throw Failure.http(code) }
        return data
    }

    private static func json<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await raw(path, method: method, body: body))
    }

    static func latestConversationId() async throws -> String? {
        let p: ConversationsPayload = try await json("api/conversations")
        return p.conversations.first?.id
    }

    /// 门的状态（/api/notes 顺带捎回：门关着时前端画门页+拦发送）
    private struct DoorWrap: Decodable { var door: Door? }
    static func door() async throws -> Door? {
        let w: DoorWrap = try await json("api/notes")
        return w.door
    }

    /// 当前对话整段；解出来的同时落盘，下次冷启动先亮它
    static func conversation(_ id: String) async throws -> ConversationPayload {
        let d = try await raw("api/conversations/\(id)")
        let conv = try JSONDecoder().decode(ConversationPayload.self, from: d)
        DiskCache.write("conv.json", d)
        return conv
    }

    static func cachedConversation() -> ConversationPayload? {
        DiskCache.read("conv.json").flatMap { try? JSONDecoder().decode(ConversationPayload.self, from: $0) }
    }

    static func pulse(_ id: String) async throws -> Pulse {
        try await json("api/conversations/\(id)/pulse")
    }

    static func stop(_ id: String) async {
        let body = try? JSONSerialization.data(withJSONObject: ["conversation_id": id])
        _ = try? await URLSession.shared.data(for: try request("api/stop", method: "POST", body: body))
    }

    // MARK: - 流式聊天

    enum Event {
        case start(conversationId: String)
        case thinking(String)
        case tool(String)
        case toolDone
        case delta(String)
        case done(Usage?)
        case error(String)
    }

    /// 发一条消息，事件按到达顺序吐出。HTTP 层的失败（401/423/其他）在第一次 yield 前以 Failure 抛出。
    static func chat(conversationId: String?, message: String, images: [String], knock: Bool = false) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var payload: [String: Any] = ["message": message, "images": images]
                    if let conversationId { payload["conversation_id"] = conversationId }
                    if knock { payload["knock"] = true }   // 敲门：门关着时寻唯一能递进来的一句（08-30 寻定）
                    let body = try JSONSerialization.data(withJSONObject: payload)
                    var req = try request("api/chat", method: "POST", body: body)
                    req.timeoutInterval = 600
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 401 { throw Failure.unauthorized }
                    if code == 423 {
                        var until = "", note = ""
                        var raw = Data()
                        for try await b in bytes { raw.append(b) }
                        if let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                           let d = j["detail"] as? [String: Any] {
                            until = d["until"] as? String ?? ""; note = d["note"] as? String ?? ""
                        }
                        throw Failure.door(until: until, note: note)
                    }
                    guard (200..<300).contains(code) else { throw Failure.http(code) }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonText = line.dropFirst(6)
                        guard let data = jsonText.data(using: .utf8),
                              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = d["type"] as? String else { continue }
                        switch type {
                        case "start": continuation.yield(.start(conversationId: d["conversation_id"] as? String ?? ""))
                        case "thinking": continuation.yield(.thinking(d["text"] as? String ?? ""))
                        case "tool": continuation.yield(.tool(d["name"] as? String ?? "?"))
                        case "tool_done": continuation.yield(.toolDone)
                        case "delta": continuation.yield(.delta(d["text"] as? String ?? ""))
                        case "done":
                            var u: Usage? = nil
                            if let ud = d["usage"], let udata = try? JSONSerialization.data(withJSONObject: ud) {
                                u = try? JSONDecoder().decode(Usage.self, from: udata)
                            }
                            continuation.yield(.done(u))
                        case "error": continuation.yield(.error(d["message"] as? String ?? "出错了"))
                        default: break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
