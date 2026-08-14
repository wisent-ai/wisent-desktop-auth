import ApplicationServices
import AVFoundation
import Foundation
import Security
import UserNotifications

public enum WisentPermission: String, CaseIterable, Codable, Sendable {
    case sharedIdentityKeychain
    case accessibility
    case screenRecording
    case inputMonitoring
    case camera
    case microphone
    case notifications
    case fullDiskAccess
}

public enum WisentPermissionState: String, Codable, Sendable {
    case granted
    case notGranted
    case notDetermined
    case restricted
    case unavailable
    case misconfigured
    case unknown
}

public struct WisentPermissionSnapshot: Codable, Equatable, Sendable {
    public let permission: WisentPermission
    public let state: WisentPermissionState
    public let detail: String

    public init(permission: WisentPermission, state: WisentPermissionState, detail: String) {
        self.permission = permission
        self.state = state
        self.detail = detail
    }
}

public struct WisentPermissionReport: Codable, Equatable, Sendable {
    public let bundleIdentifier: String
    public let required: [WisentPermissionSnapshot]

    public var allRequiredGranted: Bool {
        required.allSatisfy { $0.state == .granted }
    }

    public init(bundleIdentifier: String, required: [WisentPermissionSnapshot]) {
        self.bundleIdentifier = bundleIdentifier
        self.required = required
    }
}

/// Read-only macOS privacy diagnostics.
///
/// This API deliberately exposes no request operation. Calling it never opens a
/// system consent dialog; the host application decides when an explicit user
/// action should enter macOS's permission flow.
public enum WisentPermissionCenter {
    public static let sharedIdentityAccessGroupSuffix = ".ai.wisent.identity"

    public static func report(
        required permissions: [WisentPermission]
    ) async -> WisentPermissionReport {
        var snapshots: [WisentPermissionSnapshot] = []
        snapshots.reserveCapacity(permissions.count)
        for permission in permissions {
            snapshots.append(await snapshot(for: permission))
        }
        return WisentPermissionReport(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            required: snapshots
        )
    }

    public static func snapshot(for permission: WisentPermission) async -> WisentPermissionSnapshot {
        switch permission {
        case .sharedIdentityKeychain:
            let granted = sharedIdentityAccessGroup() != nil
            return WisentPermissionSnapshot(
                permission: permission,
                state: granted ? .granted : .notGranted,
                detail: granted
                    ? "The signed host carries the shared Wisent identity Keychain access group."
                    : "The host has no shared Wisent identity Keychain access-group entitlement."
            )
        case .accessibility:
            return binarySnapshot(
                permission,
                granted: AXIsProcessTrusted(),
                grantedDetail: "Accessibility is granted to this signed application identity.",
                missingDetail: "Accessibility is not granted to this signed application identity."
            )
        case .screenRecording:
            return binarySnapshot(
                permission,
                granted: CGPreflightScreenCaptureAccess(),
                grantedDetail: "Screen Recording is granted to this signed application identity.",
                missingDetail: "Screen Recording is not granted to this signed application identity."
            )
        case .inputMonitoring:
            return binarySnapshot(
                permission,
                granted: CGPreflightListenEventAccess(),
                grantedDetail: "Input Monitoring is granted to this signed application identity.",
                missingDetail: "Input Monitoring is not granted to this signed application identity."
            )
        case .camera:
            return captureSnapshot(
                permission,
                mediaType: .video,
                usageDescriptionKey: "NSCameraUsageDescription"
            )
        case .microphone:
            return captureSnapshot(
                permission,
                mediaType: .audio,
                usageDescriptionKey: "NSMicrophoneUsageDescription"
            )
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let state: WisentPermissionState
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                state = .granted
            case .denied:
                state = .notGranted
            case .notDetermined:
                state = .notDetermined
            @unknown default:
                state = .unknown
            }
            return WisentPermissionSnapshot(
                permission: permission,
                state: state,
                detail: "Notification authorization is \(settings.authorizationStatus.rawValue)."
            )
        case .fullDiskAccess:
            return WisentPermissionSnapshot(
                permission: permission,
                state: .unknown,
                detail: "macOS exposes no public, non-probing Full Disk Access status API."
            )
        }
    }

    public static func sharedIdentityAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                  task,
                  "keychain-access-groups" as CFString,
                  nil
              ) as? [String] else {
            return nil
        }
        return groups.first { $0.hasSuffix(sharedIdentityAccessGroupSuffix) }
    }

    private static func binarySnapshot(
        _ permission: WisentPermission,
        granted: Bool,
        grantedDetail: String,
        missingDetail: String
    ) -> WisentPermissionSnapshot {
        WisentPermissionSnapshot(
            permission: permission,
            state: granted ? .granted : .notGranted,
            detail: granted ? grantedDetail : missingDetail
        )
    }

    private static func captureSnapshot(
        _ permission: WisentPermission,
        mediaType: AVMediaType,
        usageDescriptionKey: String
    ) -> WisentPermissionSnapshot {
        guard Bundle.main.object(forInfoDictionaryKey: usageDescriptionKey) is String else {
            return WisentPermissionSnapshot(
                permission: permission,
                state: .misconfigured,
                detail: "The host is missing \(usageDescriptionKey)."
            )
        }

        let state: WisentPermissionState
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            state = .granted
        case .denied:
            state = .notGranted
        case .notDetermined:
            state = .notDetermined
        case .restricted:
            state = .restricted
        @unknown default:
            state = .unknown
        }
        return WisentPermissionSnapshot(
            permission: permission,
            state: state,
            detail: "The host's \(permission.rawValue) authorization is \(state.rawValue)."
        )
    }
}
