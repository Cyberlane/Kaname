#if os(macOS)
import CryptoKit
import Foundation

public enum KanameLinkTunnelSupervisorFailure: Error, Equatable, LocalizedError, Sendable {
    case invalidPath
    case invalidDigest
    case artifactUnavailable(String)
    case artifactMismatch(String)
    case receiptMismatch
    case alreadyRunning
    case processLaunchFailed
    case tokenPipeWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPath:
            "Tunnel runtime paths must be exact, canonical, absolute file paths."
        case .invalidDigest:
            "The pinned Node runtime digest is invalid."
        case let .artifactUnavailable(name):
            "The verified tunnel runtime artifact is unavailable: \(name)."
        case let .artifactMismatch(name):
            "The tunnel runtime artifact does not match its pinned identity: \(name)."
        case .receiptMismatch:
            "The cloudflared install receipt does not bind the exact requested binary."
        case .alreadyRunning:
            "The checked-in cloudflared supervisor is already running."
        case .processLaunchFailed:
            "The checked-in cloudflared supervisor could not be started."
        case .tokenPipeWriteFailed:
            "The connector credential could not be delivered through the anonymous stdin pipe."
        }
    }
}

public struct KanameLinkTunnelSupervisorPaths: Equatable, Sendable {
    public let nodeExecutableURL: URL
    public let nodeExecutableSHA256: String
    public let cloudflaredBinaryURL: URL
    public let installReceiptURL: URL
    public let supervisorScriptURL: URL
    public let runtimeManifestURL: URL

    public init(
        nodeExecutableURL: URL,
        nodeExecutableSHA256: String,
        cloudflaredBinaryURL: URL,
        installReceiptURL: URL,
        supervisorScriptURL: URL,
        runtimeManifestURL: URL
    ) throws {
        let urls = [
            nodeExecutableURL,
            cloudflaredBinaryURL,
            installReceiptURL,
            supervisorScriptURL,
            runtimeManifestURL,
        ]
        guard urls.allSatisfy(Self.isCanonicalAbsoluteFileURL),
              Set(urls.map(\.path)).count == urls.count,
              nodeExecutableURL.lastPathComponent == "node",
              cloudflaredBinaryURL.lastPathComponent == "cloudflared",
              supervisorScriptURL.lastPathComponent == "kaname-link-cloudflared-supervisor.mjs",
              runtimeManifestURL.lastPathComponent == "cloudflared-runtime.json" else {
            throw KanameLinkTunnelSupervisorFailure.invalidPath
        }
        let normalizedDigest = nodeExecutableSHA256.lowercased()
        guard normalizedDigest.utf8.count == 64,
              normalizedDigest.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              }) else {
            throw KanameLinkTunnelSupervisorFailure.invalidDigest
        }
        self.nodeExecutableURL = nodeExecutableURL
        self.nodeExecutableSHA256 = normalizedDigest
        self.cloudflaredBinaryURL = cloudflaredBinaryURL
        self.installReceiptURL = installReceiptURL
        self.supervisorScriptURL = supervisorScriptURL
        self.runtimeManifestURL = runtimeManifestURL
    }

    var runtimeScriptURL: URL {
        supervisorScriptURL.deletingLastPathComponent()
            .appendingPathComponent("kaname-link-cloudflared-runtime.mjs", isDirectory: false)
    }

    var commonScriptURL: URL {
        supervisorScriptURL.deletingLastPathComponent()
            .appendingPathComponent("kaname-link-delivery-common.mjs", isDirectory: false)
    }

    func launchRequest() -> KanameLinkTunnelSupervisorLaunchRequest {
        KanameLinkTunnelSupervisorLaunchRequest(
            executableURL: nodeExecutableURL,
            arguments: [
                supervisorScriptURL.path,
                "--binary", cloudflaredBinaryURL.path,
                "--receipt", installReceiptURL.path,
                "--manifest", runtimeManifestURL.path,
            ],
            environment: [
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin",
            ]
        )
    }

    private static func isCanonicalAbsoluteFileURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.path.hasPrefix("/")
            && url.pathComponents.count > 2
            && url.path == url.standardizedFileURL.path
    }
}

public protocol KanameLinkTunnelArtifactVerifying: Sendable {
    func verify(_ paths: KanameLinkTunnelSupervisorPaths) throws
}

