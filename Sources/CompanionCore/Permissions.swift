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
