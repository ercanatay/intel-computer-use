import BridgeCore
import Foundation

@main
struct GuardChecks {
    static func expectDenied(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch is BridgeFailure {
            return
        }
        throw NSError(domain: "GuardChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected the operation to be denied."])
    }

    static func main() throws {
        var count = 0
        let policy = AppPolicy(allowed: ["com.apple.calculator"])
        try policy.authorize("com.apple.calculator")
        count += 1
        for bundleID in ["com.apple.TextEdit", "com.apple.calculator.extra"] {
            try expectDenied { try policy.authorize(bundleID) }
            count += 1
        }
        for bundleID in ["com.apple.Terminal", "com.openai.codex", "com.apple.loginwindow", "com.apple.systempreferences", "com.agilebits.onepassword7", "com.apple.Passwords"] {
            try expectDenied { try AppPolicy(allowed: [bundleID]).authorize(bundleID) }
            count += 1
        }
        for state in [SessionState.locked, .inactive, .unknown] {
            try expectDenied { try state.requireUnlocked() }
            count += 1
        }
        try SessionState.unlocked.requireUnlocked()
        count += 1
        let sessionCases: [(Bool?, Bool?, Bool?, SessionState)] = [
            (true, true, false, .unlocked), (true, true, true, .locked),
            (true, true, nil, .unknown), (nil, true, false, .unknown),
            (false, true, false, .inactive), (true, false, false, .inactive)
        ]
        for (onConsole, loggedIn, locked, expected) in sessionCases {
            guard SessionState.resolve(onConsole: onConsole, loggedIn: loggedIn, locked: locked) == expected else {
                throw NSError(domain: "GuardChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Session evidence classified incorrectly."])
            }
            count += 1
        }
        guard !CapturePolicy.permits(role: "AXTextField", subrole: "AXSecureTextField"),
              !CapturePolicy.permits(role: "AXSecureTextField", subrole: nil),
              CapturePolicy.permits(role: "AXTextField", subrole: nil) else {
            throw NSError(domain: "GuardChecks", code: 4, userInfo: [NSLocalizedDescriptionKey: "Secure fields must be omitted before reading text."])
        }
        count += 3
        try OperationDeadline(unixMilliseconds: 2000).requireValid(now: 1)
        for deadline in [999.0, 1000.0, .infinity, .nan] {
            try expectDenied { try OperationDeadline(unixMilliseconds: deadline).requireValid(now: 1) }
        }
        count += 5
        for point in [(-1.0, 2.0), (10.0, -1.0), (100.0, 20.0), (10.0, 80.0), (.infinity, 1.0), (.nan, 1.0)] {
            try expectDenied { try WindowPoint(x: point.0, y: point.1).validate(width: 100, height: 80) }
            count += 1
        }
        try WindowPoint(x: 0, y: 0).validate(width: 100, height: 80)
        count += 1
        let chord = try KeyChord.parse("cmd+shift+a")
        guard chord.keyCode == 0, chord.modifiers == [.command, .shift], try KeyChord.parse("Return").keyCode == 36 else {
            throw NSError(domain: "GuardChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Key chord decoded incorrectly."])
        }
        count += 1
        for value in ["", "cmd", "cmd+", "cmd+bogus", "a+b", "cmd+cmd+a"] {
            try expectDenied { _ = try KeyChord.parse(value) }
            count += 1
        }
        print("Passed \(count) native guard checks.")
    }
}
