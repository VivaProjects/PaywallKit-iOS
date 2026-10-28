import Foundation

/// 使用真实本地包仓库和历史仓库验证异步校验，不启动模拟器。
@main
struct LocalPackageLoadingChecks {
    static let catalog = PaywallCatalog(productRefs: ["product"], recommendedRef: "product")

    static func identity(_ name: String, revision: Int = 1) -> WebPaywallPackage.Document {
        .init(kind: "web-paywall", bridgeVersion: 2, documentId: name, revision: revision,
              pageUrl: "https://example.com/\(name)/v\(revision)/index.html", catalogKey: "default",
              productRefs: ["product"], initialProductRef: "product")
    }

    /// 生成合法包，大小不同但校验规则与正式产物完全相同。
    static func install(_ identity: WebPaywallPackage.Document, at directory: URL, large: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = ["offline.html", "offline.js", "page.json", "content.json"] + (large ? ["large.bin"] : [])
        var files: [WebPaywallPackage.File] = []
        for path in paths {
            let data = path.hasSuffix(".bin") ? Data(repeating: 65, count: 32 * 1024 * 1024) : Data("{}".utf8)
            try data.write(to: directory.appendingPathComponent(path))
            files.append(.init(path: path, size: data.count, sha256: WebPaywallPackage.digest(data)))
        }
        let package = WebPaywallPackage(formatVersion: 1, runtimeEnvironment: "test", document: identity,
            documents: nil, entry: "offline.html", files: files)
        try JSONEncoder().encode(package).write(to: directory.appendingPathComponent("package.json"))
    }

