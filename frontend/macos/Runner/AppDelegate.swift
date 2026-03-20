import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private let clipboardChannelName = "arya/clipboard_files"

  override func applicationDidFinishLaunching(_ notification: Notification) {
    if let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let registrar = flutterViewController.registrar(forPlugin: "AryaClipboardFilePlugin")
      let clipboardChannel = FlutterMethodChannel(
        name: clipboardChannelName,
        binaryMessenger: registrar.messenger
      )

      clipboardChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "getClipboardFilePaths":
          result(Self.clipboardFilePaths())
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    super.applicationDidFinishLaunching(notification)
  }

  private static func clipboardFilePaths() -> [String] {
    let pasteboard = NSPasteboard.general
    var paths: [String] = []
    var seen: Set<String> = []

    if let items = pasteboard.pasteboardItems {
      for item in items {
        if let fileURLString = item.string(forType: .fileURL),
           let fileURL = URL(string: fileURLString),
           fileURL.isFileURL {
          let path = fileURL.path
          if !seen.contains(path) {
            seen.insert(path)
            paths.append(path)
          }
        }
      }
    }

    if paths.isEmpty {
      let classes: [AnyClass] = [NSURL.self]
      let options: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
      ]
      if let urls = pasteboard.readObjects(forClasses: classes, options: options) as? [URL] {
        for url in urls where url.isFileURL {
          let path = url.path
          if !seen.contains(path) {
            seen.insert(path)
            paths.append(path)
          }
        }
      }
    }

    return paths
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
