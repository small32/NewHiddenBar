//
//  HiddenItemsPanel.swift
//  NewHiddenBar
//
//  Popup panel that shows snapshots of the hidden menu bar items and forwards
//  clicks to them without revealing the whole hidden section.
//
//  Click forwarding follows the approach used by Ice/Thaw: instead of
//  expanding the collapse separator (which flashes every hidden icon in the
//  real menu bar), a single item is dragged out of the parked overflow area
//  next to the collapse button with synthetic Cmd+drag events, clicked there
//  (so its menu opens right where the panel was), and dragged back once its
//  menu closes.
//
//  Requires: Screen Recording permission (to capture other apps' menu bar
//  items) and Accessibility permission (to synthesize events).
//

import AppKit
import ApplicationServices

// MARK: - HiddenMenuItem

/// A single menu bar item that has been pushed off-screen by the collapse separator.
struct HiddenMenuItem {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String?
    let title: String?
    let offScreenFrame: CGRect
}

// MARK: - SkyLight capture

/// Loads SkyLight's SLWindowListCreateImageFromArray so off-screen status
/// item windows can be captured directly. CGWindowListCreateImage returns
/// nil for windows parked at large negative x on modern macOS; ScreenCaptureKit
/// rejects them too (-3812). SkyLight is the only public-ish API that works.
enum SkyLightCapture {
    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    }()

    private static let createImageFromArray: (@convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?)? = {
        guard let handle, let sym = dlsym(handle, "SLWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (CGRect, CFArray, CGWindowImageOption) -> Unmanaged<CGImage>?).self)
    }()

    /// Captures the minimum rectangle enclosing the given windows. Returns nil
    /// when SkyLight is unavailable or the capture fails.
    ///
    /// The array elements must be the window IDs as raw bit patterns (the
    /// same representation the CGWindowList APIs use). Wrapping them in
    /// NSNumber makes SkyLight return nil.
    static func capture(windowIDs: [CGWindowID]) -> CGImage? {
        guard let createImageFromArray, !windowIDs.isEmpty else { return nil }
        var pointers: [UnsafeRawPointer?] = windowIDs.compactMap { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard !pointers.isEmpty else { return nil }
        var callbacks = CFArrayCallBacks(version: 0, retain: nil, release: nil, copyDescription: nil, equal: nil)
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, &callbacks) else { return nil }
        return createImageFromArray(.null, array, [.boundsIgnoreFraming, .bestResolution])?.takeRetainedValue()
    }
}

// MARK: - CGEvent helpers

private extension CGEvent {
    /// Stamps the target process on the event so the window server routes it
    /// to the item's owning app (Ice/Thaw's setTargetPID).
    func setTargetPID(_ pid: pid_t) {
        setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
    }
}

// MARK: - HiddenItemsPanelController

/// Writes a diagnostic line to /tmp/NewHiddenBar-debug.log (app sandbox is off).
func hbDebugLog(_ message: String) {
    let line = "[NewHiddenBar \(Date())] \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/NewHiddenBar-debug.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: "/tmp/NewHiddenBar-debug.log"),
           let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }
}

final class HiddenItemsPanelController: NSObject {

    private weak var statusBarController: StatusBarController?

    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var anchorFrame = CGRect.zero

    var isVisible: Bool { panel?.isVisible ?? false }

    init(statusBarController: StatusBarController) {
        self.statusBarController = statusBarController
        super.init()
    }

    // MARK: - Show / Dismiss

    func toggle(anchorFrame: CGRect) {
        if isVisible {
            dismiss()
        } else {
            show(anchorFrame: anchorFrame)
        }
    }

