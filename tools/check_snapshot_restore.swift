import Foundation

/// 直接编译生产仓库和包校验源码，在 macOS 上验证恢复调度，不启动模拟器。
@main
struct SnapshotRestoreChecks {
    static let catalog = PaywallCatalog(productRefs: ["product"], recommendedRef: "product")

    /// 写入合法完整包；大包用于验证耗时校验不会占用 MainActor 或阻塞另一点位。
    static func install(_ name: String, root: URL, large: Bool = false) throws -> PaywallQuerySnapshot {
        let identity = WebPaywallPackage.Document(kind: "web-paywall", bridgeVersion: 2,
            documentId: name, revision: 1, pageUrl: "https://example.com/\(name)/v1/index.html",
            catalogKey: "default", productRefs: ["product"], initialProductRef: "product")
        let snapshot = PaywallQuerySnapshot(placement: name, requestIdentity: "fixture",
            requestBody: Data(), configuration: Data(), identity: identity)
        let directory = root.appendingPathComponent(snapshot.packageKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [WebPaywallPackage.File] = []
        let paths = ["offline.html", "offline.js", "content.json", "page.json"] +
            (large ? (0..<8).map { "asset\($0).bin" } : [])
        for path in paths {
            let data = path.hasSuffix(".bin") ? Data(repeating: 65, count: 8 * 1024 * 1024) : Data("{}".utf8)
            try data.write(to: directory.appendingPathComponent(path))
            files.append(.init(path: path, size: data.count, sha256: WebPaywallPackage.digest(data)))
        }
        let manifest = WebPaywallPackage(formatVersion: 1, runtimeEnvironment: "test",
            document: identity, documents: nil, entry: "offline.html", files: files)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("package.json"))
        return snapshot
    }

    /// 归档只复验一次目标包；清理扫描期间新提交的索引和当前租约仍有效。
    @MainActor
    static func checkArchiveMaintenance(root: URL) async throws {
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let snapshot = try install("saved", root: source)
        let orphan = try install("orphan", root: target)
        let gate = MaintenanceGate()
        let store = PaywallQuerySnapshotStore(directory: target, environment: "test",
            scan: { await gate.scan($0, measureSize: false) })
        _ = await store.restoreNames()
        let resource = WebPaywallResourceLease(directory: source.appendingPathComponent(snapshot.packageKey), release: {})
        var candidate: PaywallQuerySnapshotStore.Candidate? = try await store.save(snapshot, resource: resource)
        let directory = target.appendingPathComponent(snapshot.packageKey)
        precondition(candidate!.document.pageURL == directory.appendingPathComponent("offline.html"))
        await gate.waitStarted()
        // 扫描已经看到无索引 orphan，但它现在提交成功，旧扫描不得删除它。
        let orphanResource = WebPaywallResourceLease(directory: target.appendingPathComponent(orphan.packageKey), release: {})
        let adopted = try await store.save(orphan, resource: orphanResource)
        try await store.remove([snapshot.placement])
        await gate.open()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(FileManager.default.fileExists(atPath: candidate!.document.pageURL.path))
        precondition(FileManager.default.fileExists(atPath: adopted.document.pageURL.path))
        // 新读者仍完整验证持久化文件，归档交接不能屏蔽后续损坏。
        try Data("corrupt".utf8).write(to: adopted.lease.readAccessURL.appendingPathComponent("offline.js"))
        let restarted = PaywallQuerySnapshotStore(directory: target, environment: "test")
        let rejected = await restarted.restore(orphan.placement, catalog: catalog)
        precondition(rejected == nil)
        candidate = nil
        for _ in 0..<100 where FileManager.default.fileExists(atPath: directory.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!FileManager.default.fileExists(atPath: directory.path), "Released unindexed archive was not reclaimed")
        print("PASS Swift archive handoff, deferred cleanup, latest index and active lease protection")
    }

