@preconcurrency import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KanameDomain

private final class RunningOpenCodeServer: @unchecked Sendable {
    let process: RunningLocalProcess
    let url: URL
    private let drains: [_Concurrency.Task<Void, Never>]

    init(process: RunningLocalProcess, url: URL, outputDrain: _Concurrency.Task<Void, Never>, errorDrain: _Concurrency.Task<Void, Never>) {
        self.process = process
        self.url = url
        drains = [outputDrain, errorDrain]
    }

    func shutdown() {
        drains.forEach { $0.cancel() }
        process.standardOutput.readabilityHandler = nil
        process.standardError.readabilityHandler = nil
        process.terminate()
    }
}

private enum OpenCodeLocalServer {
    static func start(configuration: ProviderProbeConfiguration) async throws -> RunningOpenCodeServer {
        let process = try LocalProcess.start(
            executable: configuration.executable,
            arguments: ["serve", "--hostname=127.0.0.1", "--port=0"],
            workingDirectory: configuration.workingDirectory,
            environmentOverrides: ["OPENCODE_CONFIG_CONTENT": "{}"]
        )

        do {
            let url = try await waitForReadyURL(process: process, timeout: configuration.timeout)
            let outputDrain = _Concurrency.Task { [output = process.standardOutput] in
                for await _ in JSONLineStream.make(from: output) {}
            }
            let errorDrain = _Concurrency.Task { [error = process.standardError] in
                for await _ in JSONLineStream.make(from: error) {}
            }
            return RunningOpenCodeServer(
                process: process,
                url: url,
                outputDrain: outputDrain,
                errorDrain: errorDrain
            )
        } catch {
            process.terminate()
            throw error
        }
    }

    private static func waitForReadyURL(process: RunningLocalProcess, timeout: Duration) async throws -> URL {
        try await LocalProcessRace.first(
            timeout: timeout,
            timeoutMessage: "Timed out waiting for OpenCode to start its local server.",
            onTimeout: { process.terminate() },
            operation: {
                for await data in JSONLineStream.make(from: process.standardOutput) {
                    let line = String(decoding: data, as: UTF8.self)
                    if let url = Self.readyURL(in: line) {
                        return url
                    }
                }
                process.waitForExit()
                throw ProviderConnectivityError.processExited(
                    command: "opencode serve",
                    status: process.process.terminationStatus,
                    detail: "OpenCode exited before reporting its local endpoint."
                )
            }
        )
    }

    private static func readyURL(in line: String) -> URL? {
        guard line.hasPrefix("opencode server listening") else { return nil }
        guard let range = line.range(of: #"https?://[^\s]+"#, options: .regularExpression) else { return nil }
        return URL(string: String(line[range]))
    }
}

enum OpenCodeCapabilityProbe {
    static func probe(_ configuration: ProviderProbeConfiguration) async throws -> ProviderCapabilitySnapshot {
        if let externalURL = configuration.openCode.serverURL {
            return try await snapshot(
                instance: configuration.instance,
                baseURL: try validServerURL(externalURL),
                password: configuration.openCode.serverPassword,
                timeout: configuration.timeout,
                workingDirectory: configuration.workingDirectory,
                version: nil,
                connectionDetail: "Connected to the configured OpenCode server."
            )
        }

        let version = try await localVersion(configuration)
        let server = try await OpenCodeLocalServer.start(configuration: configuration)
        do {
            let result = try await snapshot(
                instance: configuration.instance,
                baseURL: server.url,
                password: nil,
                timeout: configuration.timeout,
                workingDirectory: configuration.workingDirectory,
                version: version,
                connectionDetail: "Connected to a temporary local OpenCode server."
            )
            server.shutdown()
            return result
        } catch {
            server.shutdown()
            throw error
        }
    }

