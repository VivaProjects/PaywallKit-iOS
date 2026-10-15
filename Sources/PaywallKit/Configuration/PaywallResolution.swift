public struct PaywallResolution {
    public enum Source: String { case remote, lastKnownGood, bundled, native }
    public let snapshot: PaywallSnapshot?
    public let source: Source
    public let failures: [String]
}
