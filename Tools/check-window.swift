import AppKit
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    if owner.contains("GoodThingPet") || owner.contains("好事") || owner.contains("SunPet") {
        print(window)
    }
}
