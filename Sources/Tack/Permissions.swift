import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import ServiceManagement

enum PermissionKind: CaseIterable {
    case microphone
    case accessibility
    case screenRecording
}

enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

enum Permissions {
    static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            case .denied, .restricted: .denied
            @unknown default: .denied
            }
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
    }

    static func request(_ kind: PermissionKind) {
        switch kind {
        case .microphone:
            if status(.microphone) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else {
                openSystemSettings(.microphone)
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSystemSettings(.accessibility) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSystemSettings(.screenRecording) }
        }
    }

    static var allGranted: Bool {
        PermissionKind.allCases.allSatisfy { status($0) == .granted }
    }

    static func openSystemSettings(_ kind: PermissionKind) {
        let anchor = switch kind {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Tack: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}
