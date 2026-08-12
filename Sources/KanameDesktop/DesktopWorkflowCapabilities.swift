import CryptoKit
import Foundation
#if os(macOS)
import Darwin
#endif

public enum DesktopWorkflowCapabilityRuntime: String, Codable, CaseIterable, Equatable, Sendable {
    case builtIn
    case isolatedProcess

    public var label: String {
        switch self {
        case .builtIn: "Built into Kaname"
        case .isolatedProcess: "Isolated local process"
        }
    }
}

public enum DesktopWorkflowCapabilityTrust: String, Codable, CaseIterable, Equatable, Sendable {
    case kanameBuiltIn
    case designatedRequirement
    case localDigest

    public var label: String {
        switch self {
        case .kanameBuiltIn: "Kaname built-in"
        case .designatedRequirement: "Verified code signature"
        case .localDigest: "Locally pinned digest"
        }
    }
}

public struct DesktopWorkflowCapabilityLimits: Codable, Equatable, Sendable {
    public var timeoutSeconds: Int
    public var maximumInputBytes: Int
    public var maximumOutputBytes: Int
    public var maximumArtifactBytes: Int

    public init(
        timeoutSeconds: Int = 120,
        maximumInputBytes: Int = 8 * 1_024 * 1_024,
        maximumOutputBytes: Int = 8 * 1_024 * 1_024,
        maximumArtifactBytes: Int = 100 * 1_024 * 1_024
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
        self.maximumArtifactBytes = maximumArtifactBytes
    }
}

public struct DesktopWorkflowCapabilityManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let summary: String
    public let version: String
    public let source: String
    public let license: String
    public let runtime: DesktopWorkflowCapabilityRuntime
    public let trust: DesktopWorkflowCapabilityTrust
    public let entrypoint: String?
    public let executableSHA256: String?
    public let designatedRequirement: String?
    public let inputSchema: String
    public let outputSchema: String
    public let reviewSchema: String?
    public let permissions: DesktopWorkflowPermissionEnvelope
    public let limits: DesktopWorkflowCapabilityLimits
    public let deterministic: Bool
    public let idempotent: Bool
}

public enum DesktopWorkflowCapabilityError: Error, Equatable, LocalizedError, Sendable {
    case oversizedManifest
    case invalidManifest
    case unsafeEntrypoint
    case unsupportedRuntime
    case packageUnavailable
    case digestMismatch
    case signatureInvalid
    case installationCollision
    case inputTooLarge
    case executionUnavailable
    case executionTimedOut
    case executionFailed(String)
    case outputInvalid
    case artifactInvalid

    public var errorDescription: String? {
        switch self {
        case .oversizedManifest: "The capability manifest exceeds Kaname's 256 KiB limit."
        case .invalidManifest: "The capability manifest is incomplete or invalid."
        case .unsafeEntrypoint: "The capability entrypoint is not a safe package-relative executable."
        case .unsupportedRuntime: "This Kaname build does not support the requested capability runtime."
        case .packageUnavailable: "The installed capability package is unavailable."
        case .digestMismatch: "The capability bytes no longer match their reviewed digest."
        case .signatureInvalid: "The capability code signature does not match its reviewed requirement."
        case .installationCollision: "A different capability already occupies this immutable installation identity."
        case .inputTooLarge: "The capability input exceeds its declared limit."
        case .executionUnavailable: "Kaname's isolated capability runner is unavailable on this system."
        case .executionTimedOut: "The capability exceeded its reviewed execution limit."
        case let .executionFailed(detail): "The capability stopped without producing a successful result. \(detail)"
        case .outputInvalid: "The capability produced missing, oversized, or invalid structured output."
        case .artifactInvalid: "The capability produced an unsafe or oversized artifact."
        }
    }
}

public enum DesktopWorkflowCapabilityPackageCodec {
    public static let maximumManifestBytes = 256 * 1_024

