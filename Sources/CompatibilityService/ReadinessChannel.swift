import Darwin

public enum ReadinessChannel {
    public static func validate(descriptor: Int32) throws {
        var info = stat()
        let flags = fcntl(descriptor, F_GETFL)
        guard descriptor >= 3, flags >= 0, flags & O_ACCMODE != O_RDONLY, fstat(descriptor, &info) == 0 else { throw RuntimeFailure() }
        if info.st_mode & S_IFMT == S_IFIFO { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw RuntimeFailure() }
        var address = sockaddr_un()
        var size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        var kind: Int32 = 0
        var kindSize = socklen_t(MemoryLayout<Int32>.size)
        var user: uid_t = 0
        var group: gid_t = 0
        guard result == 0, address.sun_family == AF_UNIX,
              getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &kind, &kindSize) == 0, kind == SOCK_STREAM,
              getpeereid(descriptor, &user, &group) == 0, user == geteuid() else { throw RuntimeFailure() }
    }
}
