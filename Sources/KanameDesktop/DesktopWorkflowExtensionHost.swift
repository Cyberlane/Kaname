import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct DesktopWorkflowQualificationArtifactFixture: Codable, Equatable, Sendable {
    public var role: String
    public var path: String
    public var filename: String
    public var mediaType: String
}

public struct DesktopWorkflowQualificationExpectation: Codable, Equatable, Sendable {
    public var outputPath: String?
    public var outputSHA256: String?
    public var artifactSHA256: [String: String]
    public var expectFailure: Bool
}

public struct DesktopWorkflowQualificationCase: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var inputPath: String
    public var artifacts: [DesktopWorkflowQualificationArtifactFixture]
    public var statePath: String?
    public var contextPath: String?
    public var expectation: DesktopWorkflowQualificationExpectation
}

public struct DesktopWorkflowQualificationSuite: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var componentID: String
    public var componentVersion: String
    public var cases: [DesktopWorkflowQualificationCase]
}

public enum DesktopWorkflowQualificationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSuite(String)
    case fixtureUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSuite(detail): "The qualification suite is invalid: \(detail)"
        case let .fixtureUnavailable(path): "The qualification fixture is unavailable: \(path)"
        }
    }
}

public struct DesktopWorkflowCapabilityQualifier: Sendable {
    public let runner: DesktopWorkflowCapabilityProcessRunner

    public init(runner: DesktopWorkflowCapabilityProcessRunner = .init()) {
        self.runner = runner
    }

