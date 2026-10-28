import Foundation

/// 网络读取可提前进行，结果必须在启动版本冻结后才交给提交方。
enum PaywallQueryStartup {
    /// 请求条件只采集一次；冻结后迁移旧缓存，再消费并行请求的响应。
    static func load<Request, Value>(restore: () async -> Void,
                                     prepare: () async throws -> Request,
                                     fetch: (Request) async throws -> Value,
                                     frozen: (Request) async throws -> Void) async throws -> (Request, Value) {
        async let restoring: Void = restore()
        let prepared = try await prepare()
        async let response = fetch(prepared)
        await restoring
        try Task.checkCancellation()
        // 旧缓存迁移只依赖请求身份和启动冻结，不能等待慢网络响应。
        try await frozen(prepared)
        return (prepared, try await response)
    }
}
