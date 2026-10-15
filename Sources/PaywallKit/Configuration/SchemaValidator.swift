import Foundation
import CoreFoundation

/// 只解释随包发布的 Schema 子集，规则文件不能由远端替换。
struct SchemaValidator {
    let root: [String: Any]

    /// 按精确路径报告首个结构错误。
    func validate(_ value: Any, schema: [String: Any]? = nil, path: String = "$") throws {
        let rule = schema ?? root
        if let ref = rule["$ref"] as? String {
            let name = String(ref.dropFirst("#/$defs/".count))
            guard let defs = root["$defs"] as? [String: [String: Any]], let target = defs[name] else {
                throw PaywallValidationError(path: path, reason: "invalid_schema_reference")
            }
            return try validate(value, schema: target, path: path)
        }
        if let options = rule["anyOf"] as? [[String: Any]] {
            // 节点按 type 定位分支，保留 Props 内的具体错误路径。
            if let node = value as? [String: Any], let type = node["type"] as? String,
               let option = options.first(where: { ($0["$ref"] as? String) == "#/$defs/\(type)" }) {
                return try validate(value, schema: option, path: path)
            }
            throw PaywallValidationError(path: path, reason: "unknown_component")
        }
        if let constant = rule["const"], !equal(value, constant) { try fail(path, "const") }
        if let values = rule["enum"] as? [Any], !values.contains(where: { equal(value, $0) }) {
            try fail(path, "enum")
        }
        try validateType(value, rule: rule, path: path)
    }

    /// 区分布尔值与数字，防止 JSON true 被当作版本号 1。
    private func validateType(_ value: Any, rule: [String: Any], path: String) throws {
        switch rule["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { return try fail(path, "object") }
            try validateObject(object, rule: rule, path: path)
        case "array":
            guard let list = value as? [Any] else { return try fail(path, "array") }
            try validateArray(list, rule: rule, path: path)
        case "string":
            guard let text = value as? String else { return try fail(path, "string") }
            try bounds(Double(text.unicodeScalars.count), rule, "minLength", "maxLength", path)
            if let pattern = rule["pattern"] as? String,
               text.range(of: pattern, options: .regularExpression) == nil { try fail(path, "pattern") }
        case "integer", "number":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return try fail(path, "number") }
            let n = number.doubleValue
            if rule["type"] as? String == "integer", n.rounded() != n { try fail(path, "integer") }
            try bounds(n, rule, "minimum", "maximum", path)
        case "boolean":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                return try fail(path, "boolean")
            }
        default: break
        }
    }

    /// 对象采用白名单，额外字段在客户端同样阻断。
    private func validateObject(_ object: [String: Any], rule: [String: Any], path: String) throws {
        try bounds(Double(object.count), rule, "minProperties", "maxProperties", path)
        let props = rule["properties"] as? [String: [String: Any]] ?? [:]
        for key in rule["required"] as? [String] ?? [] where object[key] == nil {
            try fail("\(path).\(key)", "required")
        }
        for (key, value) in object {
            if let child = props[key] ?? (rule["additionalProperties"] as? [String: Any]) {
                try validate(value, schema: child, path: "\(path).\(key)")
            } else if rule["additionalProperties"] as? Bool == false {
                try fail("\(path).\(key)", "unknown_field")
            }
        }
    }

    /// 列表先限制规模再检查内容，避免递归放大。
    private func validateArray(_ list: [Any], rule: [String: Any], path: String) throws {
        try bounds(Double(list.count), rule, "minItems", "maxItems", path)
        if rule["uniqueItems"] as? Bool == true {
            for index in list.indices where list[..<index].contains(where: { equal($0, list[index]) }) {
                try fail(path, "duplicate_item")
            }
        }
        if let item = rule["items"] as? [String: Any] {
            for (index, value) in list.enumerated() {
                try validate(value, schema: item, path: "\(path)[\(index)]")
            }
        }
    }

    /// 校验 Schema 中显式声明的上下限。
    private func bounds(_ value: Double, _ rule: [String: Any], _ min: String, _ max: String, _ path: String) throws {
        if let lower = rule[min] as? NSNumber, value < lower.doubleValue { try fail(path, min) }
        if let upper = rule[max] as? NSNumber, value > upper.doubleValue { try fail(path, max) }
    }

    /// 标量等值比较保留 JSON 布尔和数值的类型边界。
    private func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            return (CFGetTypeID(a) == CFBooleanGetTypeID()) == (CFGetTypeID(b) == CFBooleanGetTypeID()) && a == b
        }
        if let a = lhs as? String, let b = rhs as? String { return a == b }
        return false
    }

    /// 统一抛出可定位的错误，禁止静默跳过。
    private func fail(_ path: String, _ reason: String) throws {
        throw PaywallValidationError(path: path, reason: reason)
    }
}
