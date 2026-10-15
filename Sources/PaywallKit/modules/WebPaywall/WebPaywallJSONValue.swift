import Foundation

/// 宿主可传给 H5 的标准 JSON 值；不用于商品事实或页面文案。
public indirect enum WebPaywallJSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WebPaywallJSONValue])
    case array([WebPaywallJSONValue])
    case null

    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

extension WebPaywallJSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: WebPaywallJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, WebPaywallJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, latest in latest }))
    }
    public init(nilLiteral: ()) { self = .null }
}