    public static func decode(_ data: Data) throws -> DesktopWorkflowCapabilityManifest {
        guard !data.isEmpty, data.count <= maximumManifestBytes else {
            throw DesktopWorkflowCapabilityError.oversizedManifest
        }
        let manifest: DesktopWorkflowCapabilityManifest
        do { manifest = try JSONDecoder().decode(DesktopWorkflowCapabilityManifest.self, from: data) }
        catch { throw DesktopWorkflowCapabilityError.invalidManifest }
        try validate(manifest)
        return manifest
    }

    public static func canonicalData(_ manifest: DesktopWorkflowCapabilityManifest) throws -> Data {
        try validate(manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validate(_ manifest: DesktopWorkflowCapabilityManifest) throws {
        let identifier = #"^[a-z0-9][a-z0-9._-]{0,127}$"#
        let version = #"^[0-9]+(?:\.[0-9]+){0,3}$"#
        let digest = #"^[0-9a-f]{64}$"#
        let text = [manifest.name, manifest.summary, manifest.source, manifest.license,
                    manifest.inputSchema, manifest.outputSchema]
        guard manifest.schemaVersion == 1,
              manifest.id.range(of: identifier, options: .regularExpression) != nil,
              manifest.version.range(of: version, options: .regularExpression) != nil,
              text.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 64 * 1_024 }),
              manifest.reviewSchema.map({ !$0.isEmpty && $0.utf8.count <= 64 * 1_024 }) ?? true,
              (1...3_600).contains(manifest.limits.timeoutSeconds),
              (1...64 * 1_024 * 1_024).contains(manifest.limits.maximumInputBytes),
              (1...64 * 1_024 * 1_024).contains(manifest.limits.maximumOutputBytes),
              (1...512 * 1_024 * 1_024).contains(manifest.limits.maximumArtifactBytes) else {
            throw DesktopWorkflowCapabilityError.invalidManifest
        }
        guard DesktopWorkflowJSONSchemaValidator.validateSchema(Data(manifest.inputSchema.utf8)),
              DesktopWorkflowJSONSchemaValidator.validateSchema(Data(manifest.outputSchema.utf8)),
              manifest.reviewSchema.map({ DesktopWorkflowJSONSchemaValidator.validateSchema(Data($0.utf8)) }) ?? true else {
            throw DesktopWorkflowCapabilityError.invalidManifest
        }
        switch manifest.runtime {
        case .builtIn:
            guard manifest.trust == .kanameBuiltIn, manifest.entrypoint == nil,
                  manifest.executableSHA256 == nil, manifest.designatedRequirement == nil else {
                throw DesktopWorkflowCapabilityError.invalidManifest
            }
        case .isolatedProcess:
            guard manifest.trust != .kanameBuiltIn,
                  let entrypoint = manifest.entrypoint,
                  safeRelativePath(entrypoint),
                  manifest.executableSHA256?.range(of: digest, options: .regularExpression) != nil,
                  manifest.trust != .designatedRequirement
                    || (manifest.designatedRequirement?.isEmpty == false
                        && (manifest.designatedRequirement?.utf8.count ?? 0) <= 8_192) else {
                throw DesktopWorkflowCapabilityError.unsafeEntrypoint
            }
            guard manifest.permissions.networkDestinations.isEmpty else {
                throw DesktopWorkflowCapabilityError.unsupportedRuntime
            }
        }
        guard manifest.permissions.filesystemScopes.allSatisfy({ !$0.hasPrefix("/") && !$0.contains("..") }) else {
            throw DesktopWorkflowCapabilityError.invalidManifest
        }
    }

    public static func safeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024, !value.hasPrefix("/"), !value.contains("\\") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct DesktopWorkflowCapabilityInstallationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(capabilityID)@\(version)" }
    public var capabilityID: String
    public var version: String
    public var name: String
    public var summary: String
    public var runtime: DesktopWorkflowCapabilityRuntime
    public var trust: DesktopWorkflowCapabilityTrust
    public var packageDigest: String
    public var executableDigest: String?
    public var designatedRequirement: String?
    public var permissions: DesktopWorkflowPermissionEnvelope
    public var deterministic: Bool
    public var idempotent: Bool
    public var enabled: Bool
    public var lastTestedAtUnixMillis: Int64?
    public var lastTestPassed: Bool
    public var installedAtUnixMillis: Int64
}

