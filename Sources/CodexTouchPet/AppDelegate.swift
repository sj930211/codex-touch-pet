import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusStore = ThreadStatusStore()
    private lazy var ipcClient = CodexIPCClient(statusStore: statusStore)
    private let touchBarController = TouchBarController()

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var quietMenuItem: NSMenuItem?
    private var signalSources: [DispatchSourceSignal] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenuBar()
        configureSignals()
        configureWorkspaceObservers()
        statusStore.onChange = { [weak self] aggregate in
            self?.apply(aggregate)
        }
        touchBarController.start()
        syncCodexActivation(NSWorkspace.shared.frontmostApplication)
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
        statusItem.button?.image = statusImage(symbolName: "pawprint.fill")
        statusItem.button?.toolTip = "Codex Touch Pet"

        let menu = NSMenu()
        let statusMenuItem = NSMenuItem(title: "状态：正在连接", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        let showItem = NSMenuItem(
            title: "在 Touch Bar 展开",
            action: #selector(showTouchBar),
            keyEquivalent: ""
        )
        showItem.target = self
        showItem.isEnabled = touchBarController.isPrivateTouchBarAvailable
        menu.addItem(showItem)

        let quietItem = NSMenuItem(
            title: "安静模式",
            action: #selector(toggleQuietMode),
            keyEquivalent: ""
        )
        quietItem.target = self
        quietItem.state = .off
        menu.addItem(quietItem)

        let compatibilityTitle = touchBarController.isPrivateTouchBarAvailable
            ? "Touch Bar：兼容"
            : "Touch Bar：不可用，已降级为菜单栏"
        let compatibilityItem = NSMenuItem(title: compatibilityTitle, action: nil, keyEquivalent: "")
        compatibilityItem.isEnabled = false
        menu.addItem(compatibilityItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Codex Touch Pet", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
        self.statusMenuItem = statusMenuItem
        self.quietMenuItem = quietItem
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
        let isCodexActive = application?.bundleIdentifier == "com.openai.codex"
        touchBarController.handleCodexActivation(isActive: isCodexActive)
    }

    private func apply(_ aggregate: AggregatePetStatus) {
        precondition(Thread.isMainThread)
        touchBarController.update(aggregate)
        statusMenuItem?.title = "状态：\(aggregate.state.label)"
        statusItem?.button?.image = statusImage(symbolName: menuBarSymbolName(for: aggregate.state))
        statusItem?.button?.contentTintColor = aggregate.state.color
    }

    private func menuBarSymbolName(for state: PetState) -> String {
        switch state {
        case .waitingApproval, .waitingInput: return "exclamationmark.bubble.fill"
        case .failed, .systemError: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .working: return "pawprint.fill"
        default: return "pawprint"
        }
    }

    private func statusImage(symbolName: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Codex Touch Pet")
        image?.isTemplate = true
        return image
    }

    @objc private func showTouchBar() {
        touchBarController.showExpanded()
    }

    @objc private func toggleQuietMode() {
        let newValue = !touchBarController.quietMode
        touchBarController.setQuietMode(newValue)
        quietMenuItem?.state = newValue ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
