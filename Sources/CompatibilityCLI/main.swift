import CompatibilityRuntime
import Darwin
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, arguments[0] == "--diagnostic", arguments[1] == "--ready-fd",
      let readyFD = Int32(arguments[2]), readyFD >= 3, geteuid() != 0 else {
    fail("Diagnostic mode requires --diagnostic --ready-fd N and a non-root user.", code: 2)
}
do { try ReadinessChannel.validate(descriptor: readyFD) }
catch { fail("Private readiness pipe required.", code: 2) }
umask(0o077)
signal(SIGPIPE, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

do {
    let runtime = try RuntimeDirectory.create(under: FileManager.default.temporaryDirectory)
    let server = DiagnosticServer(runtime: runtime, session: MacSessionObserver(), peerInspector: PeerIdentityInspector(), clock: SystemClock())
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    interrupt.setEventHandler { server.stop(reason: .shutdown) }
    terminate.setEventHandler { server.stop(reason: .shutdown) }
    interrupt.resume(); terminate.resume()
    DispatchQueue.global().async {
        do {
            try server.run { endpoint in
                let record = try JSONSerialization.data(withJSONObject: ["socketPath": endpoint.path, "protocol": "CodexComputerUseIPC-5"], options: [.sortedKeys]) + Data([10])
                guard record.count <= 4096 else { throw RuntimeFailure() }
                defer { close(readyFD) }
                let count = record.withUnsafeBytes { Darwin.write(readyFD, $0.baseAddress, $0.count) }
                guard count == record.count else { throw RuntimeFailure() }
            }
            exit(0)
        } catch ServerFailure.unavailableSession {
            fail("Diagnostic service skipped: session is unsafe or unknown.", code: 2)
        } catch {
            fail("Diagnostic service stopped safely.", code: 2)
        }
    }
    dispatchMain()
} catch { fail("Diagnostic runtime unavailable.", code: 2) }
