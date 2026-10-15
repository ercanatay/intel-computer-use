import Foundation

public enum WireLimits {
    public static let maxPayloadBytes = 8_388_608
}

public struct ProtocolFailure: Error {
    public enum Reason {
        case emptyFrame, oversizedFrame, invalidFrame
        case invalidJSON, nestingLimit, valueLimit, duplicateKey, invalidEnvelope
    }
    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}

public enum FrameCodec {
    public static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw ProtocolFailure(.emptyFrame) }
        guard payload.count <= WireLimits.maxPayloadBytes else { throw ProtocolFailure(.oversizedFrame) }
        var length = UInt32(payload.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }
}

public struct FrameDecoder {
    private var header = Data()
    private var payload = Data()
    private var expectedSize: Int?
    private var failed = false

    public init() {}
    public var bufferedByteCount: Int { header.count + payload.count }

    public mutating func consume(_ chunk: Data, emit: (Data) throws -> Void) throws {
        guard !failed else { throw ProtocolFailure(.invalidFrame) }
        var offset = chunk.startIndex
        do {
            while offset < chunk.endIndex {
                if expectedSize == nil {
                    let count = min(4 - header.count, chunk.endIndex - offset)
                    header.append(chunk[offset..<(offset + count)])
                    offset += count
                    guard header.count == 4 else { continue }
                    let length = header.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                    guard length > 0 else { throw ProtocolFailure(.emptyFrame) }
                    guard length <= WireLimits.maxPayloadBytes else { throw ProtocolFailure(.oversizedFrame) }
                    expectedSize = Int(length)
                    header.removeAll(keepingCapacity: true)
                }
                if let expectedSize {
                    let count = min(expectedSize - payload.count, chunk.endIndex - offset)
                    payload.append(chunk[offset..<(offset + count)])
                    offset += count
                    if payload.count == expectedSize {
                        let complete = payload
                        payload = Data()
                        self.expectedSize = nil
                        try emit(complete)
                    }
                }
            }
        } catch {
            failed = true
            payload = Data()
            header = Data()
            throw error
        }
    }
}
