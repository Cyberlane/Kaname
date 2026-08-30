import Foundation
import Testing
@testable import KanameConnectivity

struct PreviewMCPServerTests {
    @Test
    func toolsCallReturnsUnsupportedError() throws {
        for name in CodingPreviewMCPGrant.curatedToolAllowlist {
            let response = try request(method: "tools/call", params: ["name": name], id: 7)
            #expect(response.status == 200)
            #expect(response.body["jsonrpc"] as? String == "2.0")
            #expect(response.body["id"] as? Int == 7)
            let result = try #require(response.body["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let content = try #require(result["content"] as? [[String: Any]])
            let message = try #require(content.first?["text"] as? String)
            #expect(message == "Tool \(name) is not yet wired to the desktop preview. No action was performed.")
        }
    }

    @Test
    func existingProtocolResponsesRemainStable() throws {
        let initialized = try request(method: "initialize", id: 1)
        #expect(initialized.status == 200)
        let initializeResult = try #require(initialized.body["result"] as? [String: Any])
        #expect(initializeResult["protocolVersion"] as? String == "2024-11-05")

        let listed = try request(method: "tools/list", id: 2)
        #expect(listed.status == 200)
        let listResult = try #require(listed.body["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == CodingPreviewMCPGrant.curatedToolAllowlist)

        let unknownTool = try request(method: "tools/call", params: ["name": "not.allowlisted"], id: 3)
        #expect(unknownTool.status == 200)
        let toolError = try #require(unknownTool.body["error"] as? [String: Any])
        #expect(toolError["code"] as? Int == -32_601)
        #expect(toolError["message"] as? String == "tool not allowlisted")

        let unknownMethod = try request(method: "unknown/method", id: 4)
        #expect(unknownMethod.status == 200)
        let methodError = try #require(unknownMethod.body["error"] as? [String: Any])
        #expect(methodError["code"] as? Int == -32_601)
        #expect(methodError["message"] as? String == "method not found")
    }

    private func request(
        method: String,
        params: [String: Any]? = nil,
        id: Int
    ) throws -> (status: Int, body: [String: Any]) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { payload["params"] = params }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let headers = "POST /mcp HTTP/1.1\r\nAuthorization: Bearer test-token\r\nContent-Length: \(body.count)"
        let response = KanamePreviewMCPHTTPServer.handleHTTPRequest(
            headers: headers,
            body: body,
            bearerToken: "test-token"
        )
        let separator = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        let header = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let status = try #require(Int(header.split(separator: " ")[1]))
        let responseBody = try #require(
            JSONSerialization.jsonObject(with: response[separator.upperBound...]) as? [String: Any]
        )
        return (status, responseBody)
    }
}