    /// 慢包不阻塞另一包，同包等待保持串行；排队取消不能启动额外写入。
    @MainActor
    static func checkParallelArchive(root: URL) async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let a = try install("a", root: source), b = try install("b", root: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let aSource = source.appendingPathComponent(a.packageKey)
        let gate = VerificationGate(target: aSource)
        let archive = PaywallQueryPackageArchive(beforePublish: { await gate.before($0) })
        let first = Task { try await archive.publish(a, source: aSource, root: target, environment: "test", canReplace: true) }
        await gate.waitStarted()
        let same = Task { try await archive.publish(a, source: aSource, root: target, environment: "test", canReplace: false) }
        let fast = try await archive.publish(b, source: source.appendingPathComponent(b.packageKey),
                                             root: target, environment: "test", canReplace: true)
        precondition(FileManager.default.fileExists(atPath: fast.pageURL.path))
        let before = await gate.count(aSource)
        precondition(before == 1, "Same package ran concurrently")
        same.cancel()
        await gate.open()
        _ = try await first.value
        do { _ = try await same.value; fatalError("Queued cancellation published") }
        catch is CancellationError {}
        let after = await gate.count(aSource)
        precondition(after == 1)
        try await checkArchiveCleanup(root: root, source: source, target: target, snapshot: a)
        print("PASS Swift independent archive progress, same-key serialization and queued cancellation")
    }

    /// 两个槽位均占用时第三包只排队；取消等待者不会发起文件操作。
    @MainActor
    static func checkArchiveLimit(root: URL) async throws {
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let snapshots = try ["one", "two", "three"].map { try install($0, root: source) }
        let gate = VerificationGate(target: root)
        let archive = PaywallQueryPackageArchive(beforePublish: { _ in await gate.before(root) })
        let tasks = snapshots.map { snapshot in Task {
            try await archive.publish(snapshot, source: source.appendingPathComponent(snapshot.packageKey),
                                      root: target, environment: "test", canReplace: true)
        } }
        for _ in 0..<1000 {
            if await gate.count(root) == 2 { break }
            await Task.yield()
        }
        let running = await gate.count(root)
        precondition(running == 2, "Archive concurrency limit violated")
        // 所有请求取消，已开始的准备退出后才能归还槽位。
        tasks.forEach { $0.cancel() }
        await gate.open()
        for task in tasks {
            do { _ = try await task.value; fatalError("Cancelled archive published") }
            catch is CancellationError {}
        }
        let finalCount = await gate.count(root)
        precondition(finalCount == 2, "Cancelled waiter started file work")
        let files = try FileManager.default.contentsOfDirectory(atPath: target.path)
        precondition(files.isEmpty)
        print("PASS Swift two-archive limit, in-flight cancellation and cancelled waiter release")
    }

