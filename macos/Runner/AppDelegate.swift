import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    super.applicationWillFinishLaunching(notification)

    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    let existingApplication = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).first { application in
      application.processIdentifier != currentProcessIdentifier
    }

    guard let existingApplication else { return }
    existingApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    NSApp.terminate(nil)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
