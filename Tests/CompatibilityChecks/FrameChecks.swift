import CompatibilityProtocol
import Foundation

func runFrameChecks() throws {
    let payload = Data("Türkçe + 42".utf8)
    let encoded = try FrameCodec.encode(payload)
    try expect(encoded.count == 17, "UTF-8 payload size")
    try expect(Array(encoded.prefix(4)) == [13, 0, 0, 0], "Little-endian header")
    var decoder = FrameDecoder()
    var received: [Data] = []
    try decoder.consume(encoded.prefix(3)) { received.append($0) }
    try expect(received.isEmpty, "Partial header cannot emit")
    try decoder.consume(encoded.dropFirst(3)) { received.append($0) }
    try expect(received == [payload], "Fragmented input")
    try expect(decoder.bufferedByteCount == 0, "Completed frame releases buffer")
    var byteDecoder = FrameDecoder()
    received = []
    for byte in encoded { try byteDecoder.consume(Data([byte])) { received.append($0) } }
    try expect(received == [payload], "Byte-at-a-time framing")
    var combinedDecoder = FrameDecoder()
    received = []
    try combinedDecoder.consume(encoded + encoded + encoded.prefix(2)) { received.append($0) }
    try expect(received == [payload, payload], "Coalesced frames")
    try expect(combinedDecoder.bufferedByteCount == 2, "Partial next header retained")
    for header in [Data([0, 0, 0, 0]), Data([1, 0, 128, 0]), Data([255, 255, 255, 255])] {
        var rejected = FrameDecoder()
        try expectFailure { try rejected.consume(header) { _ in throw CheckFailure(message: "Must not emit") } }
        try expect(rejected.bufferedByteCount <= 4, "Reject oversized header before allocation")
    }
    try expectFailure { _ = try FrameCodec.encode(Data()) }
    try expectFailure { _ = try FrameCodec.encode(Data(repeating: 0, count: 8_388_609)) }
    let maximum = Data(repeating: 42, count: 8_388_608)
    var maximumDecoder = FrameDecoder()
    var maximumSeen = false
    try maximumDecoder.consume(try FrameCodec.encode(maximum)) { decoded in maximumSeen = decoded == maximum }
    try expect(maximumSeen, "Maximum frame accepted")
    var abortingDecoder = FrameDecoder()
    var calls = 0
    try expectFailure {
        try abortingDecoder.consume(encoded + encoded) { _ in
            calls += 1
            throw CheckFailure(message: "Consumer stopped")
        }
    }
    try expect(calls == 1, "Consumer failure stops coalesced input")
}