    /// 坏目标隔离后可发布，清理被阻塞时后续归档仍可进行；活跃坏包禁止替换。
    static func checkArchiveCleanup(root: URL, source: URL, target: URL, snapshot: PaywallQuerySnapshot) async throws {
        let destination = target.appendingPathComponent(snapshot.packageKey)
        try Data("bad".utf8).write(to: destination.appendingPathComponent("offline.js"))
        let gate = VerificationGate(target: root)
        let archive = PaywallQueryPackageArchive(cleanup: { trash in
            precondition(trash.lastPathComponent.hasPrefix("trash-"))
            await gate.before(root)
            return await WebPaywallCacheMaintenance.remove(trash)
        })
        do {
            _ = try await archive.publish(snapshot, source: source.appendingPathComponent(snapshot.packageKey),
                                          root: target, environment: "test", canReplace: false)
            fatalError("Active corrupt archive replaced")
        } catch PaywallFailure.resource {}
        _ = try await archive.publish(snapshot, source: source.appendingPathComponent(snapshot.packageKey),
                                      root: target, environment: "test", canReplace: true)
        await gate.waitStarted()
        let broken = try install("broken", root: source)
        let brokenSource = source.appendingPathComponent(broken.packageKey)
        try Data("bad".utf8).write(to: brokenSource.appendingPathComponent("offline.js"))
        do {
            _ = try await archive.publish(broken, source: brokenSource, root: target, environment: "test", canReplace: true)
            fatalError("Corrupt source published")
        } catch {}
        // 失败归还队列，同身份修复后仍可成功，清理还没有放行。
        _ = try install("broken", root: source)
        _ = try await archive.publish(broken, source: brokenSource, root: target, environment: "test", canReplace: true)
        await gate.open()
        // 同一清理器兼容进程中断留下的隔离目录。
        _ = await WebPaywallCacheMaintenance.entries(at: target, measureSize: false)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: target.path)
        precondition(!remaining.contains { $0.hasPrefix("tmp-") || $0.hasPrefix("trash-") })
        print("PASS Swift archive isolated cleanup, protected replacement, failed publication and retry")
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("snapshot-restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let slow = try install("slow", root: root, large: true)
        let fast = try install("fast", root: root)
        struct Index: Encodable {
            let version = 1
            let environment = "test"
            let snapshots: [String: PaywallQuerySnapshot]
        }
        try JSONEncoder().encode(Index(snapshots: ["slow": slow, "fast": fast]))
            .write(to: root.appendingPathComponent("index.json"))
        let store = PaywallQuerySnapshotStore(directory: root, environment: "test")
        var order: [String] = []
        let slowTask = Task { @MainActor in
            let value = await store.restore("slow", catalog: catalog)
            order.append("slow")
            return value
        }
        // 让大包开始读取；主线程随后仍可处理事件和启动另一个恢复请求。
        try await Task.sleep(nanoseconds: 2_000_000)
        let fastValue = await store.restore("fast", catalog: catalog)
        order.append("fast")
        precondition(fastValue?.document.productRefs == ["product"])
        let slowValue = await slowTask.value
        precondition(slowValue != nil && order.first == "fast", "Slow package blocked the visible placement")
        let missing = await store.restore("missing", catalog: catalog)
        precondition(missing == nil)
        let cancelled = Task { @MainActor in await store.restore("fast", catalog: catalog) }
        cancelled.cancel()
        let cancelledValue = await cancelled.value
        precondition(cancelledValue == nil)
        // 新仓库必须完整复验；不能跨进程沿用旧成功结果或跨环境复用。
        try Data("corrupt".utf8).write(to: fastValue!.lease.readAccessURL.appendingPathComponent("offline.js"))
        let restarted = PaywallQuerySnapshotStore(directory: root, environment: "test")
        let corrupt = await restarted.restore("fast", catalog: catalog)
        precondition(corrupt == nil)
        let production = PaywallQuerySnapshotStore(directory: root, environment: "production")
        let mismatched = await production.restore("slow", catalog: catalog)
        precondition(mismatched == nil)
        try await checkParallelArchive(root: root.appendingPathComponent("parallel"))
        try await checkArchiveLimit(root: root.appendingPathComponent("archive-limit"))
        try await checkArchiveMaintenance(root: root.appendingPathComponent("archive-maintenance"))
        try await checkStartup(root: root)
        try await checkCommits(root: root.appendingPathComponent("commits"))
        print("PASS Swift independent placement restore, MainActor responsiveness, cancellation, corruption and environment isolation")
    }

