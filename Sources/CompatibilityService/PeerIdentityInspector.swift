import Darwin
import Foundation
import Security

public enum SignatureEvidence { case valid, invalid, unavailable }

public struct PeerIdentity {
    public let userID: UInt32
    public let signature: SignatureEvidence
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let codeDirectoryHash: Data?
    public init(userID: UInt32, signature: SignatureEvidence, signingIdentifier: String? = nil,
                teamIdentifier: String? = nil, codeDirectoryHash: Data? = nil) {
        self.userID = userID
        self.signature = signature
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
    }
}

public protocol PeerInspecting {
    func inspect(socketFD: Int32) throws -> PeerIdentity
}

public enum PeerPolicy {
    public static func permitsDiagnosticPeer(_ identity: PeerIdentity, currentUID: UInt32) -> Bool {
        identity.userID == currentUID
    }
}

public struct PeerIdentityInspector: PeerInspecting {
    private let evidence: any PeerEvidenceReading
    public init() { evidence = KernelPeerEvidence() }
    public init(evidence: any PeerEvidenceReading) { self.evidence = evidence }
    public func inspect(socketFD: Int32) throws -> PeerIdentity {
        let user = try evidence.userID(socketFD: socketFD)
        guard let token = evidence.auditToken(socketFD: socketFD) else { return PeerIdentity(userID: user, signature: .unavailable) }
        let details = evidence.signature(token: token)
        return PeerIdentity(userID: user, signature: details.signature, signingIdentifier: details.signingIdentifier,
                            teamIdentifier: details.teamIdentifier, codeDirectoryHash: details.codeDirectoryHash)
    }
}

public struct SignatureDetails {
    public let signature: SignatureEvidence
    public let signingIdentifier: String?
    public let teamIdentifier: String?
    public let codeDirectoryHash: Data?
    public init(signature: SignatureEvidence, signingIdentifier: String? = nil, teamIdentifier: String? = nil, codeDirectoryHash: Data? = nil) {
        self.signature = signature
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeDirectoryHash = codeDirectoryHash
    }
}

public protocol PeerEvidenceReading {
    func userID(socketFD: Int32) throws -> UInt32
    func auditToken(socketFD: Int32) -> Data?
    func signature(token: Data) -> SignatureDetails
}

private struct KernelPeerEvidence: PeerEvidenceReading {
    func userID(socketFD: Int32) throws -> UInt32 {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(socketFD, &user, &group) == 0 else { throw RuntimeFailure() }
        return user
    }
    func auditToken(socketFD: Int32) -> Data? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout.size(ofValue: token))
        let result = withUnsafeMutablePointer(to: &token) { getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &size) }
        guard result == 0, size == MemoryLayout.size(ofValue: token) else {
            return nil
        }
        return withUnsafeBytes(of: token) { Data($0) }
    }
    func signature(token: Data) -> SignatureDetails {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: token] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return SignatureDetails(signature: .unavailable) }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return SignatureDetails(signature: .invalid) }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let fields = information as? [String: Any] else { return SignatureDetails(signature: .unavailable) }
        return SignatureDetails(signature: .valid,
                            signingIdentifier: fields[kSecCodeInfoIdentifier as String] as? String,
                            teamIdentifier: fields[kSecCodeInfoTeamIdentifier as String] as? String,
                            codeDirectoryHash: fields[kSecCodeInfoUnique as String] as? Data)
    }
}
