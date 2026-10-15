import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import BridgeCore
import IOKit

struct NativeRequest: Decodable {
    let command: String
    let bundleId: String?
    let windowId: UInt32?
    let x: Double?
    let y: Double?
    let text: String?
    let key: String?
    let button: String?
    let clickCount: Int?
    let direction: String?
    let pixels: Int?
    let includeScreenshot: Bool?
    let deadlineUnixMilliseconds: Double?
}

@MainActor
final class DesktopController {
    let policy: AppPolicy
    let deadline: OperationDeadline

    init(deadlineUnixMilliseconds: Double? = nil) {
        let bundleIDs = ProcessInfo.processInfo.environment["ICU_ALLOWED_BUNDLE_IDS", default: ""].split(separator: ",").map(String.init)
        policy = AppPolicy(allowed: Set(bundleIDs))
        deadline = OperationDeadline(unixMilliseconds: deadlineUnixMilliseconds ?? (Date().timeIntervalSince1970 + 20) * 1000)
    }

    func requireSession() throws {
        try deadline.requireValid(now: Date().timeIntervalSince1970)
        try sessionState().requireUnlocked()
    }

    func sessionState() -> SessionState {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return .unknown }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        var registryLocked: Bool?
        if root != 0 {
            registryLocked = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            IOObjectRelease(root)
        }
        let sessionLocked = session["CGSSessionScreenIsLocked"] as? Bool
        let locked = registryLocked == true || sessionLocked == true ? true : registryLocked ?? sessionLocked
        return SessionState.resolve(onConsole: session[kCGSessionOnConsoleKey as String] as? Bool,
                                    loggedIn: session[kCGSessionLoginDoneKey as String] as? Bool,
                                    locked: locked)
    }

    func status() -> [String: Any] {
        ["architecture": architecture(), "session": sessionState().rawValue,
         "accessibility": AXIsProcessTrusted(), "screen_recording": CGPreflightScreenCaptureAccess(),
         "post_events": CGPreflightPostEventAccess(),
         "allowed_bundle_ids": policy.allowed.sorted(), "locked_use_supported": false,
         "helper": "intel-computer-use", "version": "0.1.0"]
    }

    func architecture() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    func application(_ bundleID: String) throws -> NSRunningApplication {
        try policy.authorize(bundleID)
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              !app.isTerminated else {
            throw BridgeFailure("app_not_running", "The allowed app is not running. Use open_app first.")
        }
        return app
    }

    func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw BridgeFailure("accessibility_required", "Enable Accessibility for Intel Computer Use in System Settings > Privacy & Security. Run the installed helper with --setup to request access.")
        }
    }

    func window(_ windowID: UInt32, app: NSRunningApplication) throws -> CGRect {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let entry = entries.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
              (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 0, frame.height > 0 else {
            throw BridgeFailure("window_not_found", "The window is no longer visible or does not belong to the requested app. Refresh list_windows.")
        }
        return frame
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    func elementBounds(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func matchingAXWindow(app: NSRunningApplication, frame: CGRect) throws -> AXUIElement {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let matches = windows.filter { element in
            guard let bounds = elementBounds(element) else { return false }
            return abs(bounds.minX - frame.minX) <= 1 && abs(bounds.minY - frame.minY) <= 1 && abs(bounds.width - frame.width) <= 1 && abs(bounds.height - frame.height) <= 1
        }
        guard matches.count == 1, let target = matches.first else {
            throw BridgeFailure("ambiguous_window", "Cannot uniquely match this visible window to an Accessibility window. Close overlapping identical windows and retry.")
        }
        return target
    }

    func checkFocus(app: NSRunningApplication, target: AXUIElement, windowID: UInt32, frame: CGRect) throws {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        guard let focused = attribute(root, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, target) else {
            throw BridgeFailure("focus_changed", "Input stopped because the target app or window lost focus. Take another snapshot.")
        }
        guard try window(windowID, app: app) == frame else {
            throw BridgeFailure("window_moved", "Input stopped because the target window moved. Take another snapshot.")
        }
        try requireSession()
        guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw BridgeFailure("focus_changed", "Input stopped because the target app lost focus.")
        }
    }

    func checkPoint(_ point: CGPoint, app: NSRunningApplication, target: AXUIElement) throws {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else {
            throw BridgeFailure("point_occluded", "Cannot establish which window owns this point. Refresh the snapshot.")
        }
        AXUIElementSetMessagingTimeout(element, 1)
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success, processID == app.processIdentifier,
              CFEqual(element, target) || attribute(element, kAXWindowAttribute).map({ CFEqual($0, target) }) == true else {
            throw BridgeFailure("point_occluded", "Another window covers the selected point. Input was not sent.")
        }
    }

    func focus(app: NSRunningApplication, windowID: UInt32, frame: CGRect) async throws -> AXUIElement {
        try requireAccessibility()
        let target = try matchingAXWindow(app: app, frame: frame)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        app.activate(options: [])
        for _ in 0..<12 {
            try requireSession()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try checkFocus(app: app, target: target, windowID: windowID, frame: frame)
        guard try window(windowID, app: app) == frame else {
            throw BridgeFailure("window_moved", "The window moved during activation. Take another snapshot.")
        }
        return target
    }

    func inspect(_ root: AXUIElement, frame: CGRect) -> [String: Any] {
        var nodes: [[String: Any]] = []
        var visited = Set<CFHashCode>()
        var truncated = false
        func walk(_ element: AXUIElement, depth: Int) {
            guard nodes.count < 300, depth <= 12 else { truncated = true; return }
            guard visited.insert(CFHash(element)).inserted else { return }
            let role = attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            guard CapturePolicy.permits(role: role, subrole: subrole),
                  attribute(element, "AXProtectedContent") as? Bool != true else { return }
            var node: [String: Any] = ["role": role, "depth": depth]
            for (field, name) in [("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute), ("value", kAXValueAttribute)] {
                if let text = attribute(element, name) as? String, !text.isEmpty { node[field] = String(text.prefix(2000)) }
            }
            if let bounds = elementBounds(element) {
                node["bounds"] = ["x": bounds.minX - frame.minX, "y": bounds.minY - frame.minY, "width": bounds.width, "height": bounds.height]
            }
            nodes.append(node)
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        walk(root, depth: 0)
        return ["nodes": nodes, "truncated": truncated]
    }

    func screenshot(windowID: UInt32, app: NSRunningApplication) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw BridgeFailure("screen_recording_required", "Enable Screen Recording for Intel Computer Use in System Settings > Privacy & Security. Run the installed helper with --setup to request access.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == app.processIdentifier }) else {
            throw BridgeFailure("window_not_found", "ScreenCaptureKit cannot capture the selected window.")
        }
        guard target.frame.width * target.frame.height <= 20_000_000 else {
            throw BridgeFailure("window_too_large", "The selected window exceeds the 20 megapixel capture limit.")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width.rounded(.up))
        configuration.height = Int(target.frame.height.rounded(.up))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try requireSession()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw BridgeFailure("capture_failed", "Cannot encode the captured window.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 16 * 1024 * 1024 else {
            throw BridgeFailure("capture_failed", "PNG encoding failed or the capture exceeds 16 MiB.")
        }
        return ["screenshot_base64": (data as Data).base64EncodedString(), "image_width": image.width, "image_height": image.height]
    }

    func execute(_ request: NativeRequest) async throws -> [String: Any] {
        if request.command == "status" { return status() }
        try requireSession()
        if request.command == "list_apps" {
            let apps: [[String: Any]] = NSWorkspace.shared.runningApplications.compactMap { app in
                guard let bundleID = app.bundleIdentifier, (try? policy.authorize(bundleID)) != nil else { return nil }
                return ["bundle_id": bundleID, "name": app.localizedName ?? bundleID, "pid": app.processIdentifier]
            }
            return ["apps": apps.sorted { ($0["bundle_id"] as? String ?? "") < ($1["bundle_id"] as? String ?? "") }]
        }
        guard let bundleID = request.bundleId else { throw BridgeFailure("invalid_request", "bundle_id is required.") }
        try policy.authorize(bundleID)
        if request.command == "open_app" {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw BridgeFailure("app_not_installed", "No installed application has this bundle ID.")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try requireSession()
            return ["bundle_id": bundleID, "pid": app.processIdentifier]
        }
        let app = try application(bundleID)
        if request.command == "list_windows" {
            let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let windows: [[String: Any]] = entries.compactMap { entry in
                guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                      (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                      let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                      let frame = try? window(windowID, app: app) else { return nil }
                return ["window_id": windowID, "title": entry[kCGWindowName as String] as? String ?? "", "width": frame.width, "height": frame.height]
            }
            return ["windows": windows]
        }
        guard let windowID = request.windowId else { throw BridgeFailure("invalid_request", "window_id is required.") }
        let frame = try window(windowID, app: app)
        if request.command == "snapshot" {
            try requireAccessibility()
            let target = try matchingAXWindow(app: app, frame: frame)
            var result = inspect(target, frame: frame)
            result.merge(["bundle_id": bundleID, "window_id": windowID, "width": frame.width, "height": frame.height, "coordinate_space": "window-relative logical points"]) { _, latest in latest }
            if request.includeScreenshot ?? true { result.merge(try await screenshot(windowID: windowID, app: app)) { _, latest in latest } }
            try requireSession()
            return result
        }
        let target = try await focus(app: app, windowID: windowID, frame: frame)
        guard CGPreflightPostEventAccess() else {
            throw BridgeFailure("input_permission_required", "macOS has not granted synthetic input access to Intel Computer Use. Enable its Accessibility permission and restart the connection.")
        }
        switch request.command {
        case "click", "scroll":
            guard let horizontal = request.x, let vertical = request.y else { throw BridgeFailure("invalid_coordinate", "x and y are required.") }
            try WindowPoint(x: horizontal, y: vertical).validate(width: frame.width, height: frame.height)
            let point = CGPoint(x: frame.minX + horizontal, y: frame.minY + vertical)
            if request.command == "click" {
                let button = request.button ?? "left"
                let count = request.clickCount ?? 1
                guard ["left", "right"].contains(button), (1...2).contains(count) else { throw BridgeFailure("invalid_click", "Invalid click parameters.") }
                for clickIndex in 1...count {
                    let right = button == "right"
                    guard let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left),
                          let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left) else { throw BridgeFailure("input_failed", "Cannot create mouse events.") }
                    down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
                    up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
                    try checkPoint(point, app: app, target: target)
                    try checkFocus(app: app, target: target, windowID: windowID, frame: frame)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            } else {
                let amount = request.pixels ?? 400
                guard (1...2000).contains(amount), let direction = request.direction, ["up", "down", "left", "right"].contains(direction) else { throw BridgeFailure("invalid_scroll", "Invalid scroll parameters.") }
                let verticalAmount = direction == "up" ? amount : direction == "down" ? -amount : 0
                let horizontalAmount = direction == "left" ? amount : direction == "right" ? -amount : 0
                guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(verticalAmount), wheel2: Int32(horizontalAmount), wheel3: 0) else { throw BridgeFailure("input_failed", "Cannot create a scroll event.") }
                event.location = point
                try checkPoint(point, app: app, target: target)
                try checkFocus(app: app, target: target, windowID: windowID, frame: frame)
                event.post(tap: .cghidEventTap)
            }
        case "type_text":
            guard let text = request.text, !text.isEmpty, text.count <= 16384 else { throw BridgeFailure("invalid_text", "Text must contain 1 to 16384 characters.") }
            let units = Array(text.utf16)
            var start = 0
            while start < units.count {
                var end = min(start + 20, units.count)
                if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
                try checkFocus(app: app, target: target, windowID: windowID, frame: frame)
                let chunk = Array(units[start..<end])
                try sendKey(app: app, keyCode: 0, flags: [], unicode: chunk)
                start = end
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        case "press_key":
            let chord = try KeyChord.parse(request.key ?? "")
            var flags = CGEventFlags()
            if chord.modifiers.contains(.command) { flags.insert(.maskCommand) }
            if chord.modifiers.contains(.control) { flags.insert(.maskControl) }
            if chord.modifiers.contains(.shift) { flags.insert(.maskShift) }
            if chord.modifiers.contains(.option) { flags.insert(.maskAlternate) }
            try checkFocus(app: app, target: target, windowID: windowID, frame: frame)
            try sendKey(app: app, keyCode: chord.keyCode, flags: flags, unicode: nil)
        default:
            throw BridgeFailure("unknown_command", "Unknown native command.")
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try requireSession()
        return ["performed": request.command, "bundle_id": bundleID, "window_id": windowID, "next_step": "Take a fresh snapshot to verify the result."]
    }

    func sendKey(app: NSRunningApplication, keyCode: UInt16, flags: CGEventFlags, unicode: [UInt16]?) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw BridgeFailure("input_failed", "Cannot create keyboard events.")
        }
        down.flags = flags
        up.flags = flags
        if let unicode = unicode {
            down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            up.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

@main
struct NativeHelper {
    @MainActor
    static func main() async {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--setup") {
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            _ = CGRequestScreenCaptureAccess()
            print("Grant Accessibility and Screen Recording to Intel Computer Use, then restart the MCP connection.")
            return
        }
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 1024 * 1024 else { throw BridgeFailure("invalid_request", "Request exceeds 1 MiB.") }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let request = try decoder.decode(NativeRequest.self, from: data)
            let result = try await DesktopController(deadlineUnixMilliseconds: request.deadlineUnixMilliseconds).execute(request)
            write(["ok": true, "data": result])
        } catch let failure as BridgeFailure {
            write(["ok": false, "error": ["code": failure.code, "message": failure.message]])
        } catch {
            write(["ok": false, "error": ["code": "native_error", "message": error.localizedDescription]])
        }
    }

    static func write(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