    /// 网络先返回也不能越过恢复屏障；取消不提交迟到结果。
    @MainActor
    static func checkStartup(root: URL) async throws {
        let restore = VerificationGate(target: root)
        let fetch = VerificationGate(target: root)
        var delivered = false
        var migrated = false
        let pending = Task { @MainActor in
            let (_, result) = try await PaywallQueryStartup.load(
                restore: { await restore.before(root) },
                prepare: { "request" },
                fetch: { _ in await fetch.before(root); return 42 },
                frozen: { _ in migrated = true })
            delivered = true
            return result
        }
        await restore.waitStarted()
        await fetch.waitStarted()
        precondition(!delivered && !migrated)
        await restore.open()
        // 恢复完成后迁移可继续，网络响应仍停在独立门闩上。
        for _ in 0..<100 where !migrated { await Task.yield() }
        precondition(migrated && !delivered)
        await fetch.open()
        let result = try await pending.value
        precondition(result == 42)
        let cancelled = Task { @MainActor in
            try await PaywallQueryStartup.load(restore: {}, prepare: { 1 }, fetch: { $0 }, frozen: { _ in })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled startup delivered") }
        catch is CancellationError {}
        print("PASS Swift request/restore overlap, frozen result delivery and cancellation")
    }

    /// 阻塞磁盘写入期间主线程可工作；排队提交与删除不会覆盖彼此。
    @MainActor
    static func checkCommits(root: URL) async throws {
        let first = try install("first", root: root)
        let second = try install("second", root: root)
        let gate = VerificationGate(target: root)
        let store = PaywallQuerySnapshotStore(directory: root, environment: "test",
            beforeIndexWrite: { await gate.before(root) })
        let batch = PaywallQueryArchiveBatch()
        let a = WebPaywallResourceLease(directory: root.appendingPathComponent(first.packageKey), release: {})
        let b = WebPaywallResourceLease(directory: root.appendingPathComponent(second.packageKey), release: {})
        let taskA = Task { @MainActor in try await store.save(first, resource: a, batch: batch) }
        await gate.waitStarted()
        let initial = await store.restoreNames()
        precondition(initial.isEmpty, "Memory index changed before disk commit")
        let taskB = Task { @MainActor in try await store.save(second, resource: b, batch: batch) }
        await gate.open()
        let keptA = try await taskA.value
        let keptB = try await taskB.value
        let names = await store.restoreNames()
        precondition(Set(names) == ["first", "second"])
        try await store.remove(["first"])
        let restarted = PaywallQuerySnapshotStore(directory: root, environment: "test")
        let remaining = await restarted.restoreNames()
        precondition(remaining == ["second"])
        // 同批次别名复用同一包和租约，不触发第二次物理发布。
        let alias = PaywallQuerySnapshot(placement: "alias", requestIdentity: second.requestIdentity,
            requestBody: second.requestBody, configuration: second.configuration, identity: second.identity)
        let reused = try await store.save(alias, resource: b, batch: batch)
        precondition(reused.lease === keptB.lease)
        do { _ = try await batch.load("failure") { throw PaywallFailure.resource }; fatalError("Archive failure lost") }
        catch PaywallFailure.resource {}
        let retried = try await batch.load("failure") { .init(document: keptB.document, lease: keptB.lease) }
        precondition(retried.lease === keptB.lease)
        withExtendedLifetime(keptA) {}
        // 写入失败不会污染内存索引，也不会破坏磁盘中的旧点位。
        let failing = PaywallQuerySnapshotStore(directory: root, environment: "test",
            beforeIndexWrite: { throw PaywallFailure.resource })
        let pendingSnapshot = PaywallQuerySnapshot(placement: "pending", requestIdentity: second.requestIdentity,
            requestBody: second.requestBody, configuration: second.configuration, identity: second.identity)
        do { _ = try await failing.save(pendingSnapshot, resource: b); fatalError("Failed write committed") }
        catch PaywallFailure.resource {}
        let unchanged = await failing.restoreNames()
        precondition(Set(unchanged) == ["second", "alias"])
        let cancelGate = VerificationGate(target: root)
        let cancellable = PaywallQuerySnapshotStore(directory: root, environment: "test",
            beforeIndexWrite: { await cancelGate.before(root) })
        let cancelled = Task { @MainActor in try await cancellable.save(pendingSnapshot, resource: b) }
        await cancelGate.waitStarted()
        cancelled.cancel()
        await cancelGate.open()
        do { _ = try await cancelled.value; fatalError("Cancelled index committed") }
        catch is CancellationError {}
        let afterCancel = await cancellable.restoreNames()
        precondition(Set(afterCancel) == ["second", "alias"])
        print("PASS Swift background serialized index commits, alias lease reuse and failed-write rollback")
    }
}
