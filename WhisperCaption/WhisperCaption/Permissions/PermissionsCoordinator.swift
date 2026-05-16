import AVFoundation
import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// macOS gives us two privacy gates we have to pass before captures work:
///
/// 1. Microphone (`NSMicrophoneUsageDescription`) — granted via the
///    AVCaptureDevice prompt.
/// 2. Screen Recording — granted via the system TCC pane. There is NO
///    programmatic "request" API; the prompt is triggered the first time
///    we touch ScreenCaptureKit (e.g. SCShareableContent.current). After
///    the user grants it, **the app must be relaunched** for the new TCC
///    entry to take effect.
///
/// This namespace centralizes status checks and the deep-links into
/// System Settings so the UI can guide the user when something is denied.
enum PermissionStatus: Sendable {
    case granted
    case denied
    case undetermined
}

enum PermissionsCoordinator {

    // MARK: - Microphone

    static func micStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:               return .granted
        case .denied, .restricted:      return .denied
        case .notDetermined:            return .undetermined
        @unknown default:               return .undetermined
        }
    }

    static func requestMic() async -> PermissionStatus {
        if micStatus() == .granted { return .granted }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    // MARK: - Screen Recording

    /// Result type carries the real SCK error so the UI can surface details
    /// instead of a flat "denied".
    struct ScreenRecordingProbe: Sendable {
        let status: PermissionStatus
        let underlyingError: String?
    }

    /// On macOS 15+ Apple split the privacy gate into "Screen & System
    /// Audio Recording", and the legacy `CGPreflightScreenCaptureAccess()`
    /// doesn't reliably reflect that pane's state. The honest check is to
    /// actually try `SCShareableContent` — if it returns content we have
    /// access; if it throws, we don't. The thrown error often tells us
    /// *why* (e.g. TCC stale, no displays, ScreenCaptureKit error -3801),
    /// which is gold for diagnosing why a checkbox in Settings doesn't
    /// translate to a real grant.
    static func probeScreenRecording() async -> ScreenRecordingProbe {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return ScreenRecordingProbe(status: .granted, underlyingError: nil)
        } catch {
            let nsError = error as NSError
            let detail = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
            return ScreenRecordingProbe(status: .denied, underlyingError: detail)
        }
    }

    static func screenRecordingStatus() async -> PermissionStatus {
        await probeScreenRecording().status
    }

    /// Try ScreenCaptureKit; if denied, trigger the TCC prompt and try again.
    /// First grant still requires an app restart on macOS — that's a TCC quirk,
    /// not something we can work around in-process.
    static func requestScreenRecording() async -> ScreenRecordingProbe {
        let first = await probeScreenRecording()
        if first.status == .granted { return first }

        // CGRequestScreenCaptureAccess returns immediately; the prompt is shown
        // by the next ScreenCaptureKit call.
        _ = CGRequestScreenCaptureAccess()

        try? await Task.sleep(nanoseconds: 500_000_000)
        return await probeScreenRecording()
    }

    // MARK: - System Settings deep links

    enum Pane: Sendable {
        case microphone
        case screenRecording

        fileprivate var url: URL {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    static func openSettings(for pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }

    // MARK: - TCC rescue text

    /// Diagnostic the in-app error pane shows when Screen Recording probes
    /// keep failing despite the toggle being on. Stale `cdhash` entries
    /// after rebuilds are the usual cause.
    static let tccResetRescueText: String =
        """
        Open Terminal and run:
            tccutil reset ScreenCapture albond.WhisperCaption && tccutil reset Microphone albond.WhisperCaption
        Then quit WhisperCaption (⌘Q), relaunch, press Start, accept the fresh prompt, quit again, relaunch.
        """
}
