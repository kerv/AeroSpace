@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        let succeeded = nativeFocused?.focusWindow() ?? true
        // Only advance the cache if focus was successfully applied. If focusWindow() returned
        // false (e.g. window is still in macosMinimizedWindowsContainer mid-deminiaturize),
        // leave lastKnownNativeFocusedWindowId stale so the next refresh retries.
        if succeeded {
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        }
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
