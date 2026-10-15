import BridgeCore
import CompatibilityProtocol
import CompatibilityRuntime
import Darwin
import Foundation

final class FixtureClock: ClockProviding {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var elapsed: Duration = .zero
    func advance(_ duration: Duration) { lock.lock(); elapsed += duration; lock.unlock() }
    func sample() -> ClockSample {
        lock.lock(); defer { lock.unlock() }
        return ClockSample(wallUnixMilliseconds: 1_000_000, instant: origin.advanced(by: elapsed))
    }
}

final class FixtureSession: SessionObserving {
    private let lock = NSLock()
    private var state: SessionState = .unlocked
    private var callback: (() -> Void)?
    func currentState() -> SessionState { lock.lock(); defer { lock.unlock() }; return state }
    func start(onUnsafe: @escaping () -> Void) { lock.lock(); callback = onUnsafe; lock.unlock() }
    func stop() { lock.lock(); callback = nil; lock.unlock() }
    func change(to state: SessionState) { lock.lock(); self.state = state; lock.unlock() }
    func powerEvent() { lock.lock(); let action = callback; lock.unlock(); action?() }
}

struct FixturePeer: PeerInspecting {
    let wrongUser: Bool
    let fails: Bool
    func inspect(socketFD: Int32) throws -> PeerIdentity {
        if fails { throw RuntimeFailure() }
        return PeerIdentity(userID: getuid() + (wrongUser ? 1 : 0), signature: .unavailable)
    }
}

struct ShortWriter: SocketWriting {
    func write(socketFD: Int32, data: Data, offset: Int) -> SocketWriteResult {
        SystemSocketWriter().write(socketFD: socketFD, data: data.prefix(min(data.count, offset + 3)), offset: offset)
    }
}

final class InterruptedWriter: SocketWriting {
    private var interrupted = false
    func write(socketFD: Int32, data: Data, offset: Int) -> SocketWriteResult {
        if !interrupted { interrupted = true; return .interrupted }
        return ShortWriter().write(socketFD: socketFD, data: data, offset: offset)
    }
}

struct BlockedWriter: SocketWriting {
    func write(socketFD: Int32, data: Data, offset: Int) -> SocketWriteResult { .wouldBlock }
}

final class ServerFixture {
    let base: URL
    let runtime: RuntimeDirectory
    let session = FixtureSession()
    let clock = FixtureClock()
    let server: DiagnosticServer
    private let ready = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    private var finished = false
    private var started = false

    init(peer: any PeerInspecting = PeerIdentityInspector(), writer: any SocketWriting = SystemSocketWriter()) throws {
        base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("cs." + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        runtime = try RuntimeDirectory.create(under: base)
        server = DiagnosticServer(runtime: runtime, session: session, peerInspector: peer, clock: clock, writer: writer)
    }
    func start() throws {
        started = true
        Thread.detachNewThread { [self] in
            defer { done.signal() }
            try? server.run { _ in ready.signal() }
        }
        guard ready.wait(timeout: .now() + 3) == .success else { throw CheckFailure(message: "Server not ready") }
    }
    func connect() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeFailure() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(runtime.socketURL.path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(descriptor); throw RuntimeFailure() }
        return descriptor
    }
    func finish() throws {
        if finished || !started { return }
        server.stop(reason: .shutdown)
        guard done.wait(timeout: .now() + 3) == .success else { throw CheckFailure(message: "Server did not stop") }
        finished = true
    }
    deinit { try? finish(); try? FileManager.default.removeItem(at: base) }
}

func sendBytes(_ data: Data, to descriptor: Int32) throws {
    let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    guard written == data.count else { throw CheckFailure(message: "Fixture send failed") }
}

func readable(_ descriptor: Int32, timeout: Int32 = 2000) -> Bool {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    return poll(&event, 1, timeout) > 0
}

func receivePayload(_ descriptor: Int32) throws -> Data {
    var decoder = FrameDecoder()
    var result: Data?
    var bytes = [UInt8](repeating: 0, count: 4096)
    while result == nil {
        guard readable(descriptor) else { throw CheckFailure(message: "Reply timed out") }
        let count = read(descriptor, &bytes, bytes.count)
        guard count > 0 else { throw CheckFailure(message: "Reply disconnected") }
        try decoder.consume(Data(bytes.prefix(count))) { result = $0 }
    }
    return result!
}

func expectDisconnected(_ descriptor: Int32) throws {
    try expect(readable(descriptor), "Close observed within bound")
    var byte: UInt8 = 0
    try expect(read(descriptor, &byte, 1) <= 0, "Connection closed without replay")
}
