import Foundation
#if os(macOS)
import Darwin
#endif

private enum UpdateHelperError: Error {
    case invalidArguments
    case invalidPath
    case parentDidNotExit
    case launchFailed
    case healthTimeout
}

@main
private enum KanameUpdateHelper {
    static func main() {
        do {
            let values = try arguments(CommandLine.arguments)
            if CommandLine.arguments.contains("--switch") {
                try switchBundle(values)
            } else if CommandLine.arguments.contains("--rollback") {
                try rollback(values)
            } else {
                throw UpdateHelperError.invalidArguments
            }
        } catch {
            FileHandle.standardError.write(Data("kaname-update-helper: update failed\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func switchBundle(_ values: [String: String]) throws {
        let installed = try appURL(values["--installed"])
        let staged = try appURL(values["--staged"])
        let backup = try appURL(values["--backup"])
        let health = try fileURL(values["--health"])
        let receipt = try fileURL(values["--receipt"])
        let pid = try processID(values["--pid"])
        let timeout = Double(values["--timeout"] ?? "12") ?? 12
        try waitForExit(pid: pid, timeout: timeout)
        try? FileManager.default.removeItem(at: health)
        try prepareParent(of: backup)
        if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
        try FileManager.default.moveItem(at: installed, to: backup)
        do {
            try FileManager.default.moveItem(at: staged, to: installed)
            try launch(installed)
            try waitForHealth(
                at: health,
                version: values["--version"],
                build: values["--build"],
                timeout: timeout
            )
            try writeReceipt(.healthy, detail: "The updated UI passed its health handshake. Rollback remains available.", to: receipt)
        } catch {
            try? FileManager.default.removeItem(at: installed)
            try FileManager.default.moveItem(at: backup, to: installed)
            try launch(installed)
            try writeReceipt(.rolledBack, detail: "The candidate missed its health deadline. Kaname restored the previous bundle.", to: receipt)
            throw error
        }
    }

    private static func rollback(_ values: [String: String]) throws {
        let installed = try appURL(values["--installed"])
        let backup = try appURL(values["--backup"])
        let health = try fileURL(values["--health"])
        let receipt = try fileURL(values["--receipt"])
        let pid = try processID(values["--pid"])
        let timeout = Double(values["--timeout"] ?? "12") ?? 12
        try waitForExit(pid: pid, timeout: timeout)
        let replaced = installed.deletingLastPathComponent().appending(path: "Kaname Replaced.app", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: replaced.path) { try FileManager.default.removeItem(at: replaced) }
        try FileManager.default.moveItem(at: installed, to: replaced)
        try FileManager.default.moveItem(at: backup, to: installed)
        try? FileManager.default.removeItem(at: health)
        try launch(installed)
        try waitForHealth(at: health, version: nil, build: nil, timeout: timeout)
        try writeReceipt(.rolledBack, detail: "The previous Kaname bundle is active.", to: receipt)
    }

    private enum ReceiptStatus: String { case healthy, rolledBack }

    private static func writeReceipt(_ status: ReceiptStatus, detail: String, to url: URL) throws {
        let payload: [String: Any] = [
            "status": status.rawValue,
            "detail": detail,
            "updatedAtUnixMillis": Int64(Date().timeIntervalSince1970 * 1_000),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func launch(_ app: URL) throws {
        let arguments = ["/usr/bin/open", app.path]
        let storage = arguments.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        var argv = storage + [nil]
        var child: pid_t = 0
        guard posix_spawn(&child, arguments[0], nil, nil, &argv, environ) == 0 else {
            throw UpdateHelperError.launchFailed
        }
        var status: Int32 = 0
        guard waitpid(child, &status, 0) == child, status == 0 else {
            throw UpdateHelperError.launchFailed
        }
    }

    private static func waitForHealth(at url: URL, version: String?, build: String?, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (version?.isEmpty != false || object["version"] as? String == version),
               (build?.isEmpty != false || object["build"] as? String == build) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw UpdateHelperError.healthTimeout
    }

    private static func waitForExit(pid: Int32, timeout: Double) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw UpdateHelperError.parentDidNotExit
    }

    private static func arguments(_ arguments: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--switch" || key == "--rollback" { index += 1; continue }
            guard key.hasPrefix("--"), index + 1 < arguments.count else { throw UpdateHelperError.invalidArguments }
            result[key] = arguments[index + 1]
            index += 2
        }
        return result
    }

    private static func processID(_ value: String?) throws -> Int32 {
        guard let value, let pid = Int32(value), pid > 1 else { throw UpdateHelperError.invalidArguments }
        return pid
    }

    private static func appURL(_ value: String?) throws -> URL {
        let url = try fileURL(value)
        guard url.pathExtension == "app", url.path != "/", !url.path.contains("/../") else {
            throw UpdateHelperError.invalidPath
        }
        return url
    }

    private static func fileURL(_ value: String?) throws -> URL {
        guard let value, value.hasPrefix("/"), value != "/" else { throw UpdateHelperError.invalidPath }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func prepareParent(of url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}