public enum DesktopWorkflowBuiltinCapabilities {
    public static let identifiers: Set<String> = [
        "kaname.context.compile",
        "kaname.model.structured",
        "kaname.artifact.register",
        "kaname.validation.run",
        "kaname.email.read",
        "kaname.email.draft",
        "kaname.email.send",
    ]

    public static func installations(at timestamp: Int64) -> [DesktopWorkflowCapabilityInstallationRecord] {
        identifiers.sorted().map { identifier in
            let metadata = metadata(for: identifier)
            return DesktopWorkflowCapabilityInstallationRecord(
                capabilityID: identifier,
                version: "1.0.0",
                name: metadata.name,
                summary: metadata.summary,
                runtime: .builtIn,
                trust: .kanameBuiltIn,
                packageDigest: DesktopWorkflowCapabilityPackageCodec.digest(Data(identifier.utf8)),
                executableDigest: nil,
                designatedRequirement: nil,
                permissions: permissionEnvelope(for: identifier),
                deterministic: !identifier.hasPrefix("kaname.model.") && identifier != "kaname.email.send",
                idempotent: identifier != "kaname.email.send",
                enabled: true,
                lastTestedAtUnixMillis: timestamp,
                lastTestPassed: true,
                installedAtUnixMillis: timestamp
            )
        }
    }

    private static func metadata(for identifier: String) -> (name: String, summary: String) {
        switch identifier {
        case "kaname.context.compile": ("Context compiler", "Builds an immutable, provenance-backed workflow context.")
        case "kaname.model.structured": ("Structured model call", "Runs a schema-constrained provider step through Kaname.")
        case "kaname.artifact.register": ("Artifact registry", "Imports and relates immutable workflow artifacts.")
        case "kaname.validation.run": ("Validation host", "Records typed deterministic checks and blocking outcomes.")
        case "kaname.email.read": ("Gmail reader", "Reads account-scoped Gmail history, threads, and attachments.")
        case "kaname.email.draft": ("Gmail draft writer", "Creates and reconciles an exact Gmail draft.")
        case "kaname.email.send": ("Gmail sender", "Sends and reconciles an exactly approved Gmail message.")
        default: (identifier, "Kaname built-in workflow capability.")
        }
    }

    private static func permissionEnvelope(for identifier: String) -> DesktopWorkflowPermissionEnvelope {
        let permissions: [DesktopWorkflowPermission] = switch identifier {
        case "kaname.context.compile": []
        case "kaname.model.structured": [.modelEgress]
        case "kaname.artifact.register": [.fileRead, .fileWrite]
        case "kaname.validation.run": []
        case "kaname.email.read": [.emailRead]
        case "kaname.email.draft": [.emailDraft]
        case "kaname.email.send": [.emailSend]
        default: []
        }
        return DesktopWorkflowPermissionEnvelope(permissions: permissions, capabilityIDs: [identifier])
    }
}

public struct DesktopWorkflowCapabilityArtifact: Equatable, Sendable {
    public let relativePath: String
    public let data: Data
    public let sha256: String
}

public struct DesktopWorkflowCapabilityExecutionResult: Equatable, Sendable {
    public let output: Data
    public let outputDigest: String
    public let artifacts: [DesktopWorkflowCapabilityArtifact]
    public let standardOutput: String
    public let standardError: String
    public let elapsedMilliseconds: Int64
}

