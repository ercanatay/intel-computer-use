import BridgeCore
import CompatibilityProtocol
import Darwin
import Foundation

public enum SocketWriteResult { case written(Int), wouldBlock, interrupted, failed }
public protocol SocketWriting {
    func write(socketFD: Int32, data: Data, offset: Int) -> SocketWriteResult
}
public struct SystemSocketWriter: SocketWriting {
    public init() {}
    public func write(socketFD: Int32, data: Data, offset: Int) -> SocketWriteResult {
        let count = data.withUnsafeBytes { Darwin.write(socketFD, $0.baseAddress!.advanced(by: offset), data.count - offset) }
        if count > 0 { return .written(count) }
        if errno == EINTR { return .interrupted }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        return .failed
    }
}

public enum ServerFailure: Error { case unavailableSession, alreadyStarted }

public final class DiagnosticServer {
    private let runtime: RuntimeDirectory
    private let session: any SessionObserving
    private let peerInspector: any PeerInspecting
    private let clock: any ClockProviding
    private let writer: any SocketWriting
    private let queue = DispatchQueue(label: "io.github.ercanatay.compat.diagnostic")
    private let completion = DispatchSemaphore(value: 0)
    private var started = false
    private var stopped = false
    private var cleanupFailed = false
    private var listener: DispatchSourceRead?
    private var reader: DispatchSourceRead?
    private var writable: DispatchSourceWrite?
    private var timer: DispatchSourceTimer?
    private var client: Int32 = -1
    private var didAccept = false
    private var serviceExpiry: ContinuousClock.Instant?
    private var inputExpiry: ContinuousClock.Instant?
    private var frameStart: ContinuousClock.Instant?
    private var decoder = FrameDecoder()
    private let protocolSession = DiagnosticSession()
    private var reply: DiagnosticReply?
    private var output = Data()
    private var outputOffset = 0

    public init(runtime: RuntimeDirectory, session: any SessionObserving, peerInspector: any PeerInspecting,
                clock: any ClockProviding, writer: any SocketWriting = SystemSocketWriter()) {
        self.runtime = runtime
        self.session = session
        self.peerInspector = peerInspector
        self.clock = clock
        self.writer = writer
    }

