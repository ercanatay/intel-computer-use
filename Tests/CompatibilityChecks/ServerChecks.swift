import BridgeCore
import CompatibilityProtocol
import CompatibilityRuntime
import Darwin
import Foundation

func runServerChecks() throws {
    let fixture = try ServerFixture(writer: InterruptedWriter())
    try fixture.start()
    let client = try fixture.connect()
    defer { close(client) }
    let frame = try FrameCodec.encode(pingPayload)
    try sendBytes(frame.prefix(2), to: client)
    try expect(!readable(client, timeout: 50), "Partial header has no reply")
    try sendBytes(frame.dropFirst(2), to: client)
    let ping = try JSONSerialization.jsonObject(with: receivePayload(client)) as? [String: Any]
    try expect((ping?["result"] as? [String: String])?["serverApiVersion"] == "CodexComputerUseIPC-5", "Real socket ping")
    let second = try fixture.connect()
    try expectDisconnected(second)
    close(second)
    let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"request","params":{"clientApiVersion":"CodexComputerUseIPC-5","requestType":"getAppPolicy","request":{"bundleId":"com.apple.calculator"},"deadlineUnixMilliseconds":1010000,"codexTurnMetadata":"forged-secret-marker"}}"#.utf8)
    try sendBytes(try FrameCodec.encode(request), to: client)
    let denial = try JSONSerialization.jsonObject(with: receivePayload(client)) as? [String: Any]
    try expect((denial?["error"] as? [String: Any])?["code"] as? Int == -10011, "Real socket denial after ping")
    try expect(!String(decoding: try JSONSerialization.data(withJSONObject: denial!), as: UTF8.self).contains("forged-secret-marker"), "Metadata never reflected")
    try fixture.finish()
    try expectDisconnected(client)
    try expect(!FileManager.default.fileExists(atPath: fixture.runtime.socketURL.path), "Stopped endpoint removed")
    try expectFailure { try fixture.server.run { _ in } }

    for peer in [FixturePeer(wrongUser: true, fails: false), FixturePeer(wrongUser: false, fails: true)] {
        let rejected = try ServerFixture(peer: peer)
        try rejected.start()
        let descriptor = try rejected.connect()
        try expectDisconnected(descriptor)
        close(descriptor)
        try rejected.finish()
    }
    for state in [SessionState.locked, .inactive, .unknown] {
        let lifecycle = try ServerFixture(writer: BlockedWriter())
        try lifecycle.start()
        let descriptor = try lifecycle.connect()
        try sendBytes(frame, to: descriptor)
        usleep(100_000)
        lifecycle.session.change(to: state)
        try expectDisconnected(descriptor)
        close(descriptor)
        try lifecycle.finish()
    }
    let power = try ServerFixture(writer: BlockedWriter())
    try power.start()
    let powerClient = try power.connect()
    try sendBytes(frame, to: powerClient)
    usleep(100_000)
    power.session.powerEvent()
    try expectDisconnected(powerClient)
    close(powerClient)
    try power.finish()

    for partial in [false, true] {
        let timed = try ServerFixture()
        try timed.start()
        let descriptor = try timed.connect()
        if partial { try sendBytes(frame.prefix(1), to: descriptor) }
        usleep(100_000)
        timed.clock.advance(.milliseconds(4999))
        usleep(150_000)
        try expect(!readable(descriptor, timeout: 10), "4.999 second input remains open")
        if partial { try sendBytes(frame.dropFirst(1).prefix(1), to: descriptor) }
        timed.clock.advance(.milliseconds(1))
        try expectDisconnected(descriptor)
        close(descriptor)
        try timed.finish()
    }
    let pending = try ServerFixture(writer: BlockedWriter())
    try pending.start()
    let pendingClient = try pending.connect()
    try sendBytes(frame, to: pendingClient)
    usleep(100_000)
    pending.clock.advance(.milliseconds(4999))
    usleep(150_000)
    try expect(!readable(pendingClient, timeout: 10), "Pending output remains bounded at 4.999 seconds")
    pending.clock.advance(.milliseconds(1))
    try expectDisconnected(pendingClient)
    close(pendingClient)
    try pending.finish()

    let lifetime = try ServerFixture()
    try lifetime.start()
    lifetime.clock.advance(.milliseconds(299999))
    usleep(150_000)
    try expect(FileManager.default.fileExists(atPath: lifetime.runtime.socketURL.path), "299.999 second service remains open")
    lifetime.clock.advance(.milliseconds(1))
    usleep(150_000)
    try lifetime.finish()
    try expect(!FileManager.default.fileExists(atPath: lifetime.runtime.socketURL.path), "300 second lifetime closes")

    let burst = try ServerFixture(writer: BlockedWriter())
    try burst.start()
    let burstClient = try burst.connect()
    try sendBytes(frame + frame, to: burstClient)
    try expectDisconnected(burstClient)
    close(burstClient)
    try burst.finish()

    let unknown = try ServerFixture()
    unknown.session.change(to: .unknown)
    try expectFailure { try unknown.server.run { _ in throw CheckFailure(message: "Unsafe readiness") } }
    try expect(!FileManager.default.fileExists(atPath: unknown.runtime.socketURL.path), "Unsafe start has no endpoint")
    let eof = try ServerFixture()
    try eof.start()
    let eofClient = try eof.connect()
    close(eofClient)
    usleep(150_000)
    try eof.finish()
    try expect(!FileManager.default.fileExists(atPath: eof.runtime.socketURL.path), "EOF cleans runtime")
}
