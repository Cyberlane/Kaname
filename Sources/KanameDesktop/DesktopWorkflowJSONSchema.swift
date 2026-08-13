import CoreFoundation
import Foundation

public struct DesktopWorkflowJSONSchemaDiagnostic: Codable, Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// A deliberately declared, fail-closed subset of JSON Schema Draft 2020-12.
/// Package configuration and capability contracts share this implementation so
/// a schema accepted during import cannot mean something different at runtime.
public enum DesktopWorkflowJSONSchemaValidator {
    public static let dialect = "https://json-schema.org/draft/2020-12/schema"
    public static let maximumSchemaBytes = 64 * 1_024

    private static let supportedKeywords: Set<String> = [
        "$schema", "$id", "$anchor", "$comment", "$defs", "$ref",
        "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly",
        "type", "const", "enum", "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
        "properties", "required", "additionalProperties", "patternProperties", "minProperties", "maxProperties",
        "items", "prefixItems", "contains", "minContains", "maxContains", "minItems", "maxItems", "uniqueItems",
        "minLength", "maxLength", "pattern", "format",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    ]
    private static let supportedTypes = Set(["object", "array", "string", "number", "integer", "boolean", "null"])
    private static let supportedFormats = Set(["date", "date-time", "email", "hostname", "uri", "uuid"])

    public static func validateSchema(_ data: Data) -> Bool {
        schemaDiagnostics(data).isEmpty
    }

    public static func schemaDiagnostics(_ data: Data, requireDeclaredDialect: Bool = false) -> [DesktopWorkflowJSONSchemaDiagnostic] {
        guard data.count <= maximumSchemaBytes else {
            return [.init(path: "", message: "Schema exceeds the 64 KiB limit.")]
        }
        guard let root = try? JSONSerialization.jsonObject(with: data), root is [String: Any] else {
            return [.init(path: "", message: "Schema must be a JSON object.")]
        }
        var diagnostics: [DesktopWorkflowJSONSchemaDiagnostic] = []
        if requireDeclaredDialect, (root as? [String: Any])?["$schema"] as? String != dialect {
            diagnostics.append(.init(path: "/$schema", message: "Declare JSON Schema Draft 2020-12 exactly."))
        }
        inspectSchema(root, path: "", root: root, diagnostics: &diagnostics)
        return diagnostics
    }

    public static func validates(instance: Data, against schemaText: String) -> Bool {
        validationDiagnostics(instance: instance, against: schemaText).isEmpty
    }

    public static func validationDiagnostics(
        instance: Data,
        against schemaText: String
    ) -> [DesktopWorkflowJSONSchemaDiagnostic] {
        guard let schemaData = schemaText.data(using: .utf8) else {
            return [.init(path: "", message: "Schema is not UTF-8.")]
        }
        let schemaIssues = schemaDiagnostics(schemaData)
        guard schemaIssues.isEmpty,
              let schema = try? JSONSerialization.jsonObject(with: schemaData),
              let value = try? JSONSerialization.jsonObject(with: instance, options: [.fragmentsAllowed]) else {
            return schemaIssues.isEmpty
                ? [.init(path: "", message: "Instance is not valid JSON.")]
                : schemaIssues
        }
        var diagnostics: [DesktopWorkflowJSONSchemaDiagnostic] = []
        validate(value, schema: schema, root: schema, path: "", diagnostics: &diagnostics)
        return diagnostics
    }

