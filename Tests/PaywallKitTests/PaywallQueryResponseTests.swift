import XCTest
@testable import PaywallKit

final class PaywallQueryResponseTests: XCTestCase {
    @MainActor
    private func load(_ json: String) async throws -> PaywallQueryResponse.Batch {
        try await PaywallQueryResponse.load(Data(json.utf8), configuration: .init(
            endpoint: URL(string: "https://example.com/query")!,
            runtimeEnvironment: .test, cacheNamespace: "query-tests",
            allowedOrigins: nil, placements: ["server_a": "a", "server_b": "b"]
        ), catalog: PaywallCatalog(productRefs: ["product"], recommendedRef: "product"))
    }

    func testEmptyResponseRemovesAllConfiguredPlacements() async throws {
        let batch = try await load(#"{"code":"200","data":[]}"#)
        XCTAssertEqual(batch.unmatched, Set(["a", "b"]))
        XCTAssertTrue(batch.pages.isEmpty)
    }

    func testMissingPlacementIsRemovedButReturnedInvalidURLIsPreserved() async throws {
        let batch = try await load(#"{"code":"200","data":[{"positionKey":"server_a","matched":true}]}"#)
        XCTAssertEqual(batch.unmatched, Set(["b"]))
    }

    func testExplicitUnmatchedAndOmittedPlacementsAreRemoved() async throws {
        let batch = try await load(#"{"code":"200","data":[{"positionKey":"server_a","matched":false}]}"#)
        XCTAssertEqual(batch.unmatched, Set(["a", "b"]))
    }

    func testUnknownServerPlacementDoesNotPreserveConfiguredPlacements() async throws {
        let batch = try await load(#"{"code":"200","data":[{"positionKey":"unknown","matched":true}]}"#)
        XCTAssertEqual(batch.unmatched, Set(["a", "b"]))
    }

    func testInvalidResponsesDoNotProduceCacheRemovalBatch() async {
        for json in [
            #"{"code":"200","data":null}"#,
            #"{"code":"200"}"#,
            #"{"code":"500","data":[]}"#,
            #"{"code":"200","data":[{"positionKey":"server_a"}]}"#
        ] {
            do {
                _ = try await load(json)
                XCTFail("Invalid response must fail before cache removal")
            } catch {}
        }
    }
}