    public func run(
        suiteURL: URL,
        installation: DesktopWorkflowCapabilityInstallationRecord,
        capabilityStore: DesktopWorkflowCapabilityStore,
        scratchRoot: URL,
        now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws -> [DesktopWorkflowQualificationRunRecord] {
        let suiteRoot = suiteURL.standardizedFileURL
        let suiteData = try boundedData(at: suiteRoot.appendingPathComponent("qualification.json"), maximumBytes: 256 * 1_024)
        let suite: DesktopWorkflowQualificationSuite
        do { suite = try JSONDecoder().decode(DesktopWorkflowQualificationSuite.self, from: suiteData) }
        catch { throw DesktopWorkflowQualificationError.invalidSuite("qualification.json could not be decoded") }
        guard suite.schemaVersion == 1,
              suite.componentID == installation.capabilityID,
              suite.componentVersion == installation.version,
              !suite.cases.isEmpty, suite.cases.count <= 1_000,
              Set(suite.cases.map(\.id)).count == suite.cases.count else {
            throw DesktopWorkflowQualificationError.invalidSuite("the component identity or case list does not match the installation")
        }
        let manifest = try capabilityStore.manifest(for: installation)
        let installationDirectory = capabilityStore.installationDirectory(
            capabilityID: installation.capabilityID, version: installation.version
        )
        return try suite.cases.map { testCase in
            try runCase(
                testCase, suiteRoot: suiteRoot, suite: suite, manifest: manifest,
                installationDirectory: installationDirectory, scratchRoot: scratchRoot, now: now
            )
        }
    }

    private func runCase(
        _ testCase: DesktopWorkflowQualificationCase,
        suiteRoot: URL,
        suite: DesktopWorkflowQualificationSuite,
        manifest: DesktopWorkflowCapabilityManifest,
        installationDirectory: URL,
        scratchRoot: URL,
        now: () -> Int64
    ) throws -> DesktopWorkflowQualificationRunRecord {
        guard validIdentifier(testCase.id), !testCase.name.isEmpty,
              safePath(testCase.inputPath), testCase.artifacts.count <= 50,
              testCase.artifacts.allSatisfy({ validIdentifier($0.role) && safePath($0.path) }),
              testCase.statePath.map(safePath) ?? true,
              testCase.contextPath.map(safePath) ?? true,
              testCase.expectation.outputPath.map(safePath) ?? true else {
            throw DesktopWorkflowQualificationError.invalidSuite("case \(testCase.id) has unsafe paths or identifiers")
        }
        let input = try boundedData(at: contained(testCase.inputPath, beneath: suiteRoot), maximumBytes: manifest.limits.maximumInputBytes)
        let artifacts = try testCase.artifacts.map { fixture -> DesktopWorkflowCapabilityArtifactInput in
            let data = try boundedData(
                at: contained(fixture.path, beneath: suiteRoot),
                maximumBytes: manifest.limits.maximumArtifactBytes
            )
            return DesktopWorkflowCapabilityArtifactInput(
                role: fixture.role, artifactDigest: DesktopWorkflowStructuredValue.digest(data),
                filename: fixture.filename, mediaType: fixture.mediaType, data: data
            )
        }
        let state: [DesktopWorkflowCapabilityStateInput]
        if let path = testCase.statePath {
            let data = try boundedData(at: contained(path, beneath: suiteRoot), maximumBytes: 8 * 1_024 * 1_024)
            do { state = try JSONDecoder().decode([DesktopWorkflowCapabilityStateInput].self, from: data) }
            catch { throw DesktopWorkflowQualificationError.invalidSuite("case \(testCase.id) state is invalid") }
        } else { state = [] }
        let context: DesktopWorkflowContextSnapshotRecord?
        if let path = testCase.contextPath {
            let data = try boundedData(at: contained(path, beneath: suiteRoot), maximumBytes: 8 * 1_024 * 1_024)
            do { context = try JSONDecoder().decode(DesktopWorkflowContextSnapshotRecord.self, from: data) }
            catch { throw DesktopWorkflowQualificationError.invalidSuite("case \(testCase.id) context is invalid") }
        } else { context = nil }
        let started = now()
        do {
            let result = try runner.execute(
                manifest: manifest, installationDirectory: installationDirectory, input: input,
                artifactInputs: artifacts, stateInputs: state, contextSnapshot: context,
                scratchRoot: scratchRoot
            )
            var assertions: [DesktopWorkflowQualificationAssertionRecord] = []
            assertions.append(.init(
                id: "execution", label: "Execution", passed: !testCase.expectation.expectFailure,
                detail: testCase.expectation.expectFailure ? "Expected this fixture to fail, but it succeeded." : "The isolated component completed."
            ))
            if let outputPath = testCase.expectation.outputPath {
                let expected = try boundedData(
                    at: contained(outputPath, beneath: suiteRoot), maximumBytes: manifest.limits.maximumOutputBytes
                )
                assertions.append(.init(
                    id: "output-bytes", label: "Structured output", passed: expected == result.output,
                    detail: expected == result.output ? "Output matched the reviewed fixture." : "Output bytes differ from the fixture."
                ))
            }
            if let digest = testCase.expectation.outputSHA256 {
                assertions.append(.init(
                    id: "output-digest", label: "Output digest", passed: digest == result.outputDigest,
                    detail: digest == result.outputDigest ? "Output digest matched." : "Expected \(digest); received \(result.outputDigest)."
                ))
            }
            let artifactsByPath = Dictionary(uniqueKeysWithValues: result.artifacts.map { ($0.relativePath, $0.sha256) })
            for (path, digest) in testCase.expectation.artifactSHA256.sorted(by: { $0.key < $1.key }) {
                let actual = artifactsByPath[path]
                assertions.append(.init(
                    id: "artifact-\(DesktopWorkflowStructuredValue.digest(Data(path.utf8)).prefix(12))",
                    label: "Artifact \(path)", passed: actual == digest,
                    detail: actual == digest ? "Artifact digest matched." : "Expected \(digest); received \(actual ?? "no artifact")."
                ))
            }
            return qualificationRun(
                suite: suite, testCase: testCase, artifacts: artifacts, state: state, context: context,
                result: result, assertions: assertions, started: started, finished: now()
            )
        } catch {
            let passed = testCase.expectation.expectFailure
            return DesktopWorkflowQualificationRunRecord(
                id: UUID().uuidString.lowercased(), componentID: suite.componentID,
                componentVersion: suite.componentVersion, fixtureName: testCase.name,
                artifactDigests: artifacts.map(\.artifactDigest),
                stateDigest: state.isEmpty ? nil : digest(state), contextDigest: context?.digest,
                outputDigest: nil, outputArtifactDigests: [],
                assertions: [.init(
                    id: "execution", label: "Expected failure", passed: passed,
                    detail: passed ? "The negative fixture failed closed as expected." : String(error.localizedDescription.prefix(2_048))
                )], outcome: passed ? .passed : .failed,
                elapsedMilliseconds: max(0, now() - started), executedAtUnixMillis: now()
            )
        }
    }

    private func qualificationRun(
        suite: DesktopWorkflowQualificationSuite,
        testCase: DesktopWorkflowQualificationCase,
        artifacts: [DesktopWorkflowCapabilityArtifactInput],
        state: [DesktopWorkflowCapabilityStateInput],
        context: DesktopWorkflowContextSnapshotRecord?,
        result: DesktopWorkflowCapabilityExecutionResult,
        assertions: [DesktopWorkflowQualificationAssertionRecord],
        started: Int64,
        finished: Int64
    ) -> DesktopWorkflowQualificationRunRecord {
        let passed = assertions.allSatisfy(\.passed)
        return DesktopWorkflowQualificationRunRecord(
            id: UUID().uuidString.lowercased(), componentID: suite.componentID,
            componentVersion: suite.componentVersion, fixtureName: testCase.name,
            artifactDigests: artifacts.map(\.artifactDigest),
            stateDigest: state.isEmpty ? nil : digest(state), contextDigest: context?.digest,
            outputDigest: result.outputDigest, outputArtifactDigests: result.artifacts.map(\.sha256),
            assertions: assertions, outcome: passed ? .passed : .failed,
            elapsedMilliseconds: max(result.elapsedMilliseconds, finished - started), executedAtUnixMillis: finished
        )
    }

    private func digest<T: Encodable>(_ value: T) -> String? {
        (try? DesktopWorkflowCanonicalJSON.encode(value)).map(DesktopWorkflowStructuredValue.digest)
    }

    private func contained(_ path: String, beneath root: URL) throws -> URL {
        guard safePath(path) else { throw DesktopWorkflowQualificationError.fixtureUnavailable(path) }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw DesktopWorkflowQualificationError.fixtureUnavailable(path)
        }
        return candidate
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        do {
            return try DesktopWorkflowFilesystem.requiredBoundedRegularData(
                at: url, maximumBytes: maximumBytes, requiresNonEmpty: true,
                failure: DesktopWorkflowQualificationError.fixtureUnavailable(url.lastPathComponent)
            )
        } catch let error as DesktopWorkflowQualificationError { throw error }
        catch { throw DesktopWorkflowQualificationError.fixtureUnavailable(url.lastPathComponent) }
    }

