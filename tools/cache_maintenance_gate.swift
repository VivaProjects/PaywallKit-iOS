import Foundation

/// 在真实目录扫描之后挂起清理，验证交付与最新租约/索引之间的竞争。
actor MaintenanceGate {
    private var started = false
    private var opened = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func scan(_ root: URL, measureSize: Bool) async -> [WebPaywallCacheMaintenance.Entry] {
        let entries = await WebPaywallCacheMaintenance.entries(at: root, measureSize: measureSize)
        started = true
        starters.forEach { $0.resume() }
        starters.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
        return entries
    }

    func waitStarted() async {
        if !started { await withCheckedContinuation { starters.append($0) } }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// 指定包的校验停在后台，其他包与缓存清理必须仍能完成。
actor VerificationGate {
    let target: URL
    private var counts: [URL: Int] = [:]
    private var entered = false
    private var opened = false
    private var starters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(target: URL) { self.target = target }
    func before(_ directory: URL) async {
        counts[directory, default: 0] += 1
        guard directory == target else { return }
        entered = true
        starters.forEach { $0.resume() }
        starters.removeAll()
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitStarted() async {
        if !entered { await withCheckedContinuation { starters.append($0) } }
    }
    func count(_ directory: URL) -> Int { counts[directory] ?? 0 }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