    func dismiss() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func show(anchorFrame: CGRect) {
        self.anchorFrame = anchorFrame
        dismiss()

        var hasScreenAccess = CGPreflightScreenCaptureAccess()
        if !hasScreenAccess {
            // Trigger the system authorization sheet directly (ad-hoc signed
            // builds change their cdhash on every rebuild, so TCC treats each
            // build as a new app and the old grant lapses).
            _ = CGRequestScreenCaptureAccess()
            hasScreenAccess = CGPreflightScreenCaptureAccess()
        }
        hbDebugLog("show() screenCaptureAccess=\(hasScreenAccess)")

        guard hasScreenAccess else {
            showMessagePanel(
                anchorFrame: anchorFrame,
                title: "需要屏幕录制权限",
                subtitle: "已为你弹出系统授权框，请点击「允许」。若未出现，请到 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 NewHiddenBar 后重试。",
                buttonTitle: "打开系统设置",
                buttonURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            )
            return
        }

        let items = Self.hiddenMenuItems()
        hbDebugLog("show() hiddenMenuItems count=\(items.count)")

        guard !items.isEmpty else {
            showMessagePanel(
                anchorFrame: anchorFrame,
                title: "没有检测到隐藏的图标",
                subtitle: "请先在菜单栏按住 ⌘ 拖动要隐藏的图标，把它移到分隔条右侧，然后再点击折叠按钮。",
                buttonTitle: nil,
                buttonURL: nil
            )
            return
        }

        // Try to capture the off-screen windows directly — that way there is
        // no flicker of items reappearing in the real menu bar. SkyLight's
        // private API is the only one that can capture windows parked at
        // large negative x; fall back to CGWindowListCreateImage, then to a
        // temporary reveal if both fail.
        var directCaptured: [(HiddenMenuItem, NSImage)] = []
        if let composite = SkyLightCapture.capture(windowIDs: items.map { $0.windowID }) {
            hbDebugLog("show() skylight composite \(composite.width)x\(composite.height)px for \(items.count) windows")
            // The composite is the bounding box of all windows in CG coordinates
            // (top-left origin). Crop each item out at its own frame.
            let union = items.reduce(CGRect.null) { $0.union($1.offScreenFrame) }
            let scale = CGFloat(composite.width) / max(union.width, 1)
            for item in items {
                let crop = CGRect(
                    x: (item.offScreenFrame.minX - union.minX) * scale,
                    y: (item.offScreenFrame.minY - union.minY) * scale,
                    width: item.offScreenFrame.width * scale,
                    height: item.offScreenFrame.height * scale
                )
                guard crop.minX >= 0, crop.minY >= 0,
                      crop.maxX <= CGFloat(composite.width), crop.maxY <= CGFloat(composite.height),
                      let cg = composite.cropping(to: crop)
                else { continue }
                let size = NSSize(width: item.offScreenFrame.width, height: item.offScreenFrame.height)
                directCaptured.append((item, NSImage(cgImage: cg, size: size)))
            }
        }
        if directCaptured.isEmpty {
            directCaptured = items.compactMap { item -> (HiddenMenuItem, NSImage)? in
                guard let image = captureImage(windowID: item.windowID) else { return nil }
                return (item, image)
            }
        }
        hbDebugLog("show() direct offscreen capture=\(directCaptured.count)/\(items.count)")

        if !directCaptured.isEmpty {
            buildPanel(captured: directCaptured, anchorFrame: anchorFrame)
            return
        }

        // Fallback: briefly reveal the hidden items so their windows can be seen,
        // capture them, then hide again before showing the panel.
        statusBarController?.tempExpandForClick()
        hbDebugLog("show() fallback tempExpandForClick called")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }

            var captured: [(HiddenMenuItem, NSImage)] = []
            for item in items {
                guard
                    let _ = Self.currentFrame(for: item),
                    let image = self.captureImage(windowID: item.windowID)
                else { continue }
                captured.append((item, image))
            }

            self.statusBarController?.restoreCollapse()
            hbDebugLog("show() fallback captured \(captured.count)/\(items.count), restoreCollapse called")

