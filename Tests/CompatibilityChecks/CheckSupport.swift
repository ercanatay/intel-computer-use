import Foundation

struct CheckFailure: Error {
    let message: String
}

var compatibilityCheckCount = 0

func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
    compatibilityCheckCount += 1
}

func expectFailure(_ operation: () throws -> Void) throws {
    var failed = false
    do { try operation() } catch { failed = true }
    try expect(failed, "Expected rejection")
}