    private func safePath(_ value: String) -> Bool {
        DesktopWorkflowCapabilityPackageCodec.safeRelativePath(value)
    }

    private func validIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }
}

private enum DesktopWorkflowExtensionManifestLoader {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        filename: String,
        from installationDirectory: URL
    ) throws -> Value {
        let url = installationDirectory.appendingPathComponent(filename).standardizedFileURL
        guard url.deletingLastPathComponent() == installationDirectory.standardizedFileURL else {
            throw DesktopWorkflowOperationalError.componentUnavailable
        }
        let data = try DesktopWorkflowFilesystem.requiredBoundedRegularData(
            at: url, maximumBytes: 256 * 1_024, requiresNonEmpty: true,
            failure: DesktopWorkflowOperationalError.componentUnavailable
        )
        return try JSONDecoder().decode(type, from: data)
    }
}

public struct DesktopWorkflowRendererManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var rendererID: String
    public var capabilityID: String
    public var version: String
    public var name: String
    public var mediaTypes: [String]
    public var supportsRecalculation: Bool
    public var supportsRangeSelection: Bool
}

public struct DesktopWorkflowRenderRequest: Codable, Equatable, Sendable {
    public var operation: String
    public var sourceRole: String
    public var sourceArtifactDigest: String
    public var mediaType: String
    public var recalculate: Bool
    public var selections: [String]
}