    private static func snapshot(
        instance: ProviderInstance,
        baseURL: URL,
        password: String?,
        timeout: Duration,
        workingDirectory: URL,
        version: String?,
        connectionDetail: String
    ) async throws -> ProviderCapabilitySnapshot {
        async let providerPayload = getJSON(path: "provider", baseURL: baseURL, password: password, timeout: timeout, workingDirectory: workingDirectory)
        async let agentPayload = getJSON(path: "agent", baseURL: baseURL, password: password, timeout: timeout, workingDirectory: workingDirectory)
        let (providers, agents) = try await (providerPayload, agentPayload)

        let inventory = parseProviderInventory(providers)
        let skills = parseAgentNames(agents)
        let authentication: ProviderAuthenticationState = inventory.connectedProviderIDs.isEmpty ? .unknown : .authenticated
        let state: ProviderConnectionState = inventory.connectedProviderIDs.isEmpty ? .degraded : .ready
        let detail = inventory.connectedProviderIDs.isEmpty
            ? "\(connectionDetail) It did not report any connected upstream providers."
            : "\(connectionDetail) \(inventory.connectedProviderIDs.count) upstream provider(s) connected."

        return ProviderCapabilitySnapshot(
            instance: instance,
            state: state,
            installed: true,
            version: version,
            authentication: authentication,
            models: inventory.models,
            skills: skills,
            detail: detail
        )
    }

    private static func getJSON(
        path: String,
        baseURL: URL,
        password: String?,
        timeout: Duration,
        workingDirectory: URL
    ) async throws -> Any {
        let requestURL = baseURL.appending(path: path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = seconds(from: timeout)
        request.setValue(encodedDirectory(workingDirectory.path()), forHTTPHeaderField: "x-opencode-directory")
        if let password {
            let value = Data("opencode:\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(value)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderConnectivityError.network("OpenCode did not return an HTTP response.")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw ProviderConnectivityError.network("OpenCode endpoint \(path) returned HTTP \(http.statusCode).")
            }
            return try JSONSerialization.jsonObject(with: data)
        } catch let error as ProviderConnectivityError {
            throw error
        } catch {
            throw ProviderConnectivityError.network("Could not reach OpenCode endpoint \(path): \(error.localizedDescription)")
        }
    }

    private static func validServerURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw ProviderConnectivityError.unsupportedConfiguration("OpenCode server URL must be an http(s) endpoint.")
        }
        return url
    }

    static func parseProviderInventory(_ payload: Any) -> (connectedProviderIDs: [String], models: [ProviderModel]) {
        let root = unwrapData(payload)
        let connected = (root["connected"] as? [String] ?? []).sorted()
        let connectedSet = Set(connected)
        let providers = (root["all"] as? [[String: Any]] ?? root["providers"] as? [[String: Any]] ?? [])
            .filter { provider in
                guard let id = provider["id"] as? String else { return false }
                return connectedSet.contains(id)
            }
        let models = providers.flatMap { provider -> [ProviderModel] in
            let providerID = provider["id"] as? String ?? "provider"
            let providerName = provider["name"] as? String ?? providerID
            let rawModels: [(String, [String: Any])]
            if let dictionary = provider["models"] as? [String: [String: Any]] {
                rawModels = dictionary.map { ($0.key, $0.value) }
            } else if let array = provider["models"] as? [[String: Any]] {
                rawModels = array.compactMap { entry in
                    guard let id = entry["id"] as? String else { return nil }
                    return (id, entry)
                }
            } else {
                rawModels = []
            }

            return rawModels.map { modelID, model in
                ProviderModel(
                    id: "\(providerID)/\(modelID)",
                    displayName: model["name"] as? String ?? "\(providerName) / \(modelID)",
                    isDefault: model["default"] as? Bool ?? false
                )
            }
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return (connected, models)
    }

    static func parseAgentNames(_ payload: Any) -> [String] {
        let root = unwrapData(payload)
        let agents = payload as? [[String: Any]] ?? root["agents"] as? [[String: Any]] ?? root["data"] as? [[String: Any]] ?? []
        return agents.compactMap { $0["name"] as? String }.sorted()
    }

    private static func unwrapData(_ payload: Any) -> [String: Any] {
        let root = payload as? [String: Any] ?? [:]
        return root["data"] as? [String: Any] ?? root
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func encodedDirectory(_ path: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static func localVersion(_ configuration: ProviderProbeConfiguration) async throws -> String? {
        let result = try await LocalProcess.capture(
            executable: configuration.executable,
            arguments: ["--version"],
            workingDirectory: configuration.workingDirectory,
            timeout: configuration.timeout
        )
        guard result.exitStatus == 0 else {
            throw ProviderConnectivityError.processExited(
                command: "\(configuration.executable) --version",
                status: result.exitStatus,
                detail: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (result.standardOutput + "\n" + result.standardError)
            .split(whereSeparator: { $0.isWhitespace })
            .first(where: { $0.range(of: #"\d+\.\d+"#, options: .regularExpression) != nil })
            .map(String.init)
    }
}
