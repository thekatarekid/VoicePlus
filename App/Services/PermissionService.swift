import AppKit
import AVFoundation
import ApplicationServices
import Foundation
import Shared

/// Abstracts the three system checks so the orchestrator and tests don't touch TCC directly.
public protocol PermissionChecking: AnyObject {
    func status(of permission: Permission) -> PermissionStatus
    /// Triggers the system prompt (where the OS offers one). Completion carries the refreshed status.
    func request(_ permission: Permission, completion: @escaping (PermissionStatus) -> Void)
}

public extension PermissionChecking {
    func matrix() -> PermissionMatrix {
        Permission.allCases.reduce(into: [:]) { $0[$1] = status(of: $1) }
    }
}

/// Real TCC-backed checks: AVCaptureDevice (mic), AXIsProcessTrustedWithOptions (accessibility),
/// CGPreflightListenEventAccess / CGRequestListenEventAccess (input monitoring).
public final class SystemPermissionChecker: PermissionChecking {
    public init() {}

    public func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .inputMonitoring:
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        }
    }

    public func request(_ permission: Permission, completion: @escaping (PermissionStatus) -> Void) {
        switch permission {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted ? .granted : .denied) }
            }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            completion(trusted ? .granted : .notDetermined)
        case .inputMonitoring:
            let granted = CGRequestListenEventAccess()
            completion(granted ? .granted : .notDetermined)
        }
    }
}

/// In-memory checker for tests and `swift run` demos without TCC.
public final class MockPermissionChecker: PermissionChecking {
    public var statuses: PermissionMatrix
    public var grantOnRequest: Set<Permission>
    public private(set) var requested: [Permission] = []

    public init(statuses: PermissionMatrix = [:], grantOnRequest: Set<Permission> = []) {
        self.statuses = statuses
        self.grantOnRequest = grantOnRequest
    }

    public func status(of permission: Permission) -> PermissionStatus { statuses[permission] ?? .notDetermined }

    public func request(_ permission: Permission, completion: @escaping (PermissionStatus) -> Void) {
        requested.append(permission)
        let result: PermissionStatus = grantOnRequest.contains(permission) ? .granted : .denied
        statuses[permission] = result
        completion(result)
    }
}

/// Walks the matrix: pre-prompt → system prompt → verify, one permission at a time (T5).
/// UI is injected (`presentPrePrompt`) so the flow is testable headless.
public final class PermissionOrchestrator {
    public enum PrePromptChoice { case proceed, skip }

    public let checker: PermissionChecking
    public var presentPrePrompt: (Permission, @escaping (PrePromptChoice) -> Void) -> Void
    public var openSettings: (Permission) -> Void
    public private(set) var log: [String] = []

    public init(checker: PermissionChecking,
                presentPrePrompt: @escaping (Permission, @escaping (PrePromptChoice) -> Void) -> Void,
                openSettings: @escaping (Permission) -> Void = { NSWorkspace.shared.open($0.settingsURL) }) {
        self.checker = checker
        self.presentPrePrompt = presentPrePrompt
        self.openSettings = openSettings
    }

    public var matrix: PermissionMatrix { checker.matrix() }

    /// Runs until all granted, or the user skips / a permission is denied. Completion gets the final matrix.
    public func run(completion: @escaping (PermissionMatrix) -> Void) {
        step(skipped: [], completion: completion)
    }

    private func step(skipped: Set<Permission>, completion: @escaping (PermissionMatrix) -> Void) {
        var current = matrix
        for p in skipped { current[p] = .granted } // treated as handled for this run; re-verified on next run
        switch PermissionPlanner.nextStep(current) {
        case .allGranted:
            log.append(skipped.isEmpty ? "all granted" : "done (skipped: \(skipped.map(\.rawValue).sorted()))")
            completion(matrix)
        case .openSettings(let permission):
            log.append("settings:\(permission.rawValue)")
            openSettings(permission)
            completion(matrix)
        case .prePrompt(let permission):
            log.append("preprompt:\(permission.rawValue)")
            presentPrePrompt(permission) { [weak self] choice in
                guard let self else { return }
                switch choice {
                case .skip:
                    self.log.append("skip:\(permission.rawValue)")
                    self.step(skipped: skipped.union([permission]), completion: completion)
                case .proceed:
                    self.checker.request(permission) { status in
                        self.log.append("verify:\(permission.rawValue)=\(status.rawValue)")
                        if status == .granted {
                            self.step(skipped: skipped, completion: completion)
                        } else {
                            // Denied (or AX/IM not yet toggled): send to Settings, stop here; caller re-verifies later.
                            self.log.append("settings:\(permission.rawValue)")
                            self.openSettings(permission)
                            completion(self.matrix)
                        }
                    }
                }
            }
        }
    }
}
