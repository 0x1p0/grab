import AppKit

// A helper that quits mid-write must not take Grab down with it (EPIPE instead of SIGPIPE).
signal(SIGPIPE, SIG_IGN)

// The helper that runs OCR and other Vision work (see VisionService).
if CommandLine.arguments.contains("--vision-worker") { VisionWorker.run() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
