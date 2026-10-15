import AppKit
import BridgeCore
import CompatibilityProtocol
import CoreGraphics
import Foundation
import IOKit

public protocol SessionObserving {
    func currentState() -> SessionState
    func start(onUnsafe: @escaping () -> Void)
    func stop()
}

public final class MacSessionObserver: SessionObserving {
    private var observations: [NSObjectProtocol] = []
    public init() {}
    public func currentState() -> SessionState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unknown }
        var registryLocked: Bool?
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        if root != 0 {
            registryLocked = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            IOObjectRelease(root)
        }
        let dictionaryLocked = session["CGSSessionScreenIsLocked"] as? Bool
        let locked: Bool? = registryLocked == true || dictionaryLocked == true ? true : registryLocked ?? dictionaryLocked
        return SessionState.resolve(onConsole: session[kCGSessionOnConsoleKey as String] as? Bool,
                                    loggedIn: session[kCGSessionLoginDoneKey as String] as? Bool, locked: locked)
    }
    public func start(onUnsafe: @escaping () -> Void) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in onUnsafe() })
        }
    }
    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for observation in observations { center.removeObserver(observation) }
        observations.removeAll()
    }
    deinit { stop() }
}

public protocol ClockProviding { func sample() -> ClockSample }

public struct SystemClock: ClockProviding {
    public init() {}
    public func sample() -> ClockSample {
        ClockSample(wallUnixMilliseconds: Date().timeIntervalSince1970 * 1000, instant: ContinuousClock.now)
    }
}