    public static func defaultInstance(for schemaText: String) -> Data? {
        guard let data = schemaText.data(using: .utf8), schemaDiagnostics(data).isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data),
              let value = defaultValue(schema: root, root: root),
              JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func inspectSchema(
        _ value: Any,
        path: String,
        root: Any,
        diagnostics: inout [DesktopWorkflowJSONSchemaDiagnostic]
    ) {
        guard let schema = value as? [String: Any] else {
            diagnostics.append(.init(path: path, message: "Schema node must be an object."))
            return
        }
        for keyword in schema.keys where !supportedKeywords.contains(keyword) {
            diagnostics.append(.init(path: pointer(path, keyword), message: "Unsupported schema keyword \(keyword)."))
        }
        if let declared = schema["$schema"] as? String, declared != dialect {
            diagnostics.append(.init(path: pointer(path, "$schema"), message: "Unsupported JSON Schema dialect \(declared)."))
        }
        if let type = schema["type"] as? String, !supportedTypes.contains(type) {
            diagnostics.append(.init(path: pointer(path, "type"), message: "Unsupported type \(type)."))
        } else if let types = schema["type"] as? [String], types.isEmpty || !Set(types).isSubset(of: supportedTypes) {
            diagnostics.append(.init(path: pointer(path, "type"), message: "Type array contains an unsupported value."))
        } else if schema["type"] != nil && schema["type"] as? String == nil && schema["type"] as? [String] == nil {
            diagnostics.append(.init(path: pointer(path, "type"), message: "Type must be a string or string array."))
        }
        if let format = schema["format"] as? String, !supportedFormats.contains(format) {
            diagnostics.append(.init(path: pointer(path, "format"), message: "Unsupported string format \(format)."))
        }
        if let pattern = schema["pattern"] as? String,
           (try? NSRegularExpression(pattern: pattern)) == nil {
            diagnostics.append(.init(path: pointer(path, "pattern"), message: "Pattern is not a valid regular expression."))
        }
        if let reference = schema["$ref"] as? String, resolve(reference: reference, root: root) == nil {
            diagnostics.append(.init(path: pointer(path, "$ref"), message: "Only resolvable local JSON Pointer references are supported."))
        }
        inspectMap(schema["$defs"], path: pointer(path, "$defs"), root: root, diagnostics: &diagnostics)
        inspectMap(schema["properties"], path: pointer(path, "properties"), root: root, diagnostics: &diagnostics)
        inspectMap(schema["patternProperties"], path: pointer(path, "patternProperties"), root: root, diagnostics: &diagnostics)
        for keyword in ["items", "contains", "not", "if", "then", "else"] {
            if let child = schema[keyword] {
                inspectSchema(child, path: pointer(path, keyword), root: root, diagnostics: &diagnostics)
            }
        }
        if let additional = schema["additionalProperties"], additional as? Bool == nil {
            inspectSchema(additional, path: pointer(path, "additionalProperties"), root: root, diagnostics: &diagnostics)
        }
        for keyword in ["allOf", "anyOf", "oneOf", "prefixItems"] {
            if let children = schema[keyword] as? [Any] {
                if children.isEmpty { diagnostics.append(.init(path: pointer(path, keyword), message: "Array must not be empty.")) }
                for (index, child) in children.enumerated() {
                    inspectSchema(child, path: pointer(pointer(path, keyword), String(index)), root: root, diagnostics: &diagnostics)
                }
            } else if schema[keyword] != nil {
                diagnostics.append(.init(path: pointer(path, keyword), message: "Keyword must be an array of schemas."))
            }
        }
    }

    private static func inspectMap(
        _ value: Any?, path: String, root: Any,
        diagnostics: inout [DesktopWorkflowJSONSchemaDiagnostic]
    ) {
        guard let value else { return }
        guard let map = value as? [String: Any] else {
            diagnostics.append(.init(path: path, message: "Keyword must be an object of schemas."))
            return
        }
        for (key, child) in map {
            inspectSchema(child, path: pointer(path, key), root: root, diagnostics: &diagnostics)
        }
    }

    private static func validate(
        _ value: Any,
        schema rawSchema: Any,
        root: Any,
        path: String,
        diagnostics: inout [DesktopWorkflowJSONSchemaDiagnostic]
    ) {
        guard let schema = resolvedSchema(rawSchema, root: root) else {
            diagnostics.append(.init(path: path, message: "Schema reference could not be resolved."))
            return
        }
        if let constant = schema["const"], !jsonEqual(value, constant) {
            diagnostics.append(.init(path: path, message: "Value does not match the required constant."))
        }
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { jsonEqual(value, $0) }) {
            diagnostics.append(.init(path: path, message: "Value is not one of the allowed choices."))
        }
        if let allOf = schema["allOf"] as? [Any] {
            for child in allOf { validate(value, schema: child, root: root, path: path, diagnostics: &diagnostics) }
        }
        if let anyOf = schema["anyOf"] as? [Any], !anyOf.contains(where: { conforms(value, schema: $0, root: root) }) {
            diagnostics.append(.init(path: path, message: "Value does not satisfy any allowed schema."))
        }
        if let oneOf = schema["oneOf"] as? [Any], oneOf.filter({ conforms(value, schema: $0, root: root) }).count != 1 {
            diagnostics.append(.init(path: path, message: "Value must satisfy exactly one allowed schema."))
        }
        if let child = schema["not"], conforms(value, schema: child, root: root) {
            diagnostics.append(.init(path: path, message: "Value satisfies a forbidden schema."))
        }
        if let condition = schema["if"], conforms(value, schema: condition, root: root) {
            if let child = schema["then"] { validate(value, schema: child, root: root, path: path, diagnostics: &diagnostics) }
        } else if let child = schema["else"] {
            validate(value, schema: child, root: root, path: path, diagnostics: &diagnostics)
        }
        if let type = schema["type"] as? String, !matches(type: type, value: value) {
            diagnostics.append(.init(path: path, message: "Expected \(type)."))
            return
        }
        if let types = schema["type"] as? [String], !types.contains(where: { matches(type: $0, value: value) }) {
            diagnostics.append(.init(path: path, message: "Value has none of the allowed types."))
            return
        }