public struct DesktopWorkflowRenderFinding: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var passed: Bool
    public var detail: String
}

public struct DesktopWorkflowRenderOutput: Codable, Equatable, Sendable {
    public var recalculated: Bool
    public var selections: [String]
    public var findings: [DesktopWorkflowRenderFinding]
}

public struct DesktopWorkflowRendererAdapter: Sendable {
    public let manifest: DesktopWorkflowRendererManifest
    public let capabilityManifest: DesktopWorkflowCapabilityManifest
    public let installationDirectory: URL
    public let scratchRoot: URL
    public let runner: DesktopWorkflowCapabilityProcessRunner

    public init(
        manifest: DesktopWorkflowRendererManifest,
        capabilityManifest: DesktopWorkflowCapabilityManifest,
        installationDirectory: URL,
        scratchRoot: URL,
        runner: DesktopWorkflowCapabilityProcessRunner = .init()
    ) throws {
        guard manifest.schemaVersion == 1, manifest.rendererID == capabilityManifest.id,
              manifest.capabilityID == capabilityManifest.id, manifest.version == capabilityManifest.version,
              !manifest.name.isEmpty, !manifest.mediaTypes.isEmpty else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("renderer metadata does not match its capability")
        }
        self.manifest = manifest
        self.capabilityManifest = capabilityManifest
        self.installationDirectory = installationDirectory
        self.scratchRoot = scratchRoot
        self.runner = runner
    }

    public static func loadManifest(from installationDirectory: URL) throws -> DesktopWorkflowRendererManifest {
        try DesktopWorkflowExtensionManifestLoader.decode(
            DesktopWorkflowRendererManifest.self, filename: "renderer.json", from: installationDirectory
        )
    }

    public func render(
        artifact: DesktopWorkflowCapabilityArtifactInput,
        mediaType: String,
        recalculate: Bool,
        selections: [String]
    ) throws -> (output: DesktopWorkflowRenderOutput, artifacts: [DesktopWorkflowCapabilityArtifact], elapsedMilliseconds: Int64) {
        guard manifest.mediaTypes.contains(mediaType), !recalculate || manifest.supportsRecalculation,
              (selections.isEmpty || manifest.supportsRangeSelection), selections.count <= 256 else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("the renderer does not support this request")
        }
        let request = DesktopWorkflowRenderRequest(
            operation: "render", sourceRole: artifact.role, sourceArtifactDigest: artifact.artifactDigest,
            mediaType: mediaType, recalculate: recalculate,
            selections: selections.map { String($0.prefix(512)) }
        )
        let result = try runner.execute(
            manifest: capabilityManifest, installationDirectory: installationDirectory,
            input: try DesktopWorkflowCanonicalJSON.encode(request), artifactInputs: [artifact],
            scratchRoot: scratchRoot
        )
        let output = try JSONDecoder().decode(DesktopWorkflowRenderOutput.self, from: result.output)
        guard output.recalculated == recalculate, output.selections == request.selections,
              output.findings.count <= 1_000 else { throw DesktopWorkflowCapabilityError.outputInvalid }
        return (output, result.artifacts, result.elapsedMilliseconds)
    }
}

public protocol DesktopWorkflowSecretResolving: Sendable {
    func secret(reference: String) throws -> Data
}

#if canImport(Security)
public struct DesktopWorkflowKeychainSecretResolver: DesktopWorkflowSecretResolving {
    public var service: String

    public init(service: String = "com.cyberlane.kaname.workflow-connector") {
        self.service = service
    }

    public func secret(reference: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty, data.count <= 64 * 1_024 else {
            throw DesktopWorkflowOperationalError.componentUnavailable
        }
        return data
    }
}
#endif

public struct DesktopWorkflowConnectorPackageManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var connectorID: String
    public var capabilityID: String
    public var version: String
    public var name: String
    public var effectKinds: [String]
    public var allowedHosts: [String]
    public var secretSlots: [String]
    public var maximumHTTPCalls: Int
    public var maximumResponseBytes: Int
}

public struct DesktopWorkflowConnectorHTTPCommand: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var secretHeaders: [String: String]
    public var bodyBase64: String?
}

