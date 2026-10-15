import Foundation

public struct ClockSample {
    public let wallUnixMilliseconds: Double
    public let instant: ContinuousClock.Instant
    public init(wallUnixMilliseconds: Double, instant: ContinuousClock.Instant) {
        self.wallUnixMilliseconds = wallUnixMilliseconds
        self.instant = instant
    }
}

public struct DiagnosticReply {
    public let requestID: UInt64
    public let payload: Data
    public let expiresAt: ContinuousClock.Instant
}

public enum DiagnosticDisposition {
    case reply(DiagnosticReply), silent, close
}

public enum CloseReason: String {
    case invalidInput, busy, duplicateID, deadline, peer, session, power, lifetime, io, shutdown
}

public final class DiagnosticSession {
    private var pendingRequestID: UInt64?
    public init() {}

    public func receive(_ payload: Data, clock: ClockSample) -> DiagnosticDisposition {
        guard pendingRequestID == nil, clock.wallUnixMilliseconds.isFinite,
              case let .object(root)? = try? BoundedJSON.decode(payload) else { return .close }
        var requestID: UInt64?
        if let field = root["id"] {
            guard case let .number(token) = field, !token.isEmpty,
                  token.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = UInt64(token), parsed <= 9_007_199_254_740_991 else { return .close }
            requestID = parsed
        }
        func respond(error code: Int?, seconds: Double = 5) -> DiagnosticDisposition {
            guard let requestID else { return code == nil ? .silent : .close }
            var result: [String: Any] = ["jsonrpc": "2.0", "id": requestID]
            if let code {
                let messages = [-10011: "No active diagnostic session permits operations", -10013: "Incompatible API version", -32600: "Invalid request", -32601: "Method not found"]
                result["error"] = ["code": code, "message": messages[code] ?? "Request denied"]
            } else {
                result["result"] = ["serverApiVersion": "CodexComputerUseIPC-5"]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return .close }
            pendingRequestID = requestID
            return .reply(DiagnosticReply(requestID: requestID, payload: data, expiresAt: clock.instant.advanced(by: .seconds(seconds))))
        }
        guard root["jsonrpc"] == .string("2.0"), case let .string(method)? = root["method"],
              !method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case let .object(params)? = root["params"] else { return respond(error: -32600) }
        guard method == "ping" || method == "request" else {
            return requestID == nil ? .silent : respond(error: -32601)
        }
        guard case let .string(version)? = params["clientApiVersion"] else { return respond(error: -32600) }
        guard version == "CodexComputerUseIPC-5" else { return respond(error: -10013) }
        if method == "ping" { return respond(error: nil) }
        guard case let .string(requestType)? = params["requestType"], !requestType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              case .object? = params["request"], case let .number(token)? = params["deadlineUnixMilliseconds"],
              let deadline = Double(token), deadline.isFinite, deadline > clock.wallUnixMilliseconds else { return respond(error: -32600) }
        if requestID == nil { return .silent }
        return respond(error: -10011, seconds: min(5, (deadline - clock.wallUnixMilliseconds) / 1000))
    }

    public func didSendReply(requestID: UInt64) throws {
        guard pendingRequestID == requestID else { throw ProtocolFailure(.invalidEnvelope) }
        pendingRequestID = nil
    }
}
