import Foundation
import KanameDesktop

// Kaname workflow capability host.
//
// The Rust executor runs `KanameWorkflowCapabilityHost describe` once and
// `KanameWorkflowCapabilityHost invoke` per compute.capability attempt, with
// one JSON request on stdin and one JSON response on stdout. Capabilities are
// the `.kanamecapability` packages the user installed through Automations;
// each runs inside the same sandbox-exec profile the desktop uses for its
// test runs. The executor clears the environment, so the host locates the
// Application Support roots itself.

struct HostFailure: Error {
    let outcome: String
    let summary: String
}

enum HostEnvironment {
    static var home: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return home }
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    /// Every Kaname channel keeps its own Application Support root; digests
    /// disambiguate packages, so all of them are scanned.
    static var capabilityRoots: [URL] {
        let support = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: support.path)) ?? []
        return names
            .filter { $0 == "Kaname" || $0.hasPrefix("Kaname ") }
            .sorted()
            .map { support.appendingPathComponent($0, isDirectory: true).appendingPathComponent("WorkflowCapabilities", isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct InstalledCapability {
    let manifest: DesktopWorkflowCapabilityManifest
    let record: DesktopWorkflowCapabilityInstallationRecord
    let directory: URL
}

func installedCapabilities() -> [InstalledCapability] {
    var found: [InstalledCapability] = []
    let now = Int64(Date().timeIntervalSince1970 * 1_000)
    for root in HostEnvironment.capabilityRoots {
        let store = DesktopWorkflowCapabilityStore(rootDirectory: root)
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in ids where !id.hasPrefix(".") {
            let idDirectory = root.appendingPathComponent(id, isDirectory: true)
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: idDirectory.path)) ?? []
            for version in versions where !version.hasPrefix(".") {
                let directory = idDirectory.appendingPathComponent(version, isDirectory: true)
                guard let (manifest, record) = try? store.inspectPackage(at: directory, installedAtUnixMillis: now) else { continue }
                found.append(InstalledCapability(manifest: manifest, record: record, directory: directory))
            }
        }
    }
    return found
}

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func schemaObject(_ text: String) -> Any {
    guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else {
        return ["type": "object"]
    }
    return value
}

func describe() {
    let capabilities: [[String: Any]] = installedCapabilities().map { installed in
        [
            "capabilityId": installed.manifest.id,
            "version": installed.manifest.version,
            "packageDigest": installed.record.packageDigest,
            "configurationSchema": ["type": "object"] as [String: Any],
            "inputSchema": schemaObject(installed.manifest.inputSchema),
            "outputSchema": schemaObject(installed.manifest.outputSchema),
            "timeoutMilliseconds": UInt64(max(1, installed.manifest.limits.timeoutSeconds)) * 1_000,
            "deterministic": installed.manifest.deterministic,
            "idempotent": installed.manifest.idempotent,
        ]
    }
    emit(["capabilities": capabilities])
}

func invoke() {
    let requestData = FileHandle.standardInput.readDataToEndOfFile()
    guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
        emit(["outcome": "malformed_result", "summary": "The invocation request was not valid JSON."])
        return
    }
    let invocationID = (request["invocationId"] as? String) ?? ""
    let receiptID = "receipt-\(invocationID)"
    let capabilityID = (request["capabilityId"] as? String) ?? ""
    let version = (request["version"] as? String) ?? ""
    let digest = (request["packageDigest"] as? String) ?? ""
    guard let installed = installedCapabilities().first(where: {
        $0.manifest.id == capabilityID && $0.manifest.version == version && $0.record.packageDigest == digest
    }) else {
        emit(["outcome": "crashed", "summary": "No installed capability matches \(capabilityID)@\(version) with digest \(digest.prefix(12)).", "receiptId": receiptID])
        return
    }
    let inline = (request["input"] as? [String: Any])?["inline"]
    guard let inline, JSONSerialization.isValidJSONObject(inline) || inline is String || inline is NSNumber,
          let inputData = try? JSONSerialization.data(withJSONObject: inline, options: [.sortedKeys, .fragmentsAllowed]) else {
        emit(["outcome": "malformed_result", "summary": "The invocation carried no inline input value.", "receiptId": receiptID])
        return
    }
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("kaname-capability-host", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
        let result = try DesktopWorkflowCapabilityProcessRunner().execute(
            manifest: installed.manifest,
            installationDirectory: installed.directory,
            input: inputData,
            scratchRoot: scratch
        )
        let output = (try? JSONSerialization.jsonObject(with: result.output, options: [.fragmentsAllowed])) ?? NSNull()
        var logs: [[String: Any]] = []
        if !result.standardOutput.isEmpty { logs.append(["level": "info", "message": String(result.standardOutput.prefix(4_000)), "offsetMilliseconds": 0]) }
        if !result.standardError.isEmpty { logs.append(["level": "error", "message": String(result.standardError.prefix(4_000)), "offsetMilliseconds": 0]) }
        emit([
            "outcome": "succeeded",
            "output": output,
            "elapsedMilliseconds": UInt64(max(0, result.elapsedMilliseconds)),
            "receiptId": receiptID,
            "providerRunReference": result.outputDigest,
            "logs": logs,
        ])
    } catch {
        let description = error.localizedDescription
        let outcome = description.localizedCaseInsensitiveContains("time") ? "timed_out" : "crashed"
        emit(["outcome": outcome, "summary": description, "receiptId": receiptID])
    }
}

switch CommandLine.arguments.dropFirst().first {
case "describe": describe()
case "invoke": invoke()
default:
    FileHandle.standardError.write(Data("usage: KanameWorkflowCapabilityHost describe|invoke < request.json\n".utf8))
    exit(64)
}