        if let object = value as? [String: Any] {
            let required = Set(schema["required"] as? [String] ?? [])
            for key in required.subtracting(object.keys) {
                diagnostics.append(.init(path: pointer(path, key), message: "Required value is missing."))
            }
            if let minimum = integer(schema["minProperties"]), object.count < minimum {
                diagnostics.append(.init(path: path, message: "Object has fewer than \(minimum) properties."))
            }
            if let maximum = integer(schema["maxProperties"]), object.count > maximum {
                diagnostics.append(.init(path: path, message: "Object has more than \(maximum) properties."))
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let patterns = schema["patternProperties"] as? [String: Any] ?? [:]
            for (key, child) in object {
                var matched = false
                if let childSchema = properties[key] {
                    matched = true
                    validate(child, schema: childSchema, root: root, path: pointer(path, key), diagnostics: &diagnostics)
                }
                for (pattern, patternSchema) in patterns where key.range(of: pattern, options: .regularExpression) != nil {
                    matched = true
                    validate(child, schema: patternSchema, root: root, path: pointer(path, key), diagnostics: &diagnostics)
                }
                if !matched, let additional = schema["additionalProperties"] {
                    if additional as? Bool == false {
                        diagnostics.append(.init(path: pointer(path, key), message: "Additional property is not allowed."))
                    } else if additional as? Bool == nil {
                        validate(child, schema: additional, root: root, path: pointer(path, key), diagnostics: &diagnostics)
                    }
                }
            }
        }
        if let array = value as? [Any] {
            if let minimum = integer(schema["minItems"]), array.count < minimum {
                diagnostics.append(.init(path: path, message: "Array has fewer than \(minimum) items."))
            }
            if let maximum = integer(schema["maxItems"]), array.count > maximum {
                diagnostics.append(.init(path: path, message: "Array has more than \(maximum) items."))
            }
            if schema["uniqueItems"] as? Bool == true {
                for index in array.indices where array[..<index].contains(where: { jsonEqual($0, array[index]) }) {
                    diagnostics.append(.init(path: pointer(path, String(index)), message: "Array item must be unique."))
                }
            }
            let prefix = schema["prefixItems"] as? [Any] ?? []
            for index in array.indices {
                if index < prefix.count {
                    validate(array[index], schema: prefix[index], root: root, path: pointer(path, String(index)), diagnostics: &diagnostics)
                } else if let items = schema["items"] {
                    validate(array[index], schema: items, root: root, path: pointer(path, String(index)), diagnostics: &diagnostics)
                }
            }
            if let contains = schema["contains"] {
                let count = array.filter { conforms($0, schema: contains, root: root) }.count
                let minimum = integer(schema["minContains"]) ?? 1
                let maximum = integer(schema["maxContains"]) ?? Int.max
                if count < minimum || count > maximum {
                    diagnostics.append(.init(path: path, message: "Array contains \(count) matching items; expected \(minimum)...\(maximum)."))
                }
            }
        }
        if let string = value as? String {
            if let minimum = integer(schema["minLength"]), string.count < minimum {
                diagnostics.append(.init(path: path, message: "String is shorter than \(minimum) characters."))
            }
            if let maximum = integer(schema["maxLength"]), string.count > maximum {
                diagnostics.append(.init(path: path, message: "String is longer than \(maximum) characters."))
            }
            if let pattern = schema["pattern"] as? String,
               string.range(of: pattern, options: .regularExpression) == nil {
                diagnostics.append(.init(path: path, message: "String does not match the required pattern."))
            }
            if let format = schema["format"] as? String, !matches(format: format, string: string) {
                diagnostics.append(.init(path: path, message: "String is not a valid \(format)."))
            }
        }
        if let number = numeric(value) {
            if let minimum = numeric(schema["minimum"]), number < minimum { diagnostics.append(.init(path: path, message: "Number is below \(minimum).")) }
            if let maximum = numeric(schema["maximum"]), number > maximum { diagnostics.append(.init(path: path, message: "Number is above \(maximum).")) }
            if let minimum = numeric(schema["exclusiveMinimum"]), number <= minimum { diagnostics.append(.init(path: path, message: "Number must be greater than \(minimum).")) }
            if let maximum = numeric(schema["exclusiveMaximum"]), number >= maximum { diagnostics.append(.init(path: path, message: "Number must be less than \(maximum).")) }
            if let multiple = numeric(schema["multipleOf"]), multiple > 0 {
                let quotient = number / multiple
                if abs(quotient.rounded() - quotient) > 0.000_000_001 {
                    diagnostics.append(.init(path: path, message: "Number must be a multiple of \(multiple)."))
                }
            }
        }
    }