public struct DesktopWorkflowCapabilityStore: Sendable {
    public static let manifestFilename = "capability.json"
    private static let maximumPackageEntries = 1_000
    private static let maximumPackageBytes = 512 * 1_024 * 1_024
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func inspectPackage(at packageURL: URL, installedAtUnixMillis: Int64) throws -> (DesktopWorkflowCapabilityManifest, DesktopWorkflowCapabilityInstallationRecord) {
        let root = packageURL.standardizedFileURL
        try requireDirectory(root)
        let manifestURL = root.appendingPathComponent(Self.manifestFilename).standardizedFileURL
        guard manifestURL.deletingLastPathComponent() == root else { throw DesktopWorkflowCapabilityError.packageUnavailable }
        let data = try DesktopWorkflowFilesystem.requiredBoundedRegularData(
            at: manifestURL,
            maximumBytes: DesktopWorkflowCapabilityPackageCodec.maximumManifestBytes,
            mapped: true,
            failure: DesktopWorkflowCapabilityError.packageUnavailable
        )
        let manifest = try DesktopWorkflowCapabilityPackageCodec.decode(data)
        let packageDigest = try packageTreeDigest(root)
        var executableDigest: String?
        if let entrypoint = manifest.entrypoint {
            let executable = root.appendingPathComponent(entrypoint).standardizedFileURL
            try requireContainedRegularFile(executable, beneath: root, executable: true)
            let digest = try sha256(at: executable)
            guard digest == manifest.executableSHA256 else { throw DesktopWorkflowCapabilityError.digestMismatch }
            executableDigest = digest
            if manifest.trust == .designatedRequirement {
                try verifyCodeSignature(executable, requirement: manifest.designatedRequirement ?? "")
            }
        }
        return (manifest, DesktopWorkflowCapabilityInstallationRecord(
            capabilityID: manifest.id,
            version: manifest.version,
            name: manifest.name,
            summary: manifest.summary,
            runtime: manifest.runtime,
            trust: manifest.trust,
            packageDigest: packageDigest,
            executableDigest: executableDigest,
            designatedRequirement: manifest.designatedRequirement,
            permissions: manifest.permissions,
            deterministic: manifest.deterministic,
            idempotent: manifest.idempotent,
            enabled: false,
            lastTestedAtUnixMillis: nil,
            lastTestPassed: false,
            installedAtUnixMillis: installedAtUnixMillis
        ))
    }

    @discardableResult
    public func installPackage(at packageURL: URL, installedAtUnixMillis: Int64) throws -> DesktopWorkflowCapabilityInstallationRecord {
        let (manifest, receipt) = try inspectPackage(at: packageURL, installedAtUnixMillis: installedAtUnixMillis)
        let destination = installationDirectory(capabilityID: manifest.id, version: manifest.version)
        try privateDirectory(rootDirectory)
        if FileManager.default.fileExists(atPath: destination.path) {
            let existing = try inspectPackage(at: destination, installedAtUnixMillis: installedAtUnixMillis).1
            guard existing.packageDigest == receipt.packageDigest,
                  existing.executableDigest == receipt.executableDigest else {
                throw DesktopWorkflowCapabilityError.installationCollision
            }
            return receipt
        }
        let parent = destination.deletingLastPathComponent()
        try privateDirectory(parent)
        try FileManager.default.copyItem(at: packageURL, to: destination)
        try hardenTree(destination)
        let installed = try inspectPackage(at: destination, installedAtUnixMillis: installedAtUnixMillis).1
        guard installed.packageDigest == receipt.packageDigest,
              installed.executableDigest == receipt.executableDigest else {
            throw DesktopWorkflowCapabilityError.digestMismatch
        }
        return installed
    }

    public func manifest(for receipt: DesktopWorkflowCapabilityInstallationRecord) throws -> DesktopWorkflowCapabilityManifest {
        let directory = installationDirectory(capabilityID: receipt.capabilityID, version: receipt.version)
        let (manifest, current) = try inspectPackage(at: directory, installedAtUnixMillis: receipt.installedAtUnixMillis)
        guard current.packageDigest == receipt.packageDigest,
              current.executableDigest == receipt.executableDigest else {
            throw DesktopWorkflowCapabilityError.digestMismatch
        }
        return manifest
    }

