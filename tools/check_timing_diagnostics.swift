import Foundation

/// 计时包装不能吞掉返回值、异常或取消，也不能在关闭日志后跳过业务调用。
@main
struct TimingDiagnosticChecks {
    enum Failure: Error { case expected }
    static func main() async throws {
        let original = PaywallLogging.mode
        defer { PaywallLogging.mode = original }
        for mode in [PaywallLogging.Mode.enabled, .disabled, .automatic] {
            PaywallLogging.mode = mode
            var calls = 0
            let value = await WebPaywallDiagnostics.measure("test", "fixture") { calls += 1; return 42 }
            precondition(value == 42 && calls == 1)
            do {
                _ = try await WebPaywallDiagnostics.measure("test", "fixture") { throw Failure.expected }
                fatalError("Failure swallowed")
            } catch Failure.expected {}
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await WebPaywallDiagnostics.measure("test", "fixture") { try Task.checkCancellation() }
            }
            do { try await cancelled.value; fatalError("Cancellation swallowed") }
            catch is CancellationError {}
        }
        PaywallLogging.printsToConsole = false
        let stage = "muted-" + UUID().uuidString
        _ = await WebPaywallDiagnostics.measure("production", stage) { 1 }
        let recorded = await PaywallLogging.read()
        precondition(recorded.contains(stage + ".begin") && recorded.contains(stage + ".end"))
        precondition(recorded.contains("run=") && recorded.contains("wallMs="))
        try await checkStore()
        print("PASS Swift muted diagnostics remain readable in production")
        print("PASS Swift timing wrapper preserves results, errors, cancellation and logging-mode behavior")
    }

    /// 文件容量、重启读取、固定导出和清理都使用真实私有临时目录验证。
    static func checkStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paywall-log-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PaywallLogStore(directory: root, fileBytes: 128, bufferBytes: 8192)
        for index in 0..<40 { store.append("event-\(index) payload") }
        let text = await store.read()
        precondition(text.contains("event-39") && !text.contains("event-0 "))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        precondition(files.count == 3)
        for file in files { let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0; precondition(size <= 128) }
        let restarted = PaywallLogStore(directory: root, fileBytes: 128)
        let restored = await restarted.read()
        precondition(restored == text)
        let exported = try await restarted.export()
        let exportedText = try String(contentsOf: exported, encoding: .utf8)
        precondition(exportedText == text)
        let exportedAgain = try await restarted.export()
        precondition(exportedAgain == exported)
        try await restarted.clear()
        let cleared = await restarted.read()
        precondition(cleared.isEmpty)
        restarted.append("after-clear")
        let afterClear = await restarted.read()
        precondition(afterClear.contains("after-clear"))
        try await checkFailure(root: root.appendingPathComponent("blocked"))
        print("PASS Swift bounded log rotation, restart, export, clear and storage-failure recovery")
    }

    /// 写入失败保留最新有界缓冲，恢复目录后可重新落盘而不影响业务执行。
    static func checkFailure(root: URL) async throws {
        try Data("file".utf8).write(to: root)
        let store = PaywallLogStore(directory: root, bufferBytes: 256)
        for index in 0..<100 { store.append("event-\(index)") }
        let memory = await store.read()
        precondition(memory.contains("logs.storage_unavailable") && memory.contains("event-99"))
        precondition(memory.contains("logs.dropped") && memory.utf8.count < 512)
        try FileManager.default.removeItem(at: root)
        let recovered = await store.read()
        precondition(recovered.contains("event-99") && !recovered.contains("logs.storage_unavailable"))
        let fresh = await PaywallLogStore(directory: root).read()
        precondition(fresh == recovered)
    }
}
