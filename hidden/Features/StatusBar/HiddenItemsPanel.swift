//
//  HiddenItemsPanel.swift
//  NewHiddenBar
//
//  Ice-style popup panel. When the user clicks the collapse button, the hidden
//  menu bar items stay off-screen; this panel renders a snapshot of each hidden
//  item and forwards clicks back to the real items by temporarily revealing them
//  and synthesizing a mouse click.
//
//  Requires: Screen Recording permission (to capture other apps' menu bar items)
//  and Accessibility permission (to synthesize clicks).
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

// MARK: - HiddenItemsPanelController

/// Writes a diagnostic line to /tmp/NewHiddenBar-debug.log (app sandbox is off).
/// Used to trace "nothing happens when clicking the collapse button".
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

        // Temporarily reveal the hidden items so their windows can be captured,
        // then hide them again before showing the panel.
        statusBarController?.tempExpandForClick()
        hbDebugLog("show() tempExpandForClick called")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
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
            hbDebugLog("show() captured \(captured.count)/\(items.count), restoreCollapse called")

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
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard
                let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                windowID == item.windowID,
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

    // MARK: - Click forwarding

    private func handleClick(on item: HiddenMenuItem, button: CGMouseButton) {
        hbDebugLog("handleClick() button=\(button == .right ? "right" : "left") windowID=\(item.windowID)")
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

        // Temporarily reveal the hidden items so the click can land on the real item.
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