    public func installationDirectory(capabilityID: String, version: String) -> URL {
        rootDirectory
            .appendingPathComponent(capabilityID, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
            .standardizedFileURL
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw DesktopWorkflowCapabilityError.packageUnavailable
        }
    }

    private func requireContainedRegularFile(_ url: URL, beneath root: URL, executable: Bool) throws {
        let rootPath = root.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(rootPath) else { throw DesktopWorkflowCapabilityError.unsafeEntrypoint }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 512 * 1_024 * 1_024,
              !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
            throw DesktopWorkflowCapabilityError.unsafeEntrypoint
        }
    }

    private func sha256(at url: URL) throws -> String {
        DesktopWorkflowCapabilityPackageCodec.digest(try DesktopWorkflowFilesystem.requiredBoundedRegularData(
            at: url,
            maximumBytes: 512 * 1_024 * 1_024,
            mapped: true,
            failure: DesktopWorkflowCapabilityError.packageUnavailable
        ))
    }

    private func packageTreeDigest(_ root: URL) throws -> String {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { throw DesktopWorkflowCapabilityError.packageUnavailable }
        let rootPath = root.standardizedFileURL.path + "/"
        var files: [(path: String, url: URL, size: Int)] = []
        var entryCount = 0
        var totalBytes = 0
        for case let candidate as URL in enumerator {
            entryCount += 1
            guard entryCount <= Self.maximumPackageEntries else {
                throw DesktopWorkflowCapabilityError.packageUnavailable
            }
            let url = candidate.standardizedFileURL
            guard url.path.hasPrefix(rootPath) else { throw DesktopWorkflowCapabilityError.unsafeEntrypoint }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw DesktopWorkflowCapabilityError.unsafeEntrypoint }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw DesktopWorkflowCapabilityError.packageUnavailable }
            let size = values.fileSize ?? 0
            totalBytes += size
            guard size >= 0, totalBytes <= Self.maximumPackageBytes else {
                throw DesktopWorkflowCapabilityError.packageUnavailable
            }
            files.append((String(url.path.dropFirst(rootPath.count)), url, size))
        }
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard DesktopWorkflowCapabilityPackageCodec.safeRelativePath(file.path) else {
                throw DesktopWorkflowCapabilityError.unsafeEntrypoint
            }
            let path = Data(file.path.utf8)
            update(&hasher, integer: UInt64(path.count))
            hasher.update(data: path)
            update(&hasher, integer: UInt64(file.size))
            hasher.update(data: try DesktopWorkflowFilesystem.requiredBoundedRegularData(
                at: file.url,
                maximumBytes: Self.maximumPackageBytes,
                mapped: true,
                failure: DesktopWorkflowCapabilityError.packageUnavailable
            ))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func update(_ hasher: inout SHA256, integer: UInt64) {
        var value = integer.bigEndian
        withUnsafeBytes(of: &value) { hasher.update(bufferPointer: $0) }
    }

    private func verifyCodeSignature(_ executable: URL, requirement: String) throws {
#if os(macOS)
        guard !requirement.isEmpty else { throw DesktopWorkflowCapabilityError.signatureInvalid }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--strict", "-R=(requirement)", executable.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DesktopWorkflowCapabilityError.signatureInvalid }
#else
        throw DesktopWorkflowCapabilityError.signatureInvalid
#endif
    }

    private func privateDirectory(_ url: URL) throws {
        try DesktopWorkflowFilesystem.preparePrivateDirectory(
            url,
            failure: DesktopWorkflowCapabilityError.packageUnavailable
        )
    }

    private func hardenTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { throw DesktopWorkflowCapabilityError.packageUnavailable }
#if os(macOS)
        guard chmod(root.path, 0o700) == 0 else { throw DesktopWorkflowCapabilityError.packageUnavailable }
