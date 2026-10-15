import Foundation
import Darwin

public struct RuntimeFailure: Error { public init() {} }

public final class RuntimeDirectory {
    public let socketURL: URL
    private let parentFD: Int32
    private let directoryFD: Int32
    private let name: String
    private let directoryIdentity: stat
    private var socketIdentity: stat?
    private var listenerFD: Int32 = -1
    private var cleaned = false

    private init(socketURL: URL, parentFD: Int32, directoryFD: Int32, name: String, identity: stat) {
        self.socketURL = socketURL
        self.parentFD = parentFD
        self.directoryFD = directoryFD
        self.name = name
        directoryIdentity = identity
    }

    public static func create(under base: URL) throws -> RuntimeDirectory {
        var initial = stat()
        guard base.isFileURL, lstat(base.path, &initial) == 0,
              initial.st_mode & S_IFMT == S_IFDIR, initial.st_uid == geteuid(),
              initial.st_mode & 0o077 == 0 else { throw RuntimeFailure() }
        let canonical = base.resolvingSymlinksInPath()
        let candidate = canonical.path + "/icu.XXXXXX/ipc.sock"
        guard candidate.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { throw RuntimeFailure() }
        let parent = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw RuntimeFailure() }
        var actual = stat()
        guard fstat(parent, &actual) == 0, actual.st_ino == initial.st_ino, actual.st_dev == initial.st_dev,
              actual.st_uid == geteuid(), actual.st_mode & 0o077 == 0 else {
            close(parent)
            throw RuntimeFailure()
        }
        var template = Array((canonical.path + "/icu.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { close(parent); throw RuntimeFailure() }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        let name = directory.lastPathComponent
        let owned = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var identity = stat()
        guard owned >= 0, fstat(owned, &identity) == 0, identity.st_uid == geteuid(), fchmod(owned, 0o700) == 0 else {
            if owned >= 0 { close(owned) }
            _ = unlinkat(parent, name, AT_REMOVEDIR)
            close(parent)
            throw RuntimeFailure()
        }
        return RuntimeDirectory(socketURL: directory.appendingPathComponent("ipc.sock"), parentFD: parent,
                                directoryFD: owned, name: name, identity: identity)
    }

    public func bindListener() throws -> Int32 {
        guard !cleaned, listenerFD < 0 else { throw RuntimeFailure() }
        var directory = stat()
        guard fstatat(parentFD, name, &directory, AT_SYMLINK_NOFOLLOW) == 0,
              directory.st_mode & S_IFMT == S_IFDIR, directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700,
              directory.st_ino == directoryIdentity.st_ino, directory.st_dev == directoryIdentity.st_dev else { throw RuntimeFailure() }
        var existing = stat()
        guard fstatat(directoryFD, "ipc.sock", &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw RuntimeFailure() }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RuntimeFailure() }
        listenerFD = descriptor
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(socketURL.path.utf8) + [UInt8(0)]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RuntimeFailure() }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw RuntimeFailure() }
        var identity = stat()
        guard fstatat(directoryFD, "ipc.sock", &identity, AT_SYMLINK_NOFOLLOW) == 0,
              identity.st_mode & S_IFMT == S_IFSOCK, identity.st_uid == geteuid() else { throw RuntimeFailure() }
        socketIdentity = identity
        guard fchmodat(directoryFD, "ipc.sock", 0o600, AT_SYMLINK_NOFOLLOW) == 0,
              listen(descriptor, 1) == 0 else { throw RuntimeFailure() }
        return descriptor
    }

    public func cleanup() throws {
        guard !cleaned else { return }
        cleaned = true
        if listenerFD >= 0 { close(listenerFD); listenerFD = -1 }
        defer { close(directoryFD); close(parentFD) }
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_mode & S_IFMT == S_IFDIR, current.st_uid == geteuid(),
              current.st_ino == directoryIdentity.st_ino, current.st_dev == directoryIdentity.st_dev else { throw RuntimeFailure() }
        if let socketIdentity {
            var endpoint = stat()
            let found = fstatat(directoryFD, "ipc.sock", &endpoint, AT_SYMLINK_NOFOLLOW)
            if found == 0 {
                guard endpoint.st_mode & S_IFMT == S_IFSOCK, endpoint.st_uid == geteuid(),
                      endpoint.st_ino == socketIdentity.st_ino, endpoint.st_dev == socketIdentity.st_dev,
                      unlinkat(directoryFD, "ipc.sock", 0) == 0 else { throw RuntimeFailure() }
            } else if errno != ENOENT { throw RuntimeFailure() }
        }
        guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw RuntimeFailure() }
    }

    deinit { try? cleanup() }
}
