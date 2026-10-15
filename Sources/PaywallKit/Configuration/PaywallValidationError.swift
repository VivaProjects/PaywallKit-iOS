import Foundation

public struct PaywallValidationError: Error, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String { "\(path): \(reason)" }
}
