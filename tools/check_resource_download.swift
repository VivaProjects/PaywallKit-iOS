import Foundation

/// 使用本机 HTTP/1.1 服务验证真实 URLSession 连接复用和流式响应边界。
@main
struct ResourceDownloadChecks {
    static func expectFailure(_ action: () async throws -> Data) async {
        do { _ = try await action(); fatalError("Invalid response accepted") } catch {}
    }

    static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let transport = WebPaywallResourceDownload()
        defer { transport.close() }
        for _ in 0..<3 {
            let bytes = try await transport.fetch(base.appendingPathComponent("bytes"), limit: 4096,
                                                   deadline: Date().addingTimeInterval(3))
            precondition(bytes == Data(repeating: 65, count: 4096))
        }
        let stats = try await transport.fetch(base.appendingPathComponent("stats"), limit: 4096,
                                               deadline: Date().addingTimeInterval(3))
        let value = try JSONSerialization.jsonObject(with: stats) as! [String: Int]
        precondition(value["byteRequests"] == 3 && value["byteConnections"] == 1, "Connections were not reused")
        for endpoint in ["header-too-large", "chunked-too-large", "redirect", "status"] {
            await expectFailure {
                try await transport.fetch(base.appendingPathComponent(endpoint), limit: 10,
                                           deadline: Date().addingTimeInterval(2))
            }
        }
        let empty = try await transport.fetch(base.appendingPathComponent("empty"), limit: 0,
                                               deadline: Date().addingTimeInterval(2))
        precondition(empty.isEmpty)
        let streamed = try await transport.fetch(base.appendingPathComponent("chunked"), limit: 8,
                                                  deadline: Date().addingTimeInterval(2))
        precondition(streamed == Data("12345678".utf8))
        let start = Date()
        await expectFailure {
            try await transport.fetch(base.appendingPathComponent("stall"), limit: 10,
                                       deadline: Date().addingTimeInterval(0.15))
        }
        precondition(Date().timeIntervalSince(start) < 1, "Body deadline did not interrupt the request")
        // 取消一个在途响应不关闭连接池，也不能取消另一个请求。
        let cancelled = Task {
            try await transport.fetch(base.appendingPathComponent("stall"), limit: 10,
                                       deadline: Date().addingTimeInterval(3))
        }
        let survivor = Task {
            try await transport.fetch(base.appendingPathComponent("delayed"), limit: 4096,
                                       deadline: Date().addingTimeInterval(3))
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled request completed") }
        catch is CancellationError {} // 不能误报成需要重试的网络超时。
        let survived = try await survivor.value
        precondition(survived.count == 4096, "Cancellation affected another request")
        let remaining = try await transport.fetch(base.appendingPathComponent("bytes"), limit: 4096,
                                                   deadline: Date().addingTimeInterval(3))
        precondition(remaining.count == 4096)
        let finalStats = try await transport.fetch(base.appendingPathComponent("stats"), limit: 4096,
                                                    deadline: Date().addingTimeInterval(3))
        let finalValue = try JSONSerialization.jsonObject(with: finalStats) as! [String: Int]
        precondition(finalValue["byteRequests"] == 4, "Redirect was followed")
        print("PASS Swift HTTP connection reuse, chunk limits, redirect/status rejection, body deadline, cancellation and pool survival")
    }
}
