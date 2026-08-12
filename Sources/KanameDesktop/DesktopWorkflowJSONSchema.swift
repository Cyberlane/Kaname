import CoreFoundation
import Foundation

public enum DesktopWorkflowJSONSchemaValidator {
    public static func validateSchema(_ data: Data) -> Bool {
        guard data.count <= 64 * 1_024,
              let schema = try? JSONSerialization.jsonObject(with: data),
              schema is [String: Any] else { return false }
        return schemaNodeIsSupported(schema)
    }

    public static func validates(instance: Data, against schemaText: String) -> Bool {
        guard let schemaData = schemaText.data(using: .utf8), validateSchema(schemaData),
              let schema = try? JSONSerialization.jsonObject(with: schemaData),
              let value = try? JSONSerialization.jsonObject(with: instance, options: [.fragmentsAllowed]) else {
            return false
        }
        return validate(value, schema: schema)
    }

    private static func schemaNodeIsSupported(_ value: Any) -> Bool {
        guard let schema = value as? [String: Any] else { return false }
        let supportedTypes = Set(["object", "array", "string", "number", "integer", "boolean", "null"])
        if let type = schema["type"] as? String, !supportedTypes.contains(type) { return false }
        if let types = schema["type"] as? [String], types.isEmpty || !Set(types).isSubset(of: supportedTypes) { return false }
        if let properties = schema["properties"] as? [String: Any],
           !properties.values.allSatisfy(schemaNodeIsSupported) { return false }
        if let items = schema["items"], !schemaNodeIsSupported(items) { return false }
        if let anyOf = schema["anyOf"] as? [Any], anyOf.isEmpty || !anyOf.allSatisfy(schemaNodeIsSupported) { return false }
        if let oneOf = schema["oneOf"] as? [Any], oneOf.isEmpty || !oneOf.allSatisfy(schemaNodeIsSupported) { return false }
        return true
    }

    private static func validate(_ value: Any, schema: Any) -> Bool {
        guard let schema = schema as? [String: Any] else { return false }
        if let constant = schema["const"], !jsonEqual(value, constant) { return false }
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { jsonEqual(value, $0) }) { return false }
        if let anyOf = schema["anyOf"] as? [Any], !anyOf.contains(where: { validate(value, schema: $0) }) { return false }
        if let oneOf = schema["oneOf"] as? [Any], oneOf.filter({ validate(value, schema: $0) }).count != 1 { return false }
        if let type = schema["type"] as? String, !matches(type: type, value: value) { return false }
        if let types = schema["type"] as? [String], !types.contains(where: { matches(type: $0, value: value) }) { return false }

        if let object = value as? [String: Any] {
            let required = Set(schema["required"] as? [String] ?? [])
            guard required.isSubset(of: Set(object.keys)) else { return false }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, child) in object {
                if let childSchema = properties[key] {
                    guard validate(child, schema: childSchema) else { return false }
                } else if schema["additionalProperties"] as? Bool == false {
                    return false
                }
            }
        }
        if let array = value as? [Any] {
            if let minimum = schema["minItems"] as? Int, array.count < minimum { return false }
            if let maximum = schema["maxItems"] as? Int, array.count > maximum { return false }
            if let items = schema["items"], !array.allSatisfy({ validate($0, schema: items) }) { return false }
        }
        if let string = value as? String {
            if let minimum = schema["minLength"] as? Int, string.count < minimum { return false }
            if let maximum = schema["maxLength"] as? Int, string.count > maximum { return false }
            if let pattern = schema["pattern"] as? String,
               string.range(of: pattern, options: .regularExpression) == nil { return false }
        }
        return true
    }

    private static func matches(type: String, value: Any) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "boolean":
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        case "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.rounded() == number.doubleValue
        case "number":
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func jsonEqual(_ left: Any, _ right: Any) -> Bool {
        guard JSONSerialization.isValidJSONObject([left]), JSONSerialization.isValidJSONObject([right]),
              let lhs = try? JSONSerialization.data(withJSONObject: [left], options: [.sortedKeys]),
              let rhs = try? JSONSerialization.data(withJSONObject: [right], options: [.sortedKeys]) else {
            return false
        }
        return lhs == rhs
    }
}