            guard !captured.isEmpty else {
                self.showMessagePanel(
                    anchorFrame: anchorFrame,
                    title: "无法获取隐藏的图标",
                    subtitle: "未能截取到被隐藏的菜单栏图标，请确认屏幕录制权限已开启后重试。",
                    buttonTitle: "打开系统设置",
                    buttonURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                )
                return
            }

            self.buildPanel(captured: captured, anchorFrame: anchorFrame)
        }
    }

    // MARK: - Enumerate hidden items

    /// Returns the menu bar items that are currently hidden by the collapse separator.
    /// Uses only public CGWindowList APIs.
    ///
    /// When the collapse separator is stretched the overflowing menu bar
    /// items are pushed off-screen (which side depends on the running macOS
    /// and the user's bar layout), so every status-level window whose frame
    /// is completely outside the visible screens is treated as hidden —
    /// no single-direction filtering.
    static func hiddenMenuItems() -> [HiddenMenuItem] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            hbDebugLog("hiddenMenuItems() CGWindowList nil")
            return []
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let visible = visibleScreenBounds
        let targetLayer = Int(kCGStatusWindowLevel)

        var layer25Count = 0
        var offscreen25Count = 0
        var nonLayerLayers = Set<Int>()
        var result: [HiddenMenuItem] = []

        for info in list {
            guard
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            else { continue }

            if layer != targetLayer {
                nonLayerLayers.insert(layer)
                continue
            }
            layer25Count += 1

            guard
                let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                ownerPID != myPID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            if !frame.intersects(visible) {
                offscreen25Count += 1
                if frame.width >= 8, frame.height >= 8 {
                    let ownerName = info[kCGWindowOwnerName as String] as? String
                    if ownerName == "Window Server" { continue }
                    result.append(HiddenMenuItem(
                        windowID: windowID,
                        ownerPID: ownerPID,
                        ownerName: ownerName,
                        title: info[kCGWindowName as String] as? String,
                        offScreenFrame: frame
                    ))
                }
            }
        }

        let sampleLayers = nonLayerLayers.sorted().prefix(10).map(String.init).joined(separator: ",")
        hbDebugLog("hiddenMenuItems() total=\(list.count) targetLayer=\(targetLayer) layer25=\(layer25Count) offscreen25=\(offscreen25Count) kept=\(result.count) otherLayers=[\(sampleLayers)]")
        return result.sorted { $0.offScreenFrame.minX < $1.offScreenFrame.minX }
    }

    /// Returns the most recent frame of the given item.
    static func currentFrame(for item: HiddenMenuItem) -> CGRect? {
        currentFrame(forID: item.windowID)
    }

    /// Returns the current frame of the window with the given ID.
    static func currentFrame(forID targetID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard
                let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                windowID == targetID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            return frame
        }
        return nil
    }

    private static var visibleScreenBounds: CGRect {
        var union = CGRect.null
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        CGGetActiveDisplayList(32, &displays, &displayCount)
        for index in 0..<Int(displayCount) {
            union = union.union(CGDisplayBounds(displays[index]))
        }
        return union
    }

    // MARK: - Capture

    private func captureImage(windowID: CGWindowID) -> NSImage? {
        guard
            let cgImage = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            )
        else { return nil }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return NSImage(cgImage: cgImage, size: size)
    }

    // MARK: - Panel UI

    private func buildPanel(captured: [(HiddenMenuItem, NSImage)], anchorFrame: CGRect) {
        let content = HiddenItemsPanelContentView(items: captured)
        content.onClickItem = { [weak self] item, button in
            self?.handleClick(on: item, button: button)
        }

        let size = content.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel: panel, contentView: content)
        positionPanel(panel, anchorFrame: anchorFrame)
        panel.orderFrontRegardless()
        self.panel = panel
        installDismissMonitor()
        hbDebugLog("buildPanel() shown frame=\(panel.frame) size=\(size) items=\(captured.count)")
    }

    private func showMessagePanel(anchorFrame: CGRect, title: String, subtitle: String, buttonTitle: String?, buttonURL: URL?) {
        let content = HiddenItemsMessageView(title: title, subtitle: subtitle, buttonTitle: buttonTitle, buttonURL: buttonURL)
        let size = content.panelSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel: panel, contentView: content)
        positionPanel(panel, anchorFrame: anchorFrame)
        panel.orderFrontRegardless()
        self.panel = panel
        installDismissMonitor()
        hbDebugLog("showMessagePanel() \(title) frame=\(panel.frame)")
    }

    private func configure(panel: NSPanel, contentView: NSView) {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.contentView = contentView
    }

    private func positionPanel(_ panel: NSPanel, anchorFrame: CGRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorFrame) } ?? NSScreen.main
        let frame = panel.frame
        var x = anchorFrame.midX - frame.width / 2
        if let screen {
            x = min(max(x, screen.frame.minX + 6), screen.frame.maxX - frame.width - 6)
        }
        let y = anchorFrame.minY - frame.height - 10
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installDismissMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let location = NSEvent.mouseLocation
            if let panel = self.panel, panel.frame.contains(location) { return }
            if self.anchorFrame.contains(location) { return }
            hbDebugLog("dismiss-by-global-click at=\(location) panel=\(String(describing: self.panel?.frame)) anchor=\(self.anchorFrame)")
            self.dismiss()
        }
    }

    // MARK: - Click forwarding (Ice/Thaw approach: drag one item out, click it, drag it back)

    /// Forwarded click on a hidden item. Instead of expanding the whole
    /// separator, the clicked item alone is dragged out of the overflow area
    /// next to the collapse button, clicked there (so its menu opens beside
    /// where the panel was), and dragged back after its menu closes. Falls
    /// back to the legacy whole-section reveal if the move fails.
    private func handleClick(on item: HiddenMenuItem, button: CGMouseButton) {
        hbDebugLog("handleClick() button=\(button == .right ? "right" : "left") windowID=\(item.windowID) pid=\(item.ownerPID)")
        dismiss()

        guard AXIsProcessTrusted() else {
            showMessagePanel(
                anchorFrame: anchorFrame,
                title: "需要辅助功能权限",
                subtitle: "要点击被隐藏的菜单栏图标，需要辅助功能权限。请在系统设置中授权后重试。",
                buttonTitle: "打开系统设置",
                buttonURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            )
            return
        }

        guard let anchor = statusBarController?.collapseButtonFrame() else {
            hbDebugLog("handleClick() no anchor frame; falling back to tempExpand")
            legacyClick(on: item, button: button)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.forwardClickThawStyle(on: item, button: button, anchor: anchor)
        }
    }

    /// The Ice/Thaw flow: move → click → wait for the menu to close → move back.
    private func forwardClickThawStyle(on item: HiddenMenuItem, button: CGMouseButton, anchor: CGRect) {
        // Drop point: just left of the collapse button (inside the visible bar).
        let isRTL = !Constant.isUsingLTRLanguage
        let dropX = isRTL ? anchor.maxX + 2 : anchor.minX - 2
        let dropPoint = CGPoint(x: dropX, y: anchor.midY)

        hbDebugLog("thaw-flow move out: drop=\(dropPoint) itemFrame=\(item.offScreenFrame)")

        guard let movedFrame = moveItemOut(item: item, to: dropPoint) else {
            hbDebugLog("thaw-flow move-out FAILED; falling back to tempExpand click")
            legacyClick(on: item, button: button)
            return
        }

        hbDebugLog("thaw-flow moved to \(movedFrame); clicking")
        let clickPoint = CGPoint(x: movedFrame.midX, y: movedFrame.midY)

        // Snapshot windows before the click so we can find the menu it opens.
        let before = Self.allWindowInfos()

        Self.postMouseClick(at: clickPoint, button: button)

        // Wait briefly for the app to open its menu, then wait for that menu
        // to close before hiding the item again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let after = Self.allWindowInfos()
            let menuWindowID = Self.menuWindowID(newWindows: after, beforeIDs: Set(before.map { $0.windowID }), interfacePID: item.ownerPID)
            if let menuWindowID {
                hbDebugLog("thaw-flow menu window=\(menuWindowID); waiting for close")
                self.waitForWindowToClose(windowID: menuWindowID, timeout: 30) { [weak self] in
                    hbDebugLog("thaw-flow menu closed; moving item back")
                    self?.moveItemBack(item: item, originalFrame: item.offScreenFrame)
                }
            } else {
                hbDebugLog("thaw-flow no menu window detected; moving item back now")
                self.moveItemBack(item: item, originalFrame: item.offScreenFrame)
            }
        }
    }

    /// Raw CGEventField (0x33) that carries the target window ID on move
    /// events. Not part of the public API; Ice/Thaw A/B tested moves with and
    /// without it and found them more reliable with it stamped.
    private static let rawWindowIDField = CGEventField(rawValue: 0x33)!

    /// Builds a Cmd+drag event pair addressed to `ownerPID` that drags the
    /// item with `windowID` from `pressPoint` to `releasePoint`.
    private static func makeDragEvents(source: CGEventSource, windowID: CGWindowID, ownerPID: pid_t, pressPoint: CGPoint, releasePoint: CGPoint) -> (down: CGEvent, up: CGEvent)? {
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: pressPoint, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: releasePoint, mouseButton: .left)
        else { return nil }
        for e in [down, up] {
            e.flags = .maskCommand
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            e.setIntegerValueField(rawWindowIDField, value: Int64(windowID))
        }
        down.setTargetPID(ownerPID)
        up.setTargetPID(ownerPID)
        return (down, up)
    }

    /// Drags the item from the overflow area to `dropPoint` with synthetic
    /// Cmd+drag events addressed to the window owner. Returns the item's new
    /// frame on success, nil on failure.
    ///
    /// The receiving app's tracking needs the cursor at the press location
    /// (Ice/Thaw found this load-bearing), so the cursor is warped there for
    /// the duration of the drag and restored afterwards.
    private func moveItemOut(item: HiddenMenuItem, to dropPoint: CGPoint) -> CGRect? {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let source else { return nil }
        guard let events = Self.makeDragEvents(source: source, windowID: item.windowID, ownerPID: item.ownerPID, pressPoint: dropPoint, releasePoint: dropPoint) else { return nil }

        let savedCursor = CGEvent(source: nil)?.location

        // The first attempt can act as a warm-up, so retry.
        for attempt in 1...3 {
            CGWarpMouseCursorPosition(dropPoint)
            Thread.sleep(forTimeInterval: 0.02)
            events.down.postToPid(item.ownerPID)
            Thread.sleep(forTimeInterval: 0.05)
            events.up.postToPid(item.ownerPID)

            if let frame = waitForFrameChange(windowID: item.windowID, from: item.offScreenFrame, timeout: 0.4), frame.minX > 0 {
                hbDebugLog("move-out attempt \(attempt) OK frame=\(frame)")
                if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
                return frame
            }
        }
        if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
        return nil
    }

    /// Drags the item back into the overflow area after its menu has closed.
    private func moveItemBack(item: HiddenMenuItem, originalFrame: CGRect) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let source else { return }

        let currentFrame = Self.currentFrame(forID: item.windowID) ?? originalFrame
        guard currentFrame.minX > 0 else {
            hbDebugLog("move-back: item already off-screen at \(currentFrame)")
            return
        }

        // Press where the item currently is (on-screen), release at the
        // original parked position (off-screen). The cursor is warped to the
        // press point only; warping to the off-screen release point would
        // clamp to the display edge under the Apple menu.
        let pressPoint = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let dropPoint = CGPoint(x: originalFrame.midX, y: originalFrame.midY)
        guard let events = Self.makeDragEvents(source: source, windowID: item.windowID, ownerPID: item.ownerPID, pressPoint: pressPoint, releasePoint: dropPoint) else { return }

        let savedCursor = CGEvent(source: nil)?.location

        for attempt in 1...3 {
            CGWarpMouseCursorPosition(pressPoint)
            Thread.sleep(forTimeInterval: 0.02)
            events.down.postToPid(item.ownerPID)
            Thread.sleep(forTimeInterval: 0.05)
            events.up.postToPid(item.ownerPID)

            if let frame = waitForFrameChange(windowID: item.windowID, from: currentFrame, timeout: 0.4), frame.maxX <= 1 {
                hbDebugLog("move-back attempt \(attempt) OK frame=\(frame)")
                if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
                return
            }
        }
        if let savedCursor { CGWarpMouseCursorPosition(savedCursor) }
        hbDebugLog("move-back FAILED after retries; item remains visible at \(Self.currentFrame(forID: item.windowID).debugDescription)")
    }

    /// Polls until the item's window frame differs from `old`, up to `timeout` seconds.
    private func waitForFrameChange(windowID: CGWindowID, from old: CGRect, timeout: TimeInterval) -> CGRect? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            Thread.sleep(forTimeInterval: 0.05)
            if let frame = Self.currentFrame(forID: windowID), frame != old {
                return frame
            }
        }
        return Self.currentFrame(forID: windowID).flatMap { $0 != old ? $0 : nil }
    }

    // MARK: - Window helpers

    private struct WindowInfoLite {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let layer: Int
        let frame: CGRect
    }

    private static func allWindowInfos() -> [WindowInfoLite] {
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard
                let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return WindowInfoLite(windowID: windowID, ownerPID: ownerPID, layer: layer, frame: frame)
        }
    }

    /// Picks the window the click opened: a pop-up-menu-level window (or a
    /// status/main-menu-level window taller than a menu bar item) belonging
    /// to the item's owner or Control Center.
    private static func menuWindowID(newWindows: [WindowInfoLite], beforeIDs: Set<CGWindowID>, interfacePID: pid_t) -> CGWindowID? {
        let popUpLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let controlCenterPID = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.controlcenter" }?
            .processIdentifier

        let candidates = newWindows.filter { !beforeIDs.contains($0.windowID) }
        return candidates.first { win in
            let pidMatches = win.ownerPID == interfacePID || win.ownerPID == controlCenterPID
            guard pidMatches else { return false }
            if win.layer == popUpLevel || win.layer == popUpLevel - 1 {
                return true
            }
            if win.layer == statusLevel || win.layer == mainMenuLevel {
                return win.frame.height > 40
            }
            return false
        }?.windowID
    }

    /// Polls until the window disappears or the timeout elapses.
    private func waitForWindowToClose(windowID: CGWindowID, timeout: TimeInterval, completion: @escaping () -> Void) {
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { completion(); return }
            if Date().timeIntervalSince(start) > timeout {
                completion()
                return
            }
            let stillOpen = Self.allWindowInfos().contains { $0.windowID == windowID }
            if stillOpen {
                self.waitForWindowToClose(windowID: windowID, timeout: timeout, completion: completion)
            } else {
                completion()
            }
        }
    }

    // MARK: - Legacy fallback click (whole-section reveal)

    private func legacyClick(on item: HiddenMenuItem, button: CGMouseButton) {
        statusBarController?.tempExpandForClick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            guard let frame = Self.currentFrame(for: item) else {
                self.statusBarController?.restoreCollapse()
                return
            }
            Self.postMouseClick(at: CGPoint(x: frame.midX, y: frame.midY), button: button)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.statusBarController?.restoreCollapse()
            }
        }
    }

    private static func postMouseClick(at point: CGPoint, button: CGMouseButton) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let isRight = button == .right
        let down = CGEvent(mouseEventSource: source, mouseType: isRight ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: button)
        let up = CGEvent(mouseEventSource: source, mouseType: isRight ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: button)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - HiddenItemsPanelContentView

