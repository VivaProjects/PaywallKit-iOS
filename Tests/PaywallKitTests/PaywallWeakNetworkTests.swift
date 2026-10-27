import XCTest
@testable import PaywallKit

/// 真实 URLSession 管线下模拟网络响应，不访问业务服务器。
private final class ControlledProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var data = Data(); var delay: TimeInterval = 0 }
    static let lock = NSLock()
    static var requestCount = 0
    static var handler: ((URLRequest) -> Reply)?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" && request.httpMethod == "POST" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let reply = Self.handler!(request)
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}

@MainActor
final class PaywallWeakNetworkTests: XCTestCase {
    private let origin = "http://127.0.0.1:18931"
    private var namespace = ""
    private var directory: URL!
    private var replies: [String: Data] = [:]
    private var events: [PaywallQueryUpdateDiagnostic] = []
    private var nextVersion = false
    private var partial = false
    private var flakyPackage = false
    private var queryDelay: TimeInterval = 0
    private var queryFailures = 0
    private var queryStatus = 503
    private var packageFails = false
    private var empty = false
    private var packageID = ""

    override func setUp() async throws {
        do {
            _ = try await URLSession.shared.data(from: URL(string: origin + "/health")!)
        } catch { throw XCTSkip("先运行 python3 tools/weak_network_fixture_server.py") }
        namespace = UUID().uuidString
        packageID = UUID().uuidString
        events = []
        PaywallLogging.mode = .enabled
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("fixture-" + namespace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = WebPaywallPackage.Document(kind: "web-paywall", bridgeVersion: 2,
            documentId: packageID, revision: 1, pageUrl: origin + "/" + packageID + "/index.html",
            catalogKey: "default", productRefs: ["product"], initialProductRef: "product")
        let files = ["offline.html": "<html>fixture</html>", "offline.js": "", "content.json": "{}", "page.json": "{}"]
        let entries = files.map { key, value in
            WebPaywallPackage.File(path: key, size: value.utf8.count, sha256: WebPaywallPackage.digest(Data(value.utf8)))
        }
        let package = WebPaywallPackage(formatVersion: 1, runtimeEnvironment: "test", document: identity,
            documents: nil, entry: "offline.html", files: entries)
        replies = files.mapValues { Data($0.utf8) }
        replies["package.json"] = try JSONEncoder().encode(package)
        for (path, data) in replies { try data.write(to: directory.appendingPathComponent(path)) }
        // handler 仅在锁内执行；用不可变响应配置，计数单独在锁内维护。
        URLProtocol.registerClass(ControlledProtocol.self)
    }

    override func tearDown() async throws {
        URLProtocol.unregisterClass(ControlledProtocol.self)
        ControlledProtocol.lock.withLock { ControlledProtocol.handler = nil }
        PaywallLogging.mode = .automatic
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func installHandler() {
        let path = packageFails ? "bad/" + packageID : (nextVersion ? "v2/" + packageID : (flakyPackage ? "flaky/" + packageID : packageID))
        var positions: [[String: Any]] = [["positionKey": "a", "matched": true, "h5Url": "\(origin)/\(path)/index.html"]]
        if partial { positions.append(["positionKey": "b", "matched": true, "h5Url": "\(origin)/bad/\(packageID)/index.html"]) }
        let payload = try! JSONSerialization.data(withJSONObject: ["code": "200", "data": positions])
        let replies = replies, delay = queryDelay, failures = queryFailures, status = queryStatus
        let failPackage = packageFails, empty = empty
        var count = 0
        ControlledProtocol.lock.lock()
        ControlledProtocol.requestCount = 0
        ControlledProtocol.handler = { request in
            if request.httpMethod == "POST" {
                count += 1
                return .init(status: count <= failures ? status : 200,
                    data: empty ? Data(#"{"code":"200","data":[]}"#.utf8) : payload, delay: delay)
            }
            if failPackage { return .init(status: 404) }
            return .init(data: replies[request.url!.lastPathComponent] ?? Data())
        }
        ControlledProtocol.lock.unlock()
    }

    private func makeClient() -> PaywallClient {
        let configuration = PaywallQueryConfiguration(endpoint: URL(string: origin + "/query")!,
            runtimeEnvironment: .test, cacheNamespace: namespace, allowedOrigins: nil, placements: partial ? ["a": "a", "b": "b"] : ["a": "a"],
            fallback: .init(placement: "settings", bundledDirectory: directory, fallbackPlacements: ["a"]),
            developmentHTTPOrigin: origin,
            onUpdateDiagnostic: { [weak self] in self?.events.append($0) })
        let client = PaywallClient(query: configuration,
            catalog: { PaywallCatalog(productRefs: ["product"], recommendedRef: "product") })
        client.reportAttribution(channel: "test", failed: false)
        return client
    }

    /// 独立 SDK 测试没有 App Bundle，使用已校验的本地启动快照作为兜底。
    private func fallbackContext(_ client: PaywallClient) throws -> PaywallFallbackContext {
        let package = try JSONDecoder().decode(WebPaywallPackage.self, from: replies["package.json"]!)
        let catalog = PaywallCatalog(productRefs: ["product"], recommendedRef: "product")
        let document = try WebPaywallDocument(packageDirectory: directory, identity: package.document,
                                             environment: "test", catalog: catalog)
        let selected = PaywallPlacement(name: "settings", document: document, presentation: .fullScreen,
                                         sessionPolicy: nil, clientID: client.id)
        let store = PaywallLocalPackageStore(placement: "settings", fallbackPlacements: ["a"],
            bundledDirectory: directory, runtimeEnvironment: "test", allowedOrigins: nil,
            cacheNamespace: namespace + ".fallback", catalog: { catalog })
        return PaywallFallbackContext(placement: "a", store: store, cachedFallback: selected)
    }

    private func waitForEvent(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while events.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(events.isEmpty, "后台任务未报告终态")
    }

    func testThreeSecondFallbackDownloadContinuesAndNextClientRestores() async throws {
        queryDelay = 4
        installHandler()
        let client = makeClient()
        let start = ProcessInfo.processInfo.systemUptime
        let selected = try await client.resolveForPresentation("a", context: try fallbackContext(client))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThan(elapsed, 2.8)
        XCTAssertLessThan(elapsed, 3.8)
        XCTAssertEqual(selected.fallbackContext?.resolution?.source, "update")
        try await waitForEvent()
        XCTAssertNil(client.cachedPlacement("a"), "迟到新包不得在本次启动启用")
        let next = makeClient()
        XCTAssertEqual(next.cachedPlacement("a")?.document.documentId, packageID)
    }

    func testSuccessfulDownloadThenSameVersionReportsNoUpdate() async throws {
        installHandler()
        let client = makeClient()
        try await client.prepare()
        try await waitForEvent()
        guard case let .completed(count, failures) = events[0] else { return XCTFail() }
        XCTAssertEqual(count, 1); XCTAssertEqual(failures, 0)
        events = []
        let next = makeClient()
        try await next.prepare()
        try await waitForEvent()
        guard case let .completed(unchanged, errors) = events[0] else { return XCTFail() }
        XCTAssertEqual(unchanged, 0); XCTAssertEqual(errors, 0)
    }

    func testTransientConfigurationFailureRetriesAndSucceeds() async throws {
        queryFailures = 2
        installHandler()
        let client = makeClient()
        let start = ProcessInfo.processInfo.systemUptime
        try await client.prepare()
        try await waitForEvent()
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 6.8)
        XCTAssertEqual(events.count, 1)
        guard case let .completed(count, failures) = events[0] else { return XCTFail() }
        XCTAssertEqual(count, 1); XCTAssertEqual(failures, 0)
    }

    func testExhaustedRetriesReportSingleFailure() async throws {
        queryFailures = 100
        installHandler()
        let client = makeClient()
        do { try await client.prepare(); XCTFail("503 must fail") } catch {}
        XCTAssertEqual(ControlledProtocol.lock.withLock { ControlledProtocol.requestCount }, 3)
        XCTAssertEqual(events.count, 1)
        guard case .failed = events.first else { return XCTFail() }
    }

    func testPackageFailureIsNotReportedAsSuccess() async throws {
        packageFails = true
        installHandler()
        let client = makeClient()
        try await client.prepare()
        try await waitForEvent()
        guard case let .completed(count, failures) = events[0] else { return XCTFail() }
        XCTAssertEqual(count, 0); XCTAssertEqual(failures, 1)
    }

    func testEmptyResponseReportsNoUpdate() async throws {
        empty = true
        installHandler()
        let client = makeClient()
        try await client.prepare()
        guard case let .completed(count, failures) = events.first else { return XCTFail() }
        XCTAssertEqual(count, 0); XCTAssertEqual(failures, 0)
    }

    func testDisabledLoggingSuppressesDiagnostic() async throws {
        empty = true
        installHandler()
        PaywallLogging.mode = .disabled
        let client = makeClient()
        try await client.prepare()
        XCTAssertTrue(events.isEmpty)
    }

    func testCancelEntryDoesNotCancelBackgroundUpdate() async throws {
        queryDelay = 1
        installHandler()
        let client = makeClient()
        let task = Task { try await client.resolveForPresentation("a", context: client.makeFallbackContext("a")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("entry must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await waitForEvent()
        XCTAssertNotNil(client.cachedPlacement("a"))
    }

    func testPartialPackageFailureReportsBothCounts() async throws {
        partial = true
        installHandler()
        let client = makeClient()
        try await client.prepare()
        try await waitForEvent()
        guard case let .completed(count, failures) = events[0] else { return XCTFail() }
        XCTAssertEqual(count, 1); XCTAssertEqual(failures, 1)
    }

    func testExistingSnapshotStaysFrozenUntilNextClient() async throws {
        installHandler()
        let first = makeClient()
        try await first.prepare()
        try await waitForEvent()
        events = []
        nextVersion = true
        installHandler()
        let second = makeClient()
        XCTAssertEqual(second.cachedPlacement("a")?.document.revision, 1)
        try await second.prepare()
        try await waitForEvent()
        XCTAssertEqual(second.cachedPlacement("a")?.document.revision, 1)
        guard case let .completed(count, failures) = events[0] else { return XCTFail() }
        XCTAssertEqual(count, 1); XCTAssertEqual(failures, 0)
        let third = makeClient()
        XCTAssertEqual(third.cachedPlacement("a")?.document.revision, 2)
    }

    func testTransientPackageFailureRetriesAndSucceeds() async throws {
        flakyPackage = true
        installHandler()
        let client = makeClient()
        let start = ProcessInfo.processInfo.systemUptime
        try await client.prepare()
        try await waitForEvent()
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - start, 6.8)
        guard case let .completed(count, failures) = events[0] else { return XCTFail() }
        XCTAssertEqual(count, 1); XCTAssertEqual(failures, 0)
        XCTAssertEqual(events.count, 1)
    }

    func testAutomaticLoggingEnvironmentGate() {
        PaywallLogging.mode = .automatic
        XCTAssertTrue(PaywallLogging.isEnabled(for: "test"))
        XCTAssertFalse(PaywallLogging.isEnabled(for: "production"))
        PaywallLogging.mode = .enabled
        XCTAssertTrue(PaywallLogging.isEnabled(for: "production"))
    }

    func testRetryClassificationAndCancellation() async throws {
        XCTAssertTrue(PaywallQueryRetry.permits(URLError(.timedOut)))
        XCTAssertTrue(PaywallQueryRetry.permits(URLError(.networkConnectionLost)))
        XCTAssertFalse(PaywallQueryRetry.permits(URLError(.cancelled)))
        XCTAssertFalse(PaywallQueryRetry.permits(WebPaywallError.invalidDocument))
        XCTAssertFalse(PaywallQueryRetry.permits(PaywallQueryRetry.HTTPFailure(status: 404)))
        XCTAssertTrue(PaywallQueryRetry.permits(PaywallQueryRetry.HTTPFailure(status: 429)))
        var attempts = 0
        let task = Task {
            try await PaywallQueryRetry.run(environment: "test", stage: "test") { () -> Void in
                attempts += 1
                throw URLError(.timedOut)
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { try await task.value; XCTFail() } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(attempts, 1)
    }
}
