import AppKit
import LatchMacUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = LatchApplicationDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