    /// 构造已持久化的更新状态，保留相同的环境、目录及版本校验路径。
    static func state(_ identity: WebPaywallPackage.Document, root: URL, key: String) throws {
        let document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity))
        let update: [String: Any] = ["formatVersion": 1, "runtimeEnvironment": "test", "version": identity.revision,
                                    "document": document, "disabledPlacements": []]
        let data: [String: Any] = ["current": ["update": update, "directory": key], "rejected": [],
                                  "highestVersion": identity.revision, "policyVersion": 0, "disabledPlacements": []]
        try JSONSerialization.data(withJSONObject: data).write(to: root.appendingPathComponent("state.json"))
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("local-loading-" + UUID().uuidString)
        guard let resources = Bundle.main.resourceURL else { fatalError("Missing test executable resource root") }
        let bundled = resources.appendingPathComponent("local-fixture-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: bundled)
        }
        let current = identity("updated", revision: 2)
        let key = String(repeating: "a", count: 64)
        let source = root.appendingPathComponent("packages/\(key)")
        try install(current, at: source, large: true)
        try install(identity("bundled"), at: bundled)
        try state(current, root: root, key: key)
        let orphan = root.appendingPathComponent("packages/orphan")
        try install(identity("orphan"), at: orphan)
        let cleanupGate = VerificationGate(target: orphan)
        let store = PaywallLocalPackageStore(placement: "settings", bundledDirectory: bundled,
            directory: root, environment: "test", beforeCleanup: { await cleanupGate.before(orphan) }, catalog: { catalog })
        await cleanupGate.waitStarted()
        // 初始化只隔离旧目录；删除尚未开始，合法页面已经可以继续加载。
        precondition(!FileManager.default.fileExists(atPath: orphan.path))
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: orphan.appendingPathComponent("new.txt"))
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { return }
                ticks += 1
            }
        }
        let selected = try await store.selection()
        heartbeat.cancel()
        precondition(selected.0.documentId == "updated" && selected.1 == "update")
        precondition(ticks > 0, "Local package validation blocked MainActor")
        await cleanupGate.open()
        await store.waitForCleanup()
        precondition(FileManager.default.fileExists(atPath: orphan.appendingPathComponent("new.txt").path))
        let context = PaywallFallbackContext(placement: "settings", store: store)
        let clientID = UUID()
        let prepared = try await context.localPlacement(clientID: clientID)
        let reused = try context.takeLocalPlacement(prepared, clientID: clientID)
        precondition(reused?.resourceLease === prepared.resourceLease, "Same presentation did not reuse its validated lease")
        let consumed = try context.takeLocalPlacement(prepared, clientID: clientID)
        precondition(consumed == nil)
        let another = try await context.localPlacement(clientID: clientID)
        context.beginPreparation()
        let retried = try context.takeLocalPlacement(another, clientID: clientID)
        precondition(retried == nil, "Retry reused stale handoff")
        print("PASS Swift one-shot local handoff, retry invalidation and isolated background initialization cleanup")
        let cancelled = Task { @MainActor in try await store.selection() }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled selection succeeded") }
        catch is CancellationError {}
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as! [String: Any]
        precondition((metadata["rejected"] as! [Int]).isEmpty, "Cancellation rejected a valid update")
        // 等待期间宿主目录收窄时，旧目录授权不能用于交付晚到文档。
        var allowed = true
        let changing = PaywallLocalPackageStore(placement: "settings", bundledDirectory: bundled,
            directory: root, environment: "test", catalog: {
                allowed ? catalog : PaywallCatalog(productRefs: ["other"], recommendedRef: "other")
            })
        let pending = Task { @MainActor in try await changing.selection() }
        try await Task.sleep(nanoseconds: 1_000_000)
        allowed = false
        do { _ = try await pending.value; fatalError("Stale catalog authorization accepted") } catch {}
        // 损坏更新仍拒绝并回到受 Bundle 边界保护的内置包。
        try Data("bad".utf8).write(to: source.appendingPathComponent("offline.js"))
        let fallback = try await store.selection()
        precondition(fallback.0.documentId == "bundled" && fallback.1 == "bundled")
        let production = PaywallLocalPackageStore(placement: "settings", bundledDirectory: bundled,
            directory: root, environment: "production", catalog: { catalog })
        do { _ = try await production.selection(); fatalError("Cross-environment fallback accepted") } catch {}
        let denied = PaywallLocalPackageStore(placement: "settings", bundledDirectory: bundled,
            directory: root, environment: "test",
            catalog: { PaywallCatalog(productRefs: ["other"], recommendedRef: "other") })
        do { _ = try await denied.selection(bundledOnly: true); fatalError("Unregistered product accepted") } catch {}
        // 同样合法的包放到 Bundle 外仍不能作为内置资源使用。
        do {
            _ = try await WebPaywallLocalDocumentLoader.bundled(directory: source, resources: bundled,
                environment: "test", catalog: catalog)
            fatalError("Outside bundled directory accepted")
        } catch {}
        try await checkHistory(root.appendingPathComponent("history-check"))
        print("PASS Swift local fallback responsiveness, cancellation, corruption, catalog, environment and Bundle boundary")
    }

    /// 历史仓库交付已验证文档；以后重新读取仍能检测损坏。
    static func checkHistory(_ root: URL) async throws {
        let old = identity("history")
        let source = root.appendingPathComponent("source")
        try install(old, at: source)
        let store = PaywallHistoryStore(directory: root.appendingPathComponent("archive"))
        let snapshot = PaywallHistorySnapshot(namespace: "fixture", requestURL: "request", environment: "test", configuration: Data())
        let remote = try WebPaywallDocument(data: JSONEncoder().encode(old), allowedOrigins: ["https://example.com"], catalog: catalog)
        try await store.record(snapshot, placement: "first", document: remote, packageDirectory: source)
        let fresh = try WebPaywallDocument(data: JSONEncoder().encode(identity("history", revision: 2)),
            allowedOrigins: ["https://example.com"], catalog: catalog)
        guard let candidate = try await store.previous(snapshot, placement: "first", document: fresh) else { fatalError("Missing previous version") }
        precondition(candidate.document.revision == 1 && candidate.document.localReadAccessURL == candidate.lease.readAccessURL)
        try Data("bad".utf8).write(to: candidate.lease.readAccessURL.appendingPathComponent("offline.js"))
        do { _ = try await store.previous(snapshot, placement: "first", document: fresh); fatalError("Corrupt history accepted") } catch {}
        let cancelled = Task { try await store.previous(snapshot, placement: "first", document: fresh) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled history accepted") } catch {}
        print("PASS Swift verified history handoff and corruption revalidation")
    }
}
