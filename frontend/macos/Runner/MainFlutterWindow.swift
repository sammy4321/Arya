import Cocoa
import FlutterMacOS
import file_selector_macos

class MainFlutterWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  private func clearBackgroundsRecursively(_ view: NSView) {
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.clear.cgColor
    for subview in view.subviews {
      clearBackgroundsRecursively(subview)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame

    // Required for truly transparent desktop overlays.
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    self.hidesOnDeactivate = false
    self.level = .floating
    self.styleMask.remove(.nonactivatingPanel)
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor

    self.contentViewController = flutterViewController
    if let contentView = self.contentView {
      clearBackgroundsRecursively(contentView)
    }

    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