#endif
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw DesktopWorkflowCapabilityError.unsafeEntrypoint }
#if os(macOS)
            if values.isDirectory == true { guard chmod(url.path, 0o700) == 0 else { throw DesktopWorkflowCapabilityError.packageUnavailable } }
            if values.isRegularFile == true {
                let mode: mode_t = FileManager.default.isExecutableFile(atPath: url.path) ? 0o700 : 0o600
                guard chmod(url.path, mode) == 0 else { throw DesktopWorkflowCapabilityError.packageUnavailable }
            }
#endif
        }
    }
}

public final class DesktopWorkflowCapabilityProcessRunner: @unchecked Sendable {
    public init() {}

    public func execute(
        manifest: DesktopWorkflowCapabilityManifest,
        installationDirectory: URL,
        input: Data,
        scratchRoot: URL
    ) throws -> DesktopWorkflowCapabilityExecutionResult {
        let resolvedInstallationDirectory = installationDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedScratchRoot = scratchRoot.resolvingSymlinksInPath().standardizedFileURL
        guard manifest.runtime == .isolatedProcess,
              let entrypoint = manifest.entrypoint,
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw DesktopWorkflowCapabilityError.executionUnavailable
        }
        guard input.count <= manifest.limits.maximumInputBytes else { throw DesktopWorkflowCapabilityError.inputTooLarge }
        guard DesktopWorkflowJSONSchemaValidator.validates(instance: input, against: manifest.inputSchema) else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        let started = Int64(Date().timeIntervalSince1970 * 1_000)
        let job = resolvedScratchRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let inputs = job.appendingPathComponent("Input", isDirectory: true)
        let outputs = job.appendingPathComponent("Output", isDirectory: true)
        let temporary = job.appendingPathComponent("Temporary", isDirectory: true)
        try privateDirectory(inputs)
        try privateDirectory(outputs)
        try privateDirectory(temporary)
        defer { try? FileManager.default.removeItem(at: job) }
        let inputURL = inputs.appendingPathComponent("input.json")
        let outputURL = outputs.appendingPathComponent("output.json")
        try writePrivate(input, to: inputURL)
        let executable = resolvedInstallationDirectory.appendingPathComponent(entrypoint).standardizedFileURL
        guard executable.path.hasPrefix(resolvedInstallationDirectory.path + "/") else {
            throw DesktopWorkflowCapabilityError.unsafeEntrypoint
        }
        let stdoutURL = temporary.appendingPathComponent("stdout.txt")
        let stderrURL = temporary.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let profile = sandboxProfile(
            installationDirectory: resolvedInstallationDirectory,
            inputDirectory: inputs,
            outputDirectory: outputs,
            temporaryDirectory: temporary
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let launch: [String]
        if try isPOSIXShellScript(executable) {
            launch = ["/bin/sh", executable.path]
        } else {
            launch = [executable.path]
        }
        process.arguments = ["-p", profile] + launch + ["--input", inputURL.path, "--output", outputURL.path]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "TMPDIR": temporary.path,
            "KANAME_CAPABILITY_ID": manifest.id,
            "KANAME_CAPABILITY_VERSION": manifest.version,
        ]
        process.currentDirectoryURL = temporary
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(TimeInterval(manifest.limits.timeoutSeconds))
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
#if os(macOS)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
#endif
            process.waitUntilExit()
            throw DesktopWorkflowCapabilityError.executionTimedOut
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = boundedText(at: stderrURL).trimmingCharacters(in: .whitespacesAndNewlines)
            throw DesktopWorkflowCapabilityError.executionFailed(
                detail.isEmpty ? "Exit status \(process.terminationStatus)." : String(detail.prefix(2_048))
            )
        }
        let output = try DesktopWorkflowFilesystem.requiredBoundedRegularData(
            at: outputURL,
            maximumBytes: manifest.limits.maximumOutputBytes,
            requiresNonEmpty: true,
            failure: DesktopWorkflowCapabilityError.outputInvalid
        )
        guard DesktopWorkflowJSONSchemaValidator.validates(instance: output, against: manifest.outputSchema) else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        let artifacts = try collectArtifacts(
            beneath: outputs.appendingPathComponent("Artifacts", isDirectory: true),
            maximumBytes: manifest.limits.maximumArtifactBytes
        )
        let finished = Int64(Date().timeIntervalSince1970 * 1_000)
        return DesktopWorkflowCapabilityExecutionResult(
            output: output,
            outputDigest: DesktopWorkflowCapabilityPackageCodec.digest(output),
            artifacts: artifacts,
            standardOutput: boundedText(at: stdoutURL),
            standardError: boundedText(at: stderrURL),
            elapsedMilliseconds: max(0, finished - started)
        )
    }

    private func sandboxProfile(
        installationDirectory: URL,
        inputDirectory: URL,
        outputDirectory: URL,
        temporaryDirectory: URL
    ) -> String {
        let installationPaths = sandboxAliases(for: installationDirectory.path)
        let readPaths = (installationPaths + sandboxAliases(for: inputDirectory.path) + ["/System", "/usr/lib", "/usr/bin", "/bin", "/Library/Apple"])
            .map { "(subpath \"\(escape($0))\")" }.joined(separator: " ")
        let writePaths = (sandboxAliases(for: outputDirectory.path) + sandboxAliases(for: temporaryDirectory.path))
            .map { "(subpath \"\(escape($0))\")" }.joined(separator: " ")
        return """
        (version 1)
        (import "system.sb")
        (deny default)
        (deny network*)
        (allow process*)
        (allow file-read* (require-any \(readPaths)))
        (allow file-write* (require-any \(writePaths)))
        (allow sysctl-read)
        (allow mach-lookup (global-name "com.apple.system.logger"))
        """
    }

    private func sandboxAliases(for path: String) -> [String] {
        guard path == "/var" || path.hasPrefix("/var/") else { return [path] }
        return [path, "/private\(path)"]
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func privateDirectory(_ url: URL) throws {
        try DesktopWorkflowFilesystem.preparePrivateDirectory(
            url,
            failure: DesktopWorkflowCapabilityError.executionUnavailable
        )
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try DesktopWorkflowFilesystem.writePrivate(
            data,
            to: url,
            failure: DesktopWorkflowCapabilityError.executionUnavailable
        )
    }

    private func isPOSIXShellScript(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 32) ?? Data()
        return prefix.starts(with: Data("#!/bin/sh".utf8))
            || prefix.starts(with: Data("#!/bin/bash".utf8))
            || prefix.starts(with: Data("#!/usr/bin/env sh".utf8))
    }

    private func boundedText(at url: URL) -> String {
        guard let data = try? Data(contentsOf: url), data.count <= 64 * 1_024 else { return "Output omitted because it exceeded 64 KiB." }
        return String(decoding: data, as: UTF8.self)
    }

    private func collectArtifacts(beneath root: URL, maximumBytes: Int) throws -> [DesktopWorkflowCapabilityArtifact] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw DesktopWorkflowCapabilityError.artifactInvalid }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw DesktopWorkflowCapabilityError.artifactInvalid }
        var artifacts: [DesktopWorkflowCapabilityArtifact] = []
        var total = 0
        for case let url as URL in enumerator {
            let item = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard item.isSymbolicLink != true else { throw DesktopWorkflowCapabilityError.artifactInvalid }
            guard item.isRegularFile == true else { continue }
            let size = item.fileSize ?? 0
            total += size
            guard artifacts.count < 50, size >= 0, total <= maximumBytes else { throw DesktopWorkflowCapabilityError.artifactInvalid }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            guard DesktopWorkflowCapabilityPackageCodec.safeRelativePath(relative) else { throw DesktopWorkflowCapabilityError.artifactInvalid }
            let data = try Data(contentsOf: url)
            artifacts.append(DesktopWorkflowCapabilityArtifact(
                relativePath: relative,
                data: data,
                sha256: DesktopWorkflowCapabilityPackageCodec.digest(data)
            ))
        }
        return artifacts.sorted { $0.relativePath < $1.relativePath }
    }
}
