import AppKit
import ApplicationServices
import Observation

/// Tracks the two privacy permissions Grab needs and nudges the user to grant them.
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    /// Screen Recording was granted while we were running; macOS wants a relaunch.
    private(set) var screenRecordingNeedsRelaunch = false

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var requestedScreenRecording = false

    /// Watches for changes only while something is still missing; once both are
    /// granted there's nothing to poll (Grab re-checks when you hold ⌥ or open a window).
    func startMonitoring() {
        timer?.invalidate()
        timer = nil
        guard !(accessibility && screenRecording) else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            if self.accessibility && self.screenRecording {
                self.timer?.invalidate()
                self.timer = nil
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        guard ax != accessibility || sr != screenRecording else { return }
        if !(ax && sr) && timer == nil { DispatchQueue.main.async { [weak self] in self?.startMonitoring() } }
        accessibility = ax
        if sr != screenRecording {
            screenRecording = sr
            if sr { screenRecordingNeedsRelaunch = false }
        }
        onChange?()
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        open("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        if !requestedScreenRecording {
            requestedScreenRecording = true
            // Shows the system prompt (once) and adds Grab to the list.
            if CGRequestScreenCaptureAccess() {
                refresh()
                return
            }
        }
        screenRecordingNeedsRelaunch = true
        open("Privacy_ScreenCapture")
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