public struct FileSystemKanameLinkTunnelArtifactVerifier: KanameLinkTunnelArtifactVerifying,
    Sendable
{
    static let cloudflaredVersion = "2026.8.2"
    static let manifestDigest = "59ef4956bea999dabdef864baa155d2d2ab5c8fb2d5be54d8b11f072772611d4"
    static let supervisorScriptSHA256 = "eb8ac8b14c8a368d09d41b5e20e8dc9e7a9ed50818413ca56036e1285750e646"
    static let runtimeScriptSHA256 = "f96280bc843468d11dfcaaf85e0d2c84cc8ef8a813730d20120c2b09f5397f11"
    static let commonScriptSHA256 = "690525050aba35362254bcf6cb4f167d2f00c057ff8e7a7bd5075314615aa235"
    static let runtimeManifestSHA256 = "fc6555defc9af251999eb470fa32d9aedc1f0e3bd663f2122a64b8ff51752170"

    public init() {}

    public func verify(_ paths: KanameLinkTunnelSupervisorPaths) throws {
        try verifyArtifact(
            paths.nodeExecutableURL,
            label: "node",
            expectedSHA256: paths.nodeExecutableSHA256,
            maximumBytes: 256 * 1_024 * 1_024,
            executable: true
        )
        try verifyArtifact(
            paths.supervisorScriptURL,
            label: "supervisor script",
            expectedSHA256: Self.supervisorScriptSHA256,
            maximumBytes: 128 * 1_024,
            executable: false
        )
        try verifyArtifact(
            paths.runtimeScriptURL,
            label: "runtime script",
            expectedSHA256: Self.runtimeScriptSHA256,
            maximumBytes: 256 * 1_024,
            executable: false
        )
        try verifyArtifact(
            paths.commonScriptURL,
            label: "shared delivery script",
            expectedSHA256: Self.commonScriptSHA256,
            maximumBytes: 64 * 1_024,
            executable: false
        )
        try verifyArtifact(
            paths.runtimeManifestURL,
            label: "runtime manifest",
            expectedSHA256: Self.runtimeManifestSHA256,
            maximumBytes: 64 * 1_024,
            executable: false
        )
        let receiptData = try readSmallArtifact(
            paths.installReceiptURL,
            label: "install receipt",
            maximumBytes: 64 * 1_024,
            privatePermissions: true
        )
        let receipt: CloudflaredInstallReceipt
        do {
            guard let object = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
                  Set(object.keys) == CloudflaredInstallReceipt.expectedKeys else {
                throw KanameLinkTunnelSupervisorFailure.receiptMismatch
            }
            receipt = try JSONDecoder().decode(CloudflaredInstallReceipt.self, from: receiptData)
        } catch let failure as KanameLinkTunnelSupervisorFailure {
            throw failure
        } catch {
            throw KanameLinkTunnelSupervisorFailure.receiptMismatch
        }

        #if arch(arm64)
        let expectedArtifactID = "darwin-arm64"
        let expectedArtifactName = "cloudflared-darwin-arm64.tgz"
        let expectedArtifactSHA256 = "b61054d3d6326ea558cb49826eebf5676e0d0a36d51b546975096ca3e0e3c89d"
        #elseif arch(x86_64)
        let expectedArtifactID = "darwin-x64"
        let expectedArtifactName = "cloudflared-darwin-amd64.tgz"
        let expectedArtifactSHA256 = "b0f770e1e0b281399a57219b840fd8eef1cc25387a404124248157ea2073727a"
        #else
        throw KanameLinkTunnelSupervisorFailure.artifactMismatch("unsupported architecture")
        #endif

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        guard receipt.schemaVersion == 1,
              receipt.component == "cloudflared",
              receipt.version == Self.cloudflaredVersion,
              receipt.manifestDigest == Self.manifestDigest,
              receipt.artifactID == expectedArtifactID,
              receipt.artifactFileName == expectedArtifactName,
              receipt.artifactSHA256 == expectedArtifactSHA256,
              receipt.binaryPath == paths.cloudflaredBinaryURL.path,
              timestampFormatter.date(from: receipt.installedAt) != nil,
              receipt.tokenPersisted == false,
              Self.isSHA256(receipt.binarySHA256) else {
            throw KanameLinkTunnelSupervisorFailure.receiptMismatch
        }
        try verifyArtifact(
            paths.cloudflaredBinaryURL,
            label: "cloudflared",
            expectedSHA256: receipt.binarySHA256,
            maximumBytes: 256 * 1_024 * 1_024,
            executable: true
        )
    }

    private func verifyArtifact(
        _ url: URL,
        label: String,
        expectedSHA256: String,
        maximumBytes: Int,
        executable: Bool
    ) throws {
        try requireRegularCanonicalFile(
            url,
            label: label,
            maximumBytes: maximumBytes,
            executable: executable
        )
        let digest: String
        do {
            digest = try Self.sha256OfFile(at: url, maximumBytes: maximumBytes)
        } catch let failure as KanameLinkTunnelSupervisorFailure {
            throw failure
        } catch {
            throw KanameLinkTunnelSupervisorFailure.artifactUnavailable(label)
        }
        guard digest == expectedSHA256 else {
            throw KanameLinkTunnelSupervisorFailure.artifactMismatch(label)
        }
    }

    private func readSmallArtifact(
        _ url: URL,
        label: String,
        maximumBytes: Int,
        privatePermissions: Bool
    ) throws -> Data {
        try requireRegularCanonicalFile(
            url,
            label: label,
            maximumBytes: maximumBytes,
            executable: false
        )
        if privatePermissions {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                throw KanameLinkTunnelSupervisorFailure.artifactMismatch(label)
            }
        }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumBytes else {
                throw KanameLinkTunnelSupervisorFailure.artifactMismatch(label)
            }
            return data
        } catch let failure as KanameLinkTunnelSupervisorFailure {
            throw failure
        } catch {
            throw KanameLinkTunnelSupervisorFailure.artifactUnavailable(label)
        }
    }

    private func requireRegularCanonicalFile(
        _ url: URL,
        label: String,
        maximumBytes: Int,
        executable: Bool
    ) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
        } catch {
            throw KanameLinkTunnelSupervisorFailure.artifactUnavailable(label)
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw KanameLinkTunnelSupervisorFailure.artifactUnavailable(label)
        }
        guard url.resolvingSymlinksInPath().path == url.path,
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumBytes,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0,
              let referenceCount = attributes[.referenceCount] as? NSNumber,
              referenceCount.intValue == 1,
              !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
            throw KanameLinkTunnelSupervisorFailure.artifactMismatch(label)
        }
    }

    private static func sha256OfFile(at url: URL, maximumBytes: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var totalBytes = 0
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
            totalBytes += data.count
            guard totalBytes <= maximumBytes else {
                throw KanameLinkTunnelSupervisorFailure.artifactMismatch(url.lastPathComponent)
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
    }
}