    private static func resolvedSchema(_ raw: Any, root: Any) -> [String: Any]? {
        guard let schema = raw as? [String: Any] else { return nil }
        guard let reference = schema["$ref"] as? String else { return schema }
        guard var resolved = resolve(reference: reference, root: root) as? [String: Any] else { return nil }
        for (key, value) in schema where key != "$ref" { resolved[key] = value }
        return resolved
    }

    private static func resolve(reference: String, root: Any) -> Any? {
        guard reference == "#" || reference.hasPrefix("#/") else { return nil }
        if reference == "#" { return root }
        var current: Any = root
        for segment in reference.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let key = String(segment).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let object = current as? [String: Any], let next = object[key] else { return nil }
            current = next
        }
        return current
    }

    private static func conforms(_ value: Any, schema: Any, root: Any) -> Bool {
        var diagnostics: [DesktopWorkflowJSONSchemaDiagnostic] = []
        validate(value, schema: schema, root: root, path: "", diagnostics: &diagnostics)
        return diagnostics.isEmpty
    }

    private static func defaultValue(schema raw: Any, root: Any) -> Any? {
        guard let schema = resolvedSchema(raw, root: root) else { return nil }
        if let value = schema["default"] { return value }
        if let constant = schema["const"] { return constant }
        if let first = (schema["enum"] as? [Any])?.first { return first }
        if schema["type"] as? String == "object" || schema["properties"] != nil {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            var object: [String: Any] = [:]
            for (key, child) in properties.sorted(by: { $0.key < $1.key }) {
                if let value = defaultValue(schema: child, root: root) { object[key] = value }
            }
            return object
        }
        if schema["type"] as? String == "array" { return [] }
        return nil
    }

    private static func matches(type: String, value: Any) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean": return isBoolean(value)
        case "integer": guard let number = numeric(value), !isBoolean(value) else { return false }; return number.rounded() == number
        case "number": return numeric(value) != nil && !isBoolean(value)
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func matches(format: String, string: String) -> Bool {
        switch format {
        case "date": return ISO8601DateFormatter().date(from: string + "T00:00:00Z") != nil
        case "date-time": return ISO8601DateFormatter().date(from: string) != nil
        case "email": return string.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
        case "hostname": return string.utf8.count <= 253 && string.range(of: #"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$"#, options: .regularExpression) != nil
        case "uri": return URL(string: string)?.scheme != nil
        case "uuid": return UUID(uuidString: string) != nil
        default: return false
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.intValue
    }

    private static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject([left]), JSONSerialization.isValidJSONObject([right]),
              let lhs = try? JSONSerialization.data(withJSONObject: [left], options: [.sortedKeys]),
              let rhs = try? JSONSerialization.data(withJSONObject: [right], options: [.sortedKeys]) else { return false }
        return lhs == rhs
    }

    private static func pointer(_ base: String, _ component: String) -> String {
        let escaped = component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        return base + "/" + escaped
    }
}
