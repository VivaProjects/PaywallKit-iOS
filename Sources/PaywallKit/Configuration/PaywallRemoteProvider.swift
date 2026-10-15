import Foundation

/// Actor 串行维护缓存；每次 resolve 都返回独立快照，不推送到已展示页面。
public actor PaywallRemoteProvider {
    private let options: PaywallRemoteOptions
    private let verifier: PaywallSignatureVerifier
    private let session: URLSession
    private let onConfigurationError: @Sendable (PaywallEvent) -> Void
    private var manifestCache: (Data, String?)?

    public init(options: PaywallRemoteOptions, onConfigurationError: @escaping @Sendable (PaywallEvent) -> Void = { _ in }) {
        self.onConfigurationError = onConfigurationError
        self.options = options
        verifier = PaywallSignatureVerifier(publicKeys: options.publicKeys)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        session = URLSession(configuration: configuration)
    }

    /// 远端、LKG、包内与固定原生四级回退；紧急暂停直接绕过 LKG。
    public func resolve(placement: String, installationID: String, locale: String, storefrontGroup: String,
                        catalogs: [String: PaywallCatalog], assetIDs: Set<String>,
                        bundledName: String = "onboarding", bundle: Bundle? = nil) async -> PaywallResolution {
        var failures: [String] = []
        var paused = false
        do {
            let manifestData = try await fetchManifest()
            let manifest = try decodeManifest(manifestData, requireFresh: true)
            guard let plan = manifest.placements[placement] else { throw failure("placement_missing") }
            paused = plan.paused
            if paused {
                // 保存签名暂停标记，重启后离线也不能复活旧 LKG。
                try save(CacheRecord(manifest: manifestData, document: Data(), reference: plan.stable,
                                     assignment: [:]), placement: placement)
                throw failure("placement_paused")
            }
            let (reference, assignment) = plan.choose(installationID: installationID)
            let result = try await downloadValidated(reference, placement, locale, storefrontGroup, catalogs, assetIDs)
            let document = result.0
            var snapshot = result.1
            snapshot.assignment = assignment
            let record = CacheRecord(manifest: manifestData, document: document, reference: reference, assignment: assignment)
            // 完整校验和领域树构建成功后，才原子更新 LKG。
            do { try save(record, placement: placement) }
            catch { failures.append("cache_write_failed") }
            return .init(snapshot: snapshot, source: .remote, failures: failures)
        } catch { failures.append(String(describing: error)) }
        if !paused {
            do {
                return try cachedResolution(placement, installationID, locale, storefrontGroup, catalogs, assetIDs, failures)

            } catch { failures.append(String(describing: error)) }
        }
        do {
            let snapshot = try PaywallSnapshotFactory().loadBundled(name: bundledName, bundle: bundle, placement: placement,
                locale: locale, storefrontGroup: storefrontGroup, catalogs: catalogs, assetIDs: assetIDs)
            return .init(snapshot: snapshot, source: .bundled, failures: failures)
        } catch { failures.append(String(describing: error)) }
        return .init(snapshot: nil, source: .native, failures: failures)
    }

    /// 失败事件绑定已验签 Manifest 指定的版本，网络故障不进入配置熔断。
    private func downloadValidated(_ reference: PaywallManifest.Reference, _ placement: String,
                                   _ locale: String, _ storefront: String, _ catalogs: [String: PaywallCatalog],
                                   _ assets: Set<String>) async throws -> (Data, PaywallSnapshot) {
        var category = "network"
        do {
            let data = try await fetch(reference.path).0
            category = "configuration"
            return (data, try makeSnapshot(data, reference, placement, locale, storefront, catalogs, assets))
        } catch {
            onConfigurationError(.init(name: .configFallback, documentId: reference.documentId,
                revision: reference.revision, placement: placement, variant: "unknown", rendererVersion: 1,
                fields: ["app": options.app, "environment": options.environment,
                         "errorCategory": category, "reason": String(describing: error)]))
            throw error
        }
    }

    /// 缓存同样需要签名和分桶校验，不信任落盘的归因字段。
    private func cachedResolution(_ placement: String, _ installationID: String, _ locale: String,
                                  _ storefrontGroup: String, _ catalogs: [String: PaywallCatalog],
                                  _ assetIDs: Set<String>, _ failures: [String]) throws -> PaywallResolution {
        let record = try read(placement: placement)
        let cachedPlan = try validateCache(record, placement: placement)
        let (cachedReference, assignment) = cachedPlan.choose(installationID: installationID)
        guard cachedReference.sha256 == record.reference.sha256 else { throw failure("cache_assignment") }
        var snapshot = try makeSnapshot(record.document, record.reference, placement, locale, storefrontGroup, catalogs, assetIDs)
        snapshot.assignment = assignment
        return .init(snapshot: snapshot, source: .lastKnownGood, failures: failures)
    }

    /// TTL 内复用已验签清单，过期后使用 ETag 有条件刷新。
    private func fetchManifest() async throws -> Data {
        if let cached = manifestCache, (try? decodeManifest(cached.0, requireFresh: true)) != nil { return cached.0 }
        let result = try await fetch("/manifests/\(options.app)/\(options.environment)", etag: manifestCache?.1)
        let data: Data
        if result.2 == 304, let cached = manifestCache { data = cached.0 }
        else { data = result.0 }
        _ = try decodeManifest(data, requireFresh: true)
        manifestCache = (data, result.1)
        return data
    }

    /// 固定 origin 与有限响应大小；开发 HTTP 只允许显式启用的本机地址。
    private func fetch(_ path: String, etag: String? = nil) async throws -> (Data, String?, Int) {
        let base = options.baseURL
        guard base.scheme == "https" || (options.allowLoopbackHTTP && base.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(base.host ?? "")),
              path.hasPrefix("/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.scheme == base.scheme, url.port == base.port else { throw failure("untrusted_url") }
        var request = URLRequest(url: url)
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, [200, 304].contains(http.statusCode),
              response.url?.host == base.host, response.url?.scheme == base.scheme,
              response.url?.port == base.port else { throw failure("http_status_or_redirect") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 400000 else { throw failure("response_limit") }
            data.append(byte)
        }
        return (data, http.value(forHTTPHeaderField: "ETag"), http.statusCode)
    }

    /// LKG 可使用过期清单验证来源绑定；远端清单必须在有效期内。
    private func decodeManifest(_ data: Data, requireFresh: Bool) throws -> PaywallManifest {
        let manifest = try JSONDecoder().decode(PaywallManifest.self, from: verifier.payload(data))
        let now = Int(Date().timeIntervalSince1970)
        guard manifest.app == options.app, manifest.environment == options.environment,
              manifest.expiresAt > manifest.issuedAt, manifest.expiresAt - manifest.issuedAt <= 900,
              manifest.issuedAt <= now + 60, !requireFresh || manifest.expiresAt > now,
              manifest.placements.values.allSatisfy({ (0...10000).contains($0.basisPoints) }) else { throw failure("manifest_context_or_expiry") }
        return manifest
    }

    /// 签名、摘要、版本与 placement 都必须一致，不能接受同签名键的错误对象。
    private func makeSnapshot(_ data: Data, _ reference: PaywallManifest.Reference, _ placement: String,
                              _ locale: String, _ storefront: String, _ catalogs: [String: PaywallCatalog],
                              _ assets: Set<String>) throws -> PaywallSnapshot {
        guard verifier.digest(data) == reference.sha256,
              reference.path == "/documents/\(reference.documentId)/revisions/\(reference.revision)" else { throw failure("document_hash_or_path") }
        let snapshot = try PaywallSnapshotFactory().makeTrusted(verifier.payload(data), placement: placement,
            locale: locale, storefrontGroup: storefront, catalogs: catalogs, assetIDs: assets)
        guard snapshot.documentId == reference.documentId, snapshot.revision == reference.revision else { throw failure("revision_mismatch") }
        return snapshot
    }

    /// 缓存保留签名清单，避免把其它 app 或环境的合法签名文档混入本环境。
    private func validateCache(_ record: CacheRecord, placement: String) throws -> PaywallManifest.Placement {
        let manifest = try decodeManifest(record.manifest, requireFresh: false)
        guard let plan = manifest.placements[placement], !plan.paused,
              [plan.stable.sha256, plan.candidate?.sha256].contains(record.reference.sha256) else { throw failure("cache_scope") }
        return plan
    }

    private func cacheURL(_ placement: String) -> URL {
        let scope = "\(options.baseURL.absoluteString)|\(options.app)|\(options.environment)|\(placement)|1.0"
        return options.cacheDirectory.appendingPathComponent(verifier.digest(Data(scope.utf8)) + ".json")
    }

    /// 原子替换防止中断留下半份 LKG。
    private func save(_ record: CacheRecord, placement: String) throws {
        try FileManager.default.createDirectory(at: options.cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: cacheURL(placement), options: .atomic)
    }

    /// 缓存大小同样受限，损坏文件只会触发下一级兜底。
    private func read(placement: String) throws -> CacheRecord {
        let url = cacheURL(placement)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1100000 else { throw failure("cache_size") }
        return try JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: url))
    }

    private func failure(_ reason: String) -> PaywallValidationError { .init(path: "$.remote", reason: reason) }

    private struct CacheRecord: Codable {
        let manifest: Data
        let document: Data
        let reference: PaywallManifest.Reference
        let assignment: [String: String]
    }
}
