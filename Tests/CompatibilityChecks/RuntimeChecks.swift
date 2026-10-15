import CompatibilityRuntime
import Darwin
import Foundation

func fileInfo(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw CheckFailure(message: "Fixture stat failed") }
    return info
}

func runRuntimeChecks() throws {
    let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ct." + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: base) }
    let runtime = try RuntimeDirectory.create(under: base)
    let directory = runtime.socketURL.deletingLastPathComponent()
    try expect(try fileInfo(directory).st_mode & 0o777 == 0o700, "Private runtime directory")
    _ = try runtime.bindListener()
    try expect(try fileInfo(runtime.socketURL).st_mode & 0o777 == 0o600, "Private socket")
    try expectFailure { _ = try runtime.bindListener() }
    try runtime.cleanup()
    try runtime.cleanup()
    try expect(!FileManager.default.fileExists(atPath: directory.path), "Owned runtime removed")
    let substituted = try RuntimeDirectory.create(under: base)
    _ = try substituted.bindListener()
    try FileManager.default.removeItem(at: substituted.socketURL)
    try Data("sentinel".utf8).write(to: substituted.socketURL)
    try expectFailure { try substituted.cleanup() }
    try expect(try Data(contentsOf: substituted.socketURL) == Data("sentinel".utf8), "Substituted inode preserved")
    let moved = try RuntimeDirectory.create(under: base)
    let originalDirectory = moved.socketURL.deletingLastPathComponent()
    let saved = base.appendingPathComponent("saved")
    try FileManager.default.moveItem(at: originalDirectory, to: saved)
    try FileManager.default.createSymbolicLink(at: originalDirectory, withDestinationURL: saved)
    try expectFailure { try moved.cleanup() }
    try expect(FileManager.default.fileExists(atPath: saved.path), "Directory substitution preserved")
    let beforeBind = try RuntimeDirectory.create(under: base)
    let beforeDirectory = beforeBind.socketURL.deletingLastPathComponent()
    let retained = base.appendingPathComponent("retained")
    let unrelated = base.appendingPathComponent("unrelated")
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try FileManager.default.moveItem(at: beforeDirectory, to: retained)
    try FileManager.default.createSymbolicLink(at: beforeDirectory, withDestinationURL: unrelated)
    try expectFailure { _ = try beforeBind.bindListener() }
    try expect(!FileManager.default.fileExists(atPath: unrelated.appendingPathComponent("ipc.sock").path), "Bind never follows substituted directory")
    let alias = base.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
    try expectFailure { _ = try RuntimeDirectory.create(under: alias) }
    try expectFailure { _ = try RuntimeDirectory.create(under: URL(fileURLWithPath: "/private/tmp")) }
    let longBase = base.appendingPathComponent(String(repeating: "a", count: 80))
    try FileManager.default.createDirectory(at: longBase, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try expectFailure { _ = try RuntimeDirectory.create(under: longBase) }
    let occupied = try RuntimeDirectory.create(under: base)
    try Data("sentinel".utf8).write(to: occupied.socketURL)
    try expectFailure { _ = try occupied.bindListener() }
    try expectFailure { try occupied.cleanup() }
    try expect(try Data(contentsOf: occupied.socketURL) == Data("sentinel".utf8), "Occupied endpoint preserved")
    for failure in [EvidenceFixture.Failure.credentials, .audit, .security] {
        let inspector = PeerIdentityInspector(evidence: EvidenceFixture(failure: failure))
        if failure == .credentials {
            try expectFailure { _ = try inspector.inspect(socketFD: -1) }
        } else {
            try expect(try inspector.inspect(socketFD: -1).signature == .unavailable, "Missing evidence is unavailable")
        }
    }
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CheckFailure(message: "socketpair failed") }
    defer { close(pair[0]); close(pair[1]) }
    try ReadinessChannel.validate(descriptor: pair[0])
    try expect(true, "Node-style inherited Unix pipe accepted")
    var pipePair: [Int32] = [-1, -1]
    guard pipe(&pipePair) == 0 else { throw RuntimeFailure() }
    defer { close(pipePair[0]); close(pipePair[1]) }
    try ReadinessChannel.validate(descriptor: pipePair[1])
    try expectFailure { try ReadinessChannel.validate(descriptor: pipePair[0]) }
    try expectFailure { try ReadinessChannel.validate(descriptor: -1) }
    let network = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(network) }
    try expectFailure { try ReadinessChannel.validate(descriptor: network) }
    let identity = try PeerIdentityInspector().inspect(socketFD: pair[0])
    try expect(identity.userID == getuid(), "Kernel UID observed")
    try expect(PeerPolicy.permitsDiagnosticPeer(identity, currentUID: getuid()), "Own user can diagnose")
    try expect(!PeerPolicy.permitsDiagnosticPeer(identity, currentUID: getuid() + 1), "Different user rejected")
    try expectFailure { _ = try PeerIdentityInspector().inspect(socketFD: -1) }
    for signature in [SignatureEvidence.valid, .invalid, .unavailable] {
        let fixture = PeerIdentity(userID: getuid() + 1, signature: signature)
        try expect(!PeerPolicy.permitsDiagnosticPeer(fixture, currentUID: getuid()), "Signature cannot override UID")
    }
}

struct EvidenceFixture: PeerEvidenceReading {
    enum Failure { case credentials, audit, security }
    let failure: Failure
    func userID(socketFD: Int32) throws -> UInt32 {
        if failure == .credentials { throw RuntimeFailure() }
        return getuid()
    }
    func auditToken(socketFD: Int32) -> Data? { failure == .audit ? nil : Data() }
    func signature(token: Data) -> SignatureDetails { SignatureDetails(signature: .unavailable) }
}