private struct CloudflaredInstallReceipt: Decodable {
    let schemaVersion: Int
    let component: String
    let version: String
    let manifestDigest: String
    let artifactID: String
    let artifactFileName: String
    let artifactSHA256: String
    let binaryPath: String
    let binarySHA256: String
    let installedAt: String
    let tokenPersisted: Bool

    static let expectedKeys: Set<String> = [
        "schemaVersion",
        "component",
        "version",
        "manifestDigest",
        "artifactId",
        "artifactFileName",
        "artifactSHA256",
        "binaryPath",
        "binarySHA256",
        "installedAt",
        "tokenPersisted",
    ]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case component
        case version
        case manifestDigest
        case artifactID = "artifactId"
        case artifactFileName
        case artifactSHA256
        case binaryPath
        case binarySHA256
        case installedAt
        case tokenPersisted
    }
}

public struct KanameLinkTunnelSupervisorLaunchRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
}

public protocol KanameLinkTunnelRunningSupervisor: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
}

public protocol KanameLinkTunnelSupervisorProcessLaunching: Sendable {
    func launch(
        request: KanameLinkTunnelSupervisorLaunchRequest,
        token: KanameLinkTunnelToken
    ) throws -> any KanameLinkTunnelRunningSupervisor
}

public struct FoundationKanameLinkTunnelSupervisorProcessLauncher:
    KanameLinkTunnelSupervisorProcessLaunching, Sendable
{
    public init() {}

    public func launch(
        request: KanameLinkTunnelSupervisorLaunchRequest,
        token: KanameLinkTunnelToken
    ) throws -> any KanameLinkTunnelRunningSupervisor {
        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            throw KanameLinkTunnelSupervisorFailure.processLaunchFailed
        }

        do {
            try token.withData { data in
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try inputPipe.fileHandleForWriting.close()
        } catch {
            process.terminate()
            try? inputPipe.fileHandleForWriting.close()
            throw KanameLinkTunnelSupervisorFailure.tokenPipeWriteFailed
        }
        return FoundationKanameLinkTunnelRunningSupervisor(process: process)
    }
}

private final class FoundationKanameLinkTunnelRunningSupervisor:
    KanameLinkTunnelRunningSupervisor, @unchecked Sendable
{
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    func terminate() { process.terminate() }
}

public actor KanameLinkTunnelSupervisorLauncher {
    private let paths: KanameLinkTunnelSupervisorPaths
    private let credentialStore: any KanameLinkTunnelCredentialStoring
    private let artifactVerifier: any KanameLinkTunnelArtifactVerifying
    private let processLauncher: any KanameLinkTunnelSupervisorProcessLaunching
    private var runningSupervisor: (any KanameLinkTunnelRunningSupervisor)?

    public init(
        paths: KanameLinkTunnelSupervisorPaths,
        credentialStore: any KanameLinkTunnelCredentialStoring,
        artifactVerifier: any KanameLinkTunnelArtifactVerifying =
            FileSystemKanameLinkTunnelArtifactVerifier(),
        processLauncher: any KanameLinkTunnelSupervisorProcessLaunching =
            FoundationKanameLinkTunnelSupervisorProcessLauncher()
    ) {
        self.paths = paths
        self.credentialStore = credentialStore
        self.artifactVerifier = artifactVerifier
        self.processLauncher = processLauncher
    }

    @discardableResult
    public func launch() throws -> Int32 {
        if let runningSupervisor, runningSupervisor.isRunning {
            throw KanameLinkTunnelSupervisorFailure.alreadyRunning
        }
        try artifactVerifier.verify(paths)
        let token = try credentialStore.loadToken()
        let process = try processLauncher.launch(
            request: paths.launchRequest(),
            token: token
        )
        runningSupervisor = process
        return process.processIdentifier
    }

    public func stop() {
        runningSupervisor?.terminate()
        runningSupervisor = nil
    }

    /// Deletes only the fixed local Keychain item. It does not invoke a
    /// Cloudflare rotation API and is never part of automatic shutdown.
    public func deleteLocalCredential() throws {
        try credentialStore.deleteToken()
    }
}
#endif
