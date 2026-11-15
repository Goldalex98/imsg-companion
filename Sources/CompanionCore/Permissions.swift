import Contacts
import Foundation

/// Read-only checks for the status report. None of them asks for access.
public enum Permissions {
    public static func contacts() -> PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    /// Opens chat.db read-only and closes it at once: macOS refuses the open without Full Disk Access.
    public static func fullDiskAccess(path: String) -> PermissionState {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }

    /// From the last preflight or send script: -1743 is Automation refused; any script that ran means granted.
    public static func automation(from result: ScriptResult?) -> PermissionState {
        switch result {
        case nil, .failedToStart?: .unknown
        case .notSubmitted(code: -1743)?: .denied
        default: .granted
        }
    }
}

/// Remembers the last script result, so the status can say whether Automation → Messages is granted.
public final class LastScriptResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScriptResult?
    public init() {}
    public var value: ScriptResult? { lock.withLock { stored } }
    func set(_ result: ScriptResult) { lock.withLock { stored = result } }
}

public struct ObservedRunner: CompanionScriptRunning {
    private let base: any CompanionScriptRunning
    private let last: LastScriptResult
    public init(_ base: any CompanionScriptRunning, last: LastScriptResult) { self.base = base; self.last = last }
    public func run(source: String, arguments: [String], timeout: TimeInterval) async -> ScriptRunOutput {
        let output = await base.run(source: source, arguments: arguments, timeout: timeout)
        last.set(CompanionSendScript.result(of: output))
        return output
    }
}
