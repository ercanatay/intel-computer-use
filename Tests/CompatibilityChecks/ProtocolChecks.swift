import CompatibilityProtocol
import Foundation

let pingPayload = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"clientApiVersion":"CodexComputerUseIPC-5"}}"#.utf8)

func responseObject(_ disposition: DiagnosticDisposition) throws -> [String: Any] {
    guard case let .reply(reply) = disposition,
          let object = try JSONSerialization.jsonObject(with: reply.payload) as? [String: Any] else {
        throw CheckFailure(message: "Expected diagnostic reply")
    }
    return object
}

func isClosed(_ disposition: DiagnosticDisposition) -> Bool {
    if case .close = disposition { return true }
    return false
}

func runProtocolChecks() throws {
    let instant = ContinuousClock.now
    let clock = ClockSample(wallUnixMilliseconds: 1_000_000, instant: instant)
    let session = DiagnosticSession()
    let response = try responseObject(session.receive(pingPayload, clock: clock))
    try expect(response["jsonrpc"] as? String == "2.0", "Response protocol")
    try expect((response["result"] as? [String: String]) == ["serverApiVersion": "CodexComputerUseIPC-5"], "Version only")
    try expect(isClosed(session.receive(pingPayload, clock: clock)), "Duplicate pending ID rejected")
    try session.didSendReply(requestID: 1)
    try expect(!isClosed(session.receive(pingPayload, clock: clock)), "Sequential ID reuse has no authority")
    let requestTypes = ["ComputerUseIPCAppPolicyRequest", "ComputerUseIPCListAppsRequest", "ComputerUseIPCAppGetSkyshotRequest", "ComputerUseIPCAppPerformActionRequest", "ComputerUseIPCAppStartRequest", "ComputerUseIPCStartAudioRecordingRequest", "ComputerUseIPCStopAudioRecordingRequest"]
    for requestType in requestTypes {
        for metadata: Any in [NSNull(), ["session_id": "synthetic", "turn_id": "synthetic", "trusted": true], ["turn_id": "stale"], "not-authority"] {
            let body: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "request", "params": ["clientApiVersion": "CodexComputerUseIPC-5", "requestType": requestType, "request": [:], "deadlineUnixMilliseconds": 1_120_000, "codexTurnMetadata": metadata]]
            let payload = try JSONSerialization.data(withJSONObject: body)
            let disposition = DiagnosticSession().receive(payload, clock: clock)
            let result = try responseObject(disposition)
            try expect((result["error"] as? [String: Any])?["code"] as? Int == -10011 && result["result"] == nil, "Operations always denied")
            if case let .reply(reply) = disposition {
                try expect(reply.expiresAt == instant.advanced(by: .seconds(5)), "Monotonic budget clamped")
            }
        }
    }
    for token in ["true", "null", "-1", "1.1", "1e0", "9007199254740992", "1.00000000000000000001"] {
        let payload = Data(String(decoding: pingPayload, as: UTF8.self).replacingOccurrences(of: "\"id\":1", with: "\"id\":" + token).utf8)
        try expect(isClosed(DiagnosticSession().receive(payload, clock: clock)), "Invalid ID never coerces")
    }
    for token in ["0", "9007199254740991"] {
        let payload = Data(String(decoding: pingPayload, as: UTF8.self).replacingOccurrences(of: "\"id\":1", with: "\"id\":" + token).utf8)
        let result = try responseObject(DiagnosticSession().receive(payload, clock: clock))
        try expect((result["id"] as? NSNumber)?.uint64Value == UInt64(token), "Exact safe integer ID")
    }
    for malformed in [#"{"id":1,"\u0069d":2}"#, #"{"value":01}"#, #"{"value":NaN}"#, #"{"value":"\uD800"}"#, #"{"value":"\q"}"#, "{} {}", "[1,]", "{", "truex"] {
        try expectFailure { _ = try BoundedJSON.decode(Data(malformed.utf8)) }
    }
    try expectFailure { _ = try BoundedJSON.decode(Data([0x22, 0xff, 0x22])) }
    _ = try BoundedJSON.decode(Data((String(repeating: "[", count: 32) + "null" + String(repeating: "]", count: 32)).utf8))
    try expectFailure { _ = try BoundedJSON.decode(Data((String(repeating: "[", count: 33) + "null" + String(repeating: "]", count: 33)).utf8)) }
    _ = try BoundedJSON.decode(Data(("[" + Array(repeating: "null", count: 16_383).joined(separator: ",") + "]").utf8))
    try expectFailure { _ = try BoundedJSON.decode(Data(("[" + Array(repeating: "null", count: 16_384).joined(separator: ",") + "]").utf8)) }
    try expect(try BoundedJSON.decode(Data(#"{"brackets":"[{}]","unicode":"\u00fc"}"#.utf8)) == .object(["brackets": .string("[{}]"), "unicode": .string("ü")]), "Quoted structure and Unicode")
    let cases: [(String, Int)] = [("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknown\",\"params\":{}}", -32601), (String(decoding: pingPayload, as: UTF8.self).replacingOccurrences(of: "IPC-5", with: "IPC-6"), -10013), (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":null}"#, -32600)]
    for (payload, code) in cases {
        let result = try responseObject(DiagnosticSession().receive(Data(payload.utf8), clock: clock))
        try expect((result["error"] as? [String: Any])?["code"] as? Int == code, "Deterministic protocol failure")
    }
    for deadline in ["999999", "1000000", "1e400"] {
        let payload = Data((#"{"jsonrpc":"2.0","id":1,"method":"request","params":{"clientApiVersion":"CodexComputerUseIPC-5","requestType":"request","request":{},"deadlineUnixMilliseconds":"# + deadline + "}}").utf8)
        let result = try responseObject(DiagnosticSession().receive(payload, clock: clock))
        try expect((result["error"] as? [String: Any])?["code"] as? Int == -32600, "Invalid deadline denied")
    }
    let notification = Data(#"{"jsonrpc":"2.0","method":"ping","params":{"clientApiVersion":"CodexComputerUseIPC-5"}}"#.utf8)
    if case .silent = DiagnosticSession().receive(notification, clock: clock) { compatibilityCheckCount += 1 }
    else { throw CheckFailure(message: "Notification must remain silent") }
    try expect(isClosed(DiagnosticSession().receive(Data("[]".utf8), clock: clock)), "Batches rejected")
    if case let .reply(reply) = DiagnosticSession().receive(pingPayload, clock: clock) {
        let laterWallClock = ClockSample(wallUnixMilliseconds: -1e15, instant: instant.advanced(by: .seconds(5)))
        try expect(reply.expiresAt <= laterWallClock.instant, "Wall-clock jump cannot extend reply")
    }
}