public struct DesktopWorkflowConnectorHTTPResponse: Codable, Equatable, Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var bodyBase64: String
}

public enum DesktopWorkflowConnectorProgramCommandKind: String, Codable, Equatable, Sendable {
    case preview
    case http
    case completed
}

public struct DesktopWorkflowConnectorProgramCommand: Codable, Equatable, Sendable {
    public var kind: DesktopWorkflowConnectorProgramCommandKind
    public var preview: DesktopWorkflowEffectPreview?
    public var http: DesktopWorkflowConnectorHTTPCommand?
    public var receipt: DesktopWorkflowConnectorExecutionReceipt?
}

public struct DesktopWorkflowConnectorProgramInput: Codable, Equatable, Sendable {
    public var operation: String
    public var request: DesktopWorkflowEffectRequest
    public var preview: DesktopWorkflowEffectPreview?
    public var idempotencyKey: String?
    public var responses: [DesktopWorkflowConnectorHTTPResponse]
    public var priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
}

public final class DesktopWorkflowProcessConnector: DesktopWorkflowConnector, @unchecked Sendable {
    public let identifier: String
    private let package: DesktopWorkflowConnectorPackageManifest
    private let capability: DesktopWorkflowCapabilityManifest
    private let installationDirectory: URL
    private let scratchRoot: URL
    private let binding: DesktopWorkflowConnectorBindingRecord
    private let secretResolver: any DesktopWorkflowSecretResolving
    private let runner: DesktopWorkflowCapabilityProcessRunner

    public init(
        package: DesktopWorkflowConnectorPackageManifest,
        capability: DesktopWorkflowCapabilityManifest,
        installationDirectory: URL,
        scratchRoot: URL,
        binding: DesktopWorkflowConnectorBindingRecord,
        secretResolver: any DesktopWorkflowSecretResolving,
        runner: DesktopWorkflowCapabilityProcessRunner = .init()
    ) throws {
        guard package.schemaVersion == 1, package.connectorID == capability.id,
              package.capabilityID == capability.id, package.version == capability.version,
              binding.connectorID == package.connectorID, binding.enabled,
              Set(binding.grantedHosts).isSubset(of: Set(package.allowedHosts)),
              Set(binding.grantedEffectKinds).isSubset(of: Set(package.effectKinds)),
              Set(binding.secretReferences.keys).isSubset(of: Set(package.secretSlots)),
              (1...16).contains(package.maximumHTTPCalls),
              (1...16 * 1_024 * 1_024).contains(package.maximumResponseBytes) else {
            throw DesktopWorkflowOperationalError.invalidConfiguration("connector metadata or binding is invalid")
        }
        identifier = package.connectorID
        self.package = package
        self.capability = capability
        self.installationDirectory = installationDirectory
        self.scratchRoot = scratchRoot
        self.binding = binding
        self.secretResolver = secretResolver
        self.runner = runner
    }

    public static func loadPackageManifest(from installationDirectory: URL) throws -> DesktopWorkflowConnectorPackageManifest {
        try DesktopWorkflowExtensionManifestLoader.decode(
            DesktopWorkflowConnectorPackageManifest.self,
            filename: "connector.json", from: installationDirectory
        )
    }

    public func preview(_ request: DesktopWorkflowEffectRequest) async throws -> DesktopWorkflowEffectPreview {
        try validate(request)
        let command = try invoke(.init(
            operation: "preview", request: request, preview: nil, idempotencyKey: nil,
            responses: [], priorReceipt: nil
        ))
        guard command.kind == .preview, let preview = command.preview,
              command.http == nil, command.receipt == nil else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        return preview
    }

    public func execute(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        try await perform(
            operation: "execute", request: request, preview: preview,
            idempotencyKey: idempotencyKey, priorReceipt: nil
        )
    }

    public func reconcile(
        _ request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String,
        priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        try await perform(
            operation: "reconcile", request: request, preview: preview,
            idempotencyKey: idempotencyKey, priorReceipt: priorReceipt
        )
    }

