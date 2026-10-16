import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusStore = ThreadStatusStore()
    private lazy var ipcClient = CodexIPCClient(statusStore: statusStore)
    private let touchBarController = TouchBarController()
    private let settingsStore = AppSettingsStore()
    private var settings = AppSettings()

    private var statusItem: NSStatusItem?
    private var menuController: PetMenuController?
    private let normalStatusImage = MenuBarIcon.image()
    private let attentionStatusImage = MenuBarIcon.image(attention: true)
    private var settingsWindowController: SettingsWindowController?
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var signalSources: [DispatchSourceSignal] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var latestAggregate = AggregatePetStatus(
        state: .connecting,
        connectionState: .connecting,
        activeCount: 0,
        waitingCount: 0,
        trackedCount: 0
    )

    private let codexBundleIdentifier = "com.openai.codex"
    // ToDesk may remain focused on another display while Codex is the visible
    // application on the primary display. NSWorkspace exposes only one global
    // frontmost application, so treating this auxiliary activation as a Codex
    // exit would incorrectly collapse the full Touch Bar panel.
    private let auxiliaryDisplayBundleIdentifiers = ["com.youqu.todesk.mac"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settings = settingsStore.load()
        touchBarController.applySettings(settings)
        configureMenuBar()
        configureSignals()
        configureWorkspaceObservers()
        statusStore.onChange = { [weak self] aggregate in
            self?.apply(aggregate)
        }
        statusStore.beginConnecting()
        touchBarController.start()
        syncCodexActivation(NSWorkspace.shared.frontmostApplication)
        // The accessory app can finish launching before the previously active
        // Codex window is reported by NSWorkspace. Re-check once after the
        // activation transaction settles so the full panel is not left
        // collapsed on a multi-display setup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.syncCodexActivation(NSWorkspace.shared.frontmostApplication)
        }
        ipcClient.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcClient.stop()
        touchBarController.stop()
        signalSources.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    private func configureMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = normalStatusImage
        statusItem.button?.toolTip = "Codex Touch Pet"
        let menuController = PetMenuController(touchBarAvailable: touchBarController.isPrivateTouchBarAvailable) { [weak self] action in
            self?.handleMenuAction(action)
        }
        menuController.update(status: latestAggregate, settings: settings)
        statusItem.menu = menuController.menu
        self.statusItem = statusItem
        self.menuController = menuController
    }

    private func configureSignals() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func configureWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.syncCodexActivation(application)
        }
        workspaceObservers.append(observer)
    }

    private func syncCodexActivation(_ application: NSRunningApplication?) {
        // Launching or activating this accessory app can emit an activation
        // notification of its own while the user is still looking at Codex.
        // Treating that transient event as "Codex left" immediately collapses
        // the freshly expanded Touch Bar, especially in multi-display setups.
        if application?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        let bundleIdentifier = application?.bundleIdentifier
        let isCodexActive: Bool
        if bundleIdentifier == codexBundleIdentifier {
            isCodexActive = true
        } else if let bundleIdentifier,
                  auxiliaryDisplayBundleIdentifiers.contains(bundleIdentifier) {
            // Keep Codex expanded when the other display is occupied by a
            // remote-control client. If startup happened while ToDesk was the
            // global frontmost app, use the primary-display window check to
            // recover the Codex state as well.
            isCodexActive = hasVisibleCodexWindowOnPrimaryDisplay()
                || touchBarController.codexIsActive
        } else {
            isCodexActive = false
        }
        touchBarController.handleCodexActivation(isActive: isCodexActive)
    }

    private func hasVisibleCodexWindowOnPrimaryDisplay() -> Bool {
        let primaryBounds = CGDisplayBounds(CGMainDisplayID())
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return false
        }

        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier == codexBundleIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = window[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 300,
                  bounds.height >= 200 else {
                continue
            }
            if bounds.intersection(primaryBounds).isNull == false {
                return true
            }
        }
        return false
    }

    private func apply(_ aggregate: AggregatePetStatus) {
        precondition(Thread.isMainThread)
        latestAggregate = aggregate
        touchBarController.update(aggregate)
        updateMenuPresentation()
        diagnosticsWindowController?.update(snapshot: diagnosticSnapshot())
    }

    private func updateMenuPresentation() {
        let summary = MenuBarSummary(status: latestAggregate, quietMode: settings.quietMode)
        menuController?.update(status: latestAggregate, settings: settings)
        statusItem?.button?.image = summary.needsAttention ? attentionStatusImage : normalStatusImage
        statusItem?.button?.contentTintColor = nil
        statusItem?.button?.toolTip = "\(AppMetadata.name) · \(summary.title) · \(summary.detail)"
        statusItem?.button?.setAccessibilityLabel("\(AppMetadata.name)，\(summary.title)，\(summary.detail)")
    }

    private func handleMenuAction(_ action: PetMenuAction) {
        switch action {
        case .expand: showTouchBar()
        case .quiet: toggleQuietMode()
        case .settings: showSettings()
        case .reconnect: reconnectIPC()
        case .diagnostics: showDiagnostics()
        case .usage: showUsage()
        case .about: showAbout()
        case .quit: quit()
        }
    }

    @objc private func showTouchBar() {
        touchBarController.showExpanded()
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                settings: settings,
                onHelpAction: { [weak self] action in self?.handleMenuAction(action) }
            ) { [weak self] newSettings in
                self?.applySettings(newSettings)
            }
        }
        settingsWindowController?.update(settings: settings)
        settingsWindowController?.present()
    }

    @objc private func showDiagnostics() {
        let snapshot = diagnosticSnapshot()
        if diagnosticsWindowController == nil {
            diagnosticsWindowController = DiagnosticsWindowController(
                snapshot: snapshot,
                onReconnect: { [weak self] in self?.reconnectIPC() }
            )
        }
        diagnosticsWindowController?.update(snapshot: snapshot)
        diagnosticsWindowController?.present()
    }

    @objc private func reconnectIPC() {
        statusStore.beginManualReconnect()
        ipcClient.reconnect()
    }

    @objc private func showUsage() {
        let alert = NSAlert()
        alert.messageText = "Codex Touch Pet 使用说明"
        alert.informativeText = "狐狸的姿态表示任务状态，右侧独立显示连接状态。任务胶囊并排展示，可横向滑动；点按胶囊会回到对应的 Codex 会话。审批、回复和具体工作内容仍在 Codex 中完成。\n\n没有任务胶囊且连接在线时，狐狸会在空闲区域活动。菜单栏设置可调整自动展开、紧凑宠物、安静模式、动效和完成/等待提示。"
        alert.addButton(withTitle: "完成")
        alert.runModal()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "\(AppMetadata.name) \(AppMetadata.version)"
        alert.informativeText = "一个面向实体 MacBook Touch Bar 的 Codex 状态宠物。\n\n开源说明：源码仓库位于 GitHub。当前许可证仍待项目所有者确认，在明确许可证前，请勿将本项目视为授予复制、修改或分发许可。\n\n本项目依赖 macOS AppKit、Codex Desktop 本地状态与 Touch Bar 私有接口，兼容性以实际设备为准。"
        alert.addButton(withTitle: "打开源代码")
        alert.addButton(withTitle: "完成")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(AppMetadata.repositoryURL)
        }
    }

    @objc private func toggleQuietMode() {
        var newSettings = settings
        newSettings.quietMode.toggle()
        applySettings(newSettings)
    }

    private func applySettings(_ newSettings: AppSettings) {
        settings = newSettings
        settingsStore.save(newSettings)
        touchBarController.applySettings(newSettings)
        updateMenuPresentation()
        settingsWindowController?.update(settings: newSettings)
    }

    private func diagnosticSnapshot() -> DiagnosticSnapshot {
        DiagnosticSnapshot(
            codexRunning: !NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.openai.codex"
            ).isEmpty,
            connectionState: latestAggregate.connectionState,
            lastSuccessfulUpdateAt: latestAggregate.lastSuccessfulUpdateAt,
            activeCount: latestAggregate.activeCount,
            waitingCount: latestAggregate.waitingCount,
            trackedCount: latestAggregate.trackedCount,
            filteredInternalCount: latestAggregate.filteredInternalCount,
            touchBarAvailable: touchBarController.isPrivateTouchBarAvailable,
            lastConnectionIssueAt: latestAggregate.lastDisconnectAt,
            connectionIssueCode: latestAggregate.connectionIssueCode
        )
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
