import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int(CommandLine.arguments[1]) else { exit(2) }
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int) == pid {
    let number = window[kCGWindowNumber as String] ?? "?"
    let layer = window[kCGWindowLayer as String] ?? "?"
    let visible = window[kCGWindowIsOnscreen as String] ?? "?"
    let bounds = window[kCGWindowBounds as String] ?? "?"
    print("window=\(number) layer=\(layer) onscreen=\(visible) bounds=\(bounds)")
}