    private func perform(
        operation: String,
        request: DesktopWorkflowEffectRequest,
        preview: DesktopWorkflowEffectPreview,
        idempotencyKey: String,
        priorReceipt: DesktopWorkflowConnectorExecutionReceipt?
    ) async throws -> DesktopWorkflowConnectorExecutionReceipt {
        try validate(request)
        var input = DesktopWorkflowConnectorProgramInput(
            operation: operation, request: request, preview: preview,
            idempotencyKey: idempotencyKey, responses: [], priorReceipt: priorReceipt
        )
        for _ in 0..<package.maximumHTTPCalls + 1 {
            let command = try invoke(input)
            switch command.kind {
            case .completed:
                guard let receipt = command.receipt, command.http == nil, command.preview == nil else {
                    throw DesktopWorkflowCapabilityError.outputInvalid
                }
                return receipt
            case .http:
                guard let request = command.http, command.preview == nil, command.receipt == nil,
                      input.responses.count < package.maximumHTTPCalls else {
                    throw DesktopWorkflowCapabilityError.outputInvalid
                }
                input.responses.append(try await send(request, idempotencyKey: idempotencyKey))
            case .preview:
                throw DesktopWorkflowCapabilityError.outputInvalid
            }
        }
        throw DesktopWorkflowCapabilityError.executionFailed("The connector exceeded its reviewed HTTP-call budget.")
    }

    private func invoke(_ input: DesktopWorkflowConnectorProgramInput) throws -> DesktopWorkflowConnectorProgramCommand {
        let result = try runner.execute(
            manifest: capability, installationDirectory: installationDirectory,
            input: try DesktopWorkflowCanonicalJSON.encode(input), scratchRoot: scratchRoot
        )
        return try JSONDecoder().decode(DesktopWorkflowConnectorProgramCommand.self, from: result.output)
    }

    private func validate(_ request: DesktopWorkflowEffectRequest) throws {
        guard request.connectorID == identifier,
              binding.grantedEffectKinds.contains(request.effectKind),
              binding.accountID == nil || binding.accountID == request.accountID else {
            throw DesktopWorkflowHostFrameworkError.authorityUnavailable
        }
    }

    private func send(
        _ command: DesktopWorkflowConnectorHTTPCommand,
        idempotencyKey: String
    ) async throws -> DesktopWorkflowConnectorHTTPResponse {
        guard let url = URL(string: command.url), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), binding.grantedHosts.contains(host),
              ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(command.method.uppercased()),
              command.headers.count <= 64, command.secretHeaders.count <= 16 else {
            throw DesktopWorkflowHostFrameworkError.authorityUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = command.method.uppercased()
        request.timeoutInterval = TimeInterval(min(300, capability.limits.timeoutSeconds))
        for (name, value) in command.headers where validHeader(name) {
            request.setValue(String(value.prefix(8_192)), forHTTPHeaderField: name)
        }
        for (name, slot) in command.secretHeaders {
            guard validHeader(name), let reference = binding.secretReferences[slot],
                  let value = String(data: try secretResolver.secret(reference: reference), encoding: .utf8) else {
                throw DesktopWorkflowHostFrameworkError.authorityUnavailable
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        if let body = command.bodyBase64 {
            guard let data = Data(base64Encoded: body), data.count <= capability.limits.maximumInputBytes else {
                throw DesktopWorkflowCapabilityError.inputTooLarge
            }
            request.httpBody = data
        }
        let delegate = SameHostRedirectDelegate(host: host)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= package.maximumResponseBytes, let http = response as? HTTPURLResponse else {
            throw DesktopWorkflowCapabilityError.outputInvalid
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard result.count < 64 else { return }
            result[String(describing: pair.key).lowercased()] = String(String(describing: pair.value).prefix(8_192))
        }
        return DesktopWorkflowConnectorHTTPResponse(
            statusCode: http.statusCode, headers: headers, bodyBase64: data.base64EncodedString()
        )
    }

    private func validHeader(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]{1,128}$"#, options: .regularExpression) != nil
    }
}

private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https", request.url?.host?.lowercased() == host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
