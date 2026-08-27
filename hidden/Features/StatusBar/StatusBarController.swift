//
//  StatusBarController.swift
//  vanillaClone
//
//  Created by Thanh Nguyen on 1/30/19.
//  Copyright © 2019 Dwarves Foundation. All rights reserved.
//

import AppKit

class StatusBarController {
    
    //MARK: - Variables
    private var timer:Timer? = nil
    
    /// Ice-style popup panel that shows the hidden items instead of revealing
    /// them directly in the menu bar.
    private lazy var hiddenItemsPanelController = HiddenItemsPanelController(statusBarController: self)
    
    //MARK: - BarItems
        
    private let btnExpandCollapse = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let btnSeparate = NSStatusBar.system.statusItem(withLength: 1)
    private var btnAlwaysHidden:NSStatusItem? = nil
    
    private var btnHiddenLength: CGFloat = 20
    private var btnHiddenCollapseLength: CGFloat = 2000
    
    // Derived from the preference on every read. A stored property would be frozen at the
    // value the preference had when StatusBarController was constructed, so enabling the
    // always hidden section at runtime would create a zero-width (invisible) status item.
    private var btnAlwaysHiddenLength: CGFloat {
        Preferences.alwaysHiddenSectionEnabled ? 20 : 0
    }
    private var btnAlwaysHiddenEnableExpandCollapseLength: CGFloat = 0
    
    private let imgIconLine = NSImage(named:NSImage.Name("ic_line"))
    
    private var isCollapsed: Bool {
        return self.btnSeparate.length > self.btnHiddenLength
    }
    
    private var isBtnSeparateValidPosition: Bool {
        guard
            let btnExpandCollapseX = self.btnExpandCollapse.button?.getOrigin?.x,
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x
            else {return false}
        
        if Constant.isUsingLTRLanguage {
            return btnExpandCollapseX >= btnSeparateX
        } else {
            return btnExpandCollapseX <= btnSeparateX
        }
    }
    
    private var isBtnAlwaysHiddenValidPosition: Bool {
        if !Preferences.alwaysHiddenSectionEnabled { return true }
        
        guard
            let btnSeparateX = self.btnSeparate.button?.getOrigin?.x,
            let btnAlwaysHiddenX = self.btnAlwaysHidden?.button?.getOrigin?.x
            else {return false}
        
        if Constant.isUsingLTRLanguage {
            return btnSeparateX >= btnAlwaysHiddenX
        } else {
            return btnSeparateX <= btnAlwaysHiddenX
        }
    }
    
    private var isToggle = false
    
    //MARK: - Methods
    init() {
        updateCollapsedLengths()
        setupUI()
        setupAlwayHideStatusBar()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.collapseMenuBar()
        }
        
        if Preferences.areSeparatorsHidden {hideSeparators()}
        autoCollapseIfNeeded()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        timer = nil
        if let statusItem = self.btnAlwaysHidden {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
    
    @objc private func handleScreenParametersChanged() {
        let wasCollapsed = isCollapsed
        updateCollapsedLengths()
        if wasCollapsed {
            btnSeparate.length = btnHiddenCollapseLength
            if Preferences.areSeparatorsHidden {
                btnAlwaysHidden?.length = btnAlwaysHiddenEnableExpandCollapseLength
            }
        }
    }
    
    private func updateCollapsedLengths() {
        // Use the widest screen across all displays so the collapse length is always
        // large enough, regardless of which display has focus.
        // macOS enforces a hard 10,000pt maximum for NSStatusItem.length.
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        let collapseLength = max(500, min(screenWidth * 2, 10_000))
        btnHiddenCollapseLength = collapseLength
        btnAlwaysHiddenEnableExpandCollapseLength = Preferences.alwaysHiddenSectionEnabled ? collapseLength : 0
    }
    
    private func setupUI() {
        if let button = btnSeparate.button {
            button.image = self.imgIconLine
        }
        let menu = self.getContextMenu()
        btnSeparate.menu = menu

        updateAutoCollapseMenuTitle()
        
        if let button = btnExpandCollapse.button {
            button.image = Assets.collapseImage
            button.target = self
            
            button.action = #selector(self.btnExpandCollapsePressed(sender:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        btnExpandCollapse.autosaveName = "hiddenbar_expandcollapse";
        btnSeparate.autosaveName = "hiddenbar_separate";
    }
    
    @objc func btnExpandCollapsePressed(sender: NSStatusBarButton) {
        // NSStatusBarButton sends the action on mouseUp, but on modern macOS the
        // currentEvent type is not reliably .leftMouseUp. Only branch on the
        // Option modifier: a plain left-click always toggles the hidden panel;
        // Option+click manages the separators.
        let isOptionKeyPressed = (NSApp.currentEvent?.modifierFlags.contains(NSEvent.ModifierFlags.option) ?? false)
        hbDebugLog("btnExpandCollapsePressed isOption=\(isOptionKeyPressed) type=\(String(describing: NSApp.currentEvent?.type))")
        if isOptionKeyPressed {
            self.showHideSeparatorsAndAlwayHideArea()
        } else {
            self.toggleHiddenPanel()
        }
    }
    
    /// Debounces the panel toggle. On macOS 26 one click can fire the button
    /// action twice (mouseUp + a second delivery), which would build and destroy
    /// the panel in quick succession — the "flashes and vanishes" symptom.
    private var isTogglingPanel = false

    private func toggleHiddenPanel() {
        guard !isTogglingPanel else {
            hbDebugLog("toggleHiddenPanel debounced (double-fire)")
            return
        }
        isTogglingPanel = true
        guard let frame = btnExpandCollapse.button?.window?.frame else {
            hbDebugLog("toggleHiddenPanel button?.window is nil")
            isTogglingPanel = false
            return
        }
        hbDebugLog("toggleHiddenPanel frame=\(frame) isCollapsed=\(isCollapsed)")
        hiddenItemsPanelController.toggle(anchorFrame: frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.isTogglingPanel = false
        }
    }
    
    func showHideSeparatorsAndAlwayHideArea() {
        Preferences.areSeparatorsHidden ? self.showSeparators() : self.hideSeparators()
        
        if self.isCollapsed {self.toggleHiddenPanel()}
    }
    
    private func showSeparators() {
        Preferences.areSeparatorsHidden = false
        
        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenLength
    }
    
    private func hideSeparators() {
        guard self.isBtnAlwaysHiddenValidPosition else {return}
        
        Preferences.areSeparatorsHidden = true
        
        if !self.isCollapsed {
            self.btnSeparate.length = self.btnHiddenLength
        }
        self.btnAlwaysHidden?.length = self.btnAlwaysHiddenEnableExpandCollapseLength
    }
    
    func expandCollapseIfNeeded() {
        //prevented rapid click cause icon show many in Dock
        if isToggle {return}
        isToggle = true
        toggleHiddenPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isToggle = false
        }
    }
    
    private func collapseMenuBar() {
        guard self.isBtnSeparateValidPosition && !self.isCollapsed else {
            autoCollapseIfNeeded()
            return
        }
        
        btnSeparate.length = self.btnHiddenCollapseLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
        }
    }
    