    public func run(onReady: (URL) throws -> Void) throws {
        try queue.sync {
            guard !started, !stopped else { throw ServerFailure.alreadyStarted }
            started = true
            do {
                guard session.currentState() == .unlocked else { throw ServerFailure.unavailableSession }
                serviceExpiry = clock.sample().instant.advanced(by: .seconds(300))
                let descriptor = try runtime.bindListener()
                try configure(descriptor)
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [weak self] in self?.acceptClients(descriptor) }
                listener = source
                source.resume()
                let ticker = DispatchSource.makeTimerSource(queue: queue)
                ticker.schedule(deadline: .now(), repeating: .milliseconds(100))
                ticker.setEventHandler { [weak self] in _ = self?.checkSafety() }
                timer = ticker
                ticker.resume()
                session.start { [weak self] in self?.stop(reason: .power) }
                guard checkSafety() else { throw ServerFailure.unavailableSession }
                try onReady(runtime.socketURL)
            } catch {
                finish(reason: .shutdown)
                throw error
            }
        }
        completion.wait()
        queue.sync {}
        if cleanupFailed { throw RuntimeFailure() }
    }

    public func stop(reason: CloseReason) { queue.async { self.finish(reason: reason) } }

    private func configure(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw RuntimeFailure() }
    }

    private func checkSafety() -> Bool {
        guard !stopped else { return false }
        guard session.currentState() == .unlocked else { finish(reason: .session); return false }
        let now = clock.sample().instant
        if let expiry = serviceExpiry, now >= expiry { finish(reason: .lifetime); return false }
        if let expiry = reply?.expiresAt, now >= expiry { finish(reason: .deadline); return false }
        if let expiry = inputExpiry, now >= expiry { finish(reason: .deadline); return false }
        return true
    }

    private func acceptClients(_ descriptor: Int32) {
        guard checkSafety() else { return }
        for _ in 0..<16 {
            let accepted = accept(descriptor, nil, nil)
            if accepted < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { finish(reason: .io) }
                return
            }
            guard !didAccept else { close(accepted); continue }
            do {
                try configure(accepted)
                let identity = try peerInspector.inspect(socketFD: accepted)
                guard PeerPolicy.permitsDiagnosticPeer(identity, currentUID: geteuid()), checkSafety() else {
                    close(accepted); finish(reason: .peer); return
                }
            } catch { close(accepted); finish(reason: .peer); return }
            didAccept = true
            client = accepted
            inputExpiry = clock.sample().instant.advanced(by: .seconds(5))
            let source = DispatchSource.makeReadSource(fileDescriptor: accepted, queue: queue)
            source.setEventHandler { [weak self] in self?.readInput() }
            source.setCancelHandler { close(accepted) }
            reader = source
            source.resume()
        }
    }

    private func readInput() {
        guard checkSafety() else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<16 {
            let count = read(client, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(reason: .io); return
            }
            guard count > 0 else { finish(reason: .io); return }
            if frameStart == nil {
                frameStart = clock.sample().instant
                inputExpiry = frameStart?.advanced(by: .seconds(5))
            }
            do {
                var incoming = decoder
                decoder = FrameDecoder()
                try incoming.consume(Data(bytes.prefix(count))) { payload in
                    guard self.checkSafety() else { throw RuntimeFailure() }
                    switch self.protocolSession.receive(payload, clock: self.clock.sample()) {
                    case .close: throw ProtocolFailure(.invalidEnvelope)
                    case .silent: break
                    case let .reply(response):
                        guard self.reply == nil else { throw ProtocolFailure(.invalidEnvelope) }
                        self.reply = response
                        self.output = try FrameCodec.encode(response.payload)
                        self.outputOffset = 0
                    }
                    self.frameStart = nil
                    self.inputExpiry = self.clock.sample().instant.advanced(by: .seconds(5))
                }
                guard !stopped else { return }
                decoder = incoming
                if decoder.bufferedByteCount > 0 && frameStart == nil {
                    frameStart = clock.sample().instant
                    inputExpiry = frameStart?.advanced(by: .seconds(5))
                }
            } catch { finish(reason: .invalidInput); return }
            guard checkSafety() else { return }
            if reply != nil { enableWrites() }
        }
    }

    private func enableWrites() {
        guard writable == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.flushOutput() }
        writable = source
        source.resume()
    }

    private func flushOutput() {
        guard checkSafety(), let pending = reply else { return }
        for _ in 0..<64 {
            guard checkSafety() else { return }
            switch writer.write(socketFD: client, data: output, offset: outputOffset) {
            case let .written(count):
                guard count > 0, count <= output.count - outputOffset else { finish(reason: .io); return }
                outputOffset += count
            case .interrupted: continue
            case .wouldBlock: return
            case .failed: finish(reason: .io); return
            }
            if outputOffset == output.count {
                do { try protocolSession.didSendReply(requestID: pending.requestID) }
                catch { finish(reason: .invalidInput); return }
                reply = nil
                output.removeAll(keepingCapacity: false)
                outputOffset = 0
                writable?.cancel()
                writable = nil
                if frameStart == nil { inputExpiry = clock.sample().instant.advanced(by: .seconds(5)) }
                return
            }
        }
    }

    private func finish(reason: CloseReason) {
        guard !stopped else { return }
        stopped = true
        session.stop()
        timer?.cancel(); timer = nil
        writable?.cancel(); writable = nil
        reader?.cancel(); reader = nil
        client = -1
        listener?.cancel(); listener = nil
        reply = nil
        output.removeAll(keepingCapacity: false)
        decoder = FrameDecoder()
        do { try runtime.cleanup() } catch { cleanupFailed = true }
        queue.async { self.completion.signal() }
    }
}