final class HiddenItemsPanelContentView: NSView {
    var onClickItem: ((HiddenMenuItem, CGMouseButton) -> Void)?

    private let buttons: [HiddenItemButton]
    private let padding: CGFloat = 6
    private let spacing: CGFloat = 2
    private let itemHeight: CGFloat = 24

    var panelSize: NSSize {
        let iconsWidth = buttons.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
        let totalGaps = spacing * CGFloat(max(0, buttons.count - 1))
        let width = padding * 2 + iconsWidth + totalGaps
        return NSSize(width: max(width, 40), height: itemHeight + padding * 2)
    }

    init(items: [(HiddenMenuItem, NSImage)]) {
        buttons = items.map { item, image in
            HiddenItemButton(item: item, image: image)
        }
        super.init(frame: .zero)
        installPanelGlass()

        for button in buttons {
            button.onClick = { [weak self] item, mouseButton in
                self?.onClickItem?(item, mouseButton)
            }
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x = padding
        for button in buttons {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: padding, width: width, height: itemHeight)
            x += width + spacing
        }
    }
}

// MARK: - HiddenItemButton

final class HiddenItemButton: NSButton {
    let item: HiddenMenuItem
    var onClick: ((HiddenMenuItem, CGMouseButton) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    init(item: HiddenMenuItem, image: NSImage) {
        self.item = item
        super.init(frame: .zero)
        isBordered = false
        self.image = image
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor.clear.cgColor
        toolTip = item.ownerName ?? item.title
        target = self
        action = #selector(buttonClicked)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let imageSize = image?.size ?? NSSize(width: 18, height: 18)
        return NSSize(width: imageSize.width + 8, height: imageSize.height + 4)
    }

    override var isFlipped: Bool { true }

    @objc private func buttonClicked() {
        onClick?(item, .left)
    }

    override func rightMouseUp(with event: NSEvent) {
        onClick?(item, .right)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

// MARK: - HiddenItemsMessageView

final class HiddenItemsMessageView: NSView {
    private let maxWidth: CGFloat = 260
    private let padding: CGFloat = 14
    private let buttonURL: URL?

    let panelSize: NSSize

    init(title: String, subtitle: String, buttonTitle: String?, buttonURL: URL?) {
        self.buttonURL = buttonURL

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        var actionButton: NSButton?
        if let buttonTitle {
            actionButton = NSButton(title: buttonTitle, target: nil, action: nil)
            actionButton?.bezelStyle = .rounded
            actionButton?.controlSize = .small
        }

        let contentWidth = maxWidth - padding * 2
        titleLabel.preferredMaxLayoutWidth = contentWidth
        let titleHeight = titleLabel.fittingSize.height
        subtitleLabel.preferredMaxLayoutWidth = contentWidth
        let subtitleHeight = subtitleLabel.fittingSize.height

        let gap: CGFloat = 6
        var height = padding + titleHeight + gap + subtitleHeight + padding
        if actionButton != nil {
            height += 26 + gap
        }

        panelSize = NSSize(width: maxWidth, height: height)
        super.init(frame: NSRect(origin: .zero, size: panelSize))
        installPanelGlass()

        if let actionButton {
            actionButton.target = self
            actionButton.action = #selector(openSettings)
        }

        var y = padding
        titleLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: titleHeight)
        y += titleHeight + gap
        subtitleLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: subtitleHeight)
        y += subtitleHeight + gap
        if let actionButton {
            actionButton.frame = NSRect(x: padding, y: y, width: contentWidth, height: 26)
        }

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        if let actionButton {
            addSubview(actionButton)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    @objc private func openSettings() {
        if let buttonURL {
            NSWorkspace.shared.open(buttonURL)
        }
    }
}

// MARK: - Shared panel glass background

extension NSView {
    func installPanelGlass() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