    /// Temporarily reveals the hidden items so a synthesized click can reach a real item.
    func tempExpandForClick() {
        btnSeparate.length = btnHiddenLength
    }

    /// The on-screen frame of the collapse (chevron) button, in CG coordinates
    /// (origin top-left, the same space as CGEvent and CGWindowList bounds).
    /// Used as the anchor next to which a hidden item is dragged out before
    /// being clicked.
    func collapseButtonFrame() -> CGRect? {
        guard let window = btnExpandCollapse.button?.window else { return nil }
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return nil }
        // AppKit (bottom-left origin) → CG (top-left origin)
        let appKitFrame = window.frame
        return CGRect(
            x: appKitFrame.minX,
            y: screen.frame.maxY - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }
    
    /// Re-hides the items after a synthesized click has been delivered.
    func restoreCollapse() {
        guard isBtnSeparateValidPosition else { return }
        btnSeparate.length = btnHiddenCollapseLength
        if let button = btnExpandCollapse.button {
            button.image = Assets.expandImage
        }
    }
    
    private func autoCollapseIfNeeded() {
        guard Preferences.isAutoHide else {return}
        guard !isCollapsed else { return }
        
        startTimerToAutoHide()
    }
    
    private func startTimerToAutoHide() {
        timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: Preferences.numberOfSecondForAutoHide, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                if Preferences.isAutoHide {
                    self?.collapseMenuBar()
                }
            }
        }
    }
    
    private func getContextMenu() -> NSMenu {
        let menu = NSMenu()
        
        let prefItem = NSMenuItem(title: "Preferences...".localized, action: #selector(openPreferenceViewControllerIfNeeded), keyEquivalent: "P")
        prefItem.target = self
        menu.addItem(prefItem)
        
        let toggleAutoHideItem = NSMenuItem(title: "Toggle Auto Collapse".localized, action: #selector(toggleAutoHide), keyEquivalent: "t")
        toggleAutoHideItem.target = self
        toggleAutoHideItem.tag = 1
        NotificationCenter.default.addObserver(self, selector: #selector(updateAutoHide), name: .prefsChanged, object: nil)
        menu.addItem(toggleAutoHideItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit".localized, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        return menu
    }
    
    private func updateAutoCollapseMenuTitle() {
        guard let toggleAutoHideItem = btnSeparate.menu?.item(withTag: 1) else { return }
        if Preferences.isAutoHide {
            toggleAutoHideItem.title = "Disable Auto Collapse".localized
        } else {
            toggleAutoHideItem.title = "Enable Auto Collapse".localized
        }
    }
    
    @objc func updateAutoHide() {
        updateAutoCollapseMenuTitle()
        autoCollapseIfNeeded()
    }
    
    @objc func openPreferenceViewControllerIfNeeded() {
        Util.showPrefWindow()
    }
    
    @objc func toggleAutoHide() {
        Preferences.isAutoHide.toggle()
    }
}


//MARK: - Alway hide feature
extension StatusBarController {
    private func setupAlwayHideStatusBar() {
        NotificationCenter.default.addObserver(self, selector: #selector(toggleStatusBarIfNeeded), name: .alwayHideToggle, object: nil)
        toggleStatusBarIfNeeded()
    }
    @objc private func toggleStatusBarIfNeeded() {
        updateCollapsedLengths()

        if Preferences.alwaysHiddenSectionEnabled {
            if self.btnAlwaysHidden == nil {
                let statusItem = NSStatusBar.system.statusItem(withLength: btnAlwaysHiddenLength)
                if let button = statusItem.button {
                    button.image = self.imgIconLine
                    button.appearsDisabled = true
                }
                statusItem.autosaveName = "hiddenbar_terminate"
                self.btnAlwaysHidden = statusItem
            }
            // Re-apply the width every time: the item may have been created while the
            // separators were hidden, in which case it has to start out collapsed.
            self.btnAlwaysHidden?.length = Preferences.areSeparatorsHidden
                ? btnAlwaysHiddenEnableExpandCollapseLength
                : btnAlwaysHiddenLength
        } else {
            if let statusItem = self.btnAlwaysHidden {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            self.btnAlwaysHidden = nil
        }
    }
}
