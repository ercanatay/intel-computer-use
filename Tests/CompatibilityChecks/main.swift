import Foundation

do {
    let group = CommandLine.arguments.dropFirst().first ?? "all"
    guard ["all", "framing", "protocol", "runtime", "server"].contains(group) else { throw CheckFailure(message: "Unknown check group") }
    if group == "all" || group == "framing" { try runFrameChecks() }
    if group == "all" || group == "protocol" { try runProtocolChecks() }
    if group == "all" || group == "runtime" { try runRuntimeChecks() }
    if group == "all" || group == "server" { try runServerChecks() }
    print("Passed \(compatibilityCheckCount) compatibility checks (\(group)).")
} catch {
    let message = (error as? CheckFailure)?.message ?? "Compatibility check failed"
    FileHandle.standardError.write(Data((message + " after \(compatibilityCheckCount) checks\n").utf8))
    exit(1)
}
