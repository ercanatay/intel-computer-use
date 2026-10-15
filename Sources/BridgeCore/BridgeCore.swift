import Foundation

public struct BridgeFailure: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct AppPolicy: Sendable {
    public let allowed: Set<String>

    public init(allowed: Set<String>) {
        self.allowed = allowed
    }

    public func authorize(_ bundleID: String) throws {
        let prefixes = ["com.openai.", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords", "com.agilebits.", "com.1password.", "com.bitwarden."]
        guard !prefixes.contains(where: { bundleID.lowercased().hasPrefix($0.lowercased()) }) else {
            throw BridgeFailure("protected_app", "This application is protected from desktop automation.")
        }
        guard allowed.contains(bundleID) else {
            throw BridgeFailure("app_not_allowed", "Add the exact bundle ID to the server's --allow arguments: \(bundleID)")
        }
    }
}

public enum SessionState: String, Sendable {
    case unlocked, locked, inactive, unknown

    public static func resolve(onConsole: Bool?, loggedIn: Bool?, locked: Bool?) -> SessionState {
        guard let locked = locked else { return .unknown }
        if locked { return .locked }
        guard let onConsole = onConsole, let loggedIn = loggedIn else { return .unknown }
        return onConsole && loggedIn ? .unlocked : .inactive
    }

    public func requireUnlocked() throws {
        guard self == .unlocked else {
            throw BridgeFailure("session_unavailable", "Native control requires an active, unlocked Mac session (current: \(rawValue)).")
        }
    }
}

public enum CapturePolicy {
    public static func permits(role: String, subrole: String?) -> Bool {
        role != "AXSecureTextField" && subrole != "AXSecureTextField"
    }
}

public enum ForegroundInputPolicy {
    public static func requireFrontmost(targetPID: Int32, frontmostPID: Int32?, terminated: Bool) throws {
        guard !terminated, frontmostPID == targetPID else {
            throw BridgeFailure("focus_changed", "Input stopped because the target app lost focus.")
        }
    }

    public static func requirePointOwner(targetPID: Int32, hitPID: Int32?, targetWindowMatches: Bool) throws {
        guard hitPID == targetPID, targetWindowMatches else {
            throw BridgeFailure("point_occluded", "Another window covers the selected point. Input was not sent.")
        }
    }
}

public struct OperationDeadline: Sendable {
    public let unixMilliseconds: Double

    public init(unixMilliseconds: Double) {
        self.unixMilliseconds = unixMilliseconds
    }

    public func requireValid(now: Double) throws {
        guard unixMilliseconds.isFinite, now.isFinite, unixMilliseconds > now * 1000 else {
            throw BridgeFailure("deadline_exceeded", "The native request deadline expired; input was stopped.")
        }
    }
}

public struct WindowPoint: Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func validate(width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, x >= 0, y >= 0, x < width, y < height else {
            throw BridgeFailure("invalid_coordinate", "Coordinates must be finite points inside the selected window.")
        }
    }
}

public enum KeyModifier: String, Hashable, Sendable {
    case command, shift, control, option
}

public struct KeyChord: Sendable {
    public let keyCode: UInt16
    public let modifiers: Set<KeyModifier>

    public static func parse(_ value: String) throws -> KeyChord {
        let parts = value.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let aliases: [String: KeyModifier] = ["cmd": .command, "command": .command, "super": .command, "meta": .command, "shift": .shift, "ctrl": .control, "control": .control, "alt": .option, "option": .option]
        let keys: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28,
            "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "return": 36,
            "enter": 36, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
            "home": 115, "pageup": 116, "delete": 117, "end": 119,
            "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126
        ]
        guard let last = parts.last, let keyCode = keys[last] else {
            throw BridgeFailure("invalid_key", "Use one supported key with optional cmd, ctrl, shift, or alt modifiers.")
        }
        var modifiers = Set<KeyModifier>()
        for part in parts.dropLast() {
            guard let modifier = aliases[part], modifiers.insert(modifier).inserted else {
                throw BridgeFailure("invalid_key", "Unknown or duplicate keyboard modifier.")
            }
        }
        return KeyChord(keyCode: keyCode, modifiers: modifiers)
    }
}
