import AppKit

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private enum Identifier {
        static let tray = NSTouchBarItem.Identifier("dev.codex.touch-pet.tray")
        static let pet = NSTouchBarItem.Identifier("dev.codex.touch-pet.pet")
        static let status = NSTouchBarItem.Identifier("dev.codex.touch-pet.status")
    }

    let isPrivateTouchBarAvailable = CTPPrivateTouchBarAvailable()
    private(set) var quietMode = false

    private var touchBar: NSTouchBar?
    private var trayItem: NSCustomTouchBarItem?
    private var trayButton: NSButton?
    private var petLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var animationTimer: Timer?
    private var trayRestoreWorkItem: DispatchWorkItem?
    private var collapseTimer: Timer?
    private var current = AggregatePetStatus(
        state: .disconnected,
        activeCount: 0,
        waitingCount: 0,
        trackedCount: 0
    )
    private var frameIndex = 0
    private var isExpanded = false
    private var codexIsActive = false

    func start() {
        guard isPrivateTouchBarAvailable else { return }

        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            Identifier.pet,
            Identifier.status
        ]
        touchBar.principalItemIdentifier = Identifier.pet
        self.touchBar = touchBar

        let trayItem = NSCustomTouchBarItem(identifier: Identifier.tray)
        let trayButton = NSButton(title: "🐾", target: self, action: #selector(toggleExpanded))
        trayButton.bezelColor = NSColor(calibratedRed: 0.18, green: 0.73, blue: 0.90, alpha: 1.0)
        trayItem.view = trayButton
        self.trayItem = trayItem
        self.trayButton = trayButton
        CTPAddSystemTrayItem(trayItem)
        scheduleTrayRestore()

        animationTimer = Timer.scheduledTimer(
            timeInterval: 0.7,
            target: self,
            selector: #selector(advanceAnimation),
            userInfo: nil,
            repeats: true
        )
        updateViews()

        // A debug duration may be supplied for local Touch Bar verification. In
        // normal operation the compact tray item is the only startup UI.
        let configuredWelcomeDuration = ProcessInfo.processInfo.environment["CODEX_TOUCH_PET_WELCOME_SECONDS"]
            .flatMap(TimeInterval.init)
        if let configuredWelcomeDuration {
            showExpanded()
            scheduleCollapse(after: configuredWelcomeDuration)
        }
    }

    func stop() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        animationTimer?.invalidate()
        animationTimer = nil
        trayRestoreWorkItem?.cancel()
        trayRestoreWorkItem = nil
        if let touchBar {
            CTPDismissSystemModalTouchBar(touchBar)
        }
        if let trayItem {
            CTPRemoveSystemTrayItem(trayItem)
        }
        isExpanded = false
        codexIsActive = false
        trayItem = nil
        touchBar = nil
    }

    func update(_ status: AggregatePetStatus) {
        precondition(Thread.isMainThread)
        current = status
        frameIndex = 0
        updateViews()
    }

    /// Called by the application activation observer. The full bar follows the
    /// Codex window, while the compact Control Strip item remains registered.
    func handleCodexActivation(isActive: Bool) {
        precondition(Thread.isMainThread)
        guard codexIsActive != isActive else { return }
        codexIsActive = isActive
        guard !quietMode else { return }
        if isActive {
            showExpanded()
        } else {
            hideExpanded()
        }
    }

    func setQuietMode(_ enabled: Bool) {
        quietMode = enabled
        if enabled {
            hideExpanded()
        } else if codexIsActive {
            showExpanded()
        }
    }

    func showExpanded() {
        guard isPrivateTouchBarAvailable, let touchBar else { return }
        collapseTimer?.invalidate()
        collapseTimer = nil
        CTPPresentSystemModalTouchBar(touchBar, Identifier.tray)
        isExpanded = true
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case Identifier.pet:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: face(for: current.state, expanded: true))
            label.alignment = .center
            label.font = .systemFont(ofSize: 19, weight: .medium)
            label.textColor = statusColor
            label.toolTip = "Codex Touch Bar Pet"
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            petLabel = label
            item.view = label
            return item

        case Identifier.status:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: current.state.label)
            label.alignment = .left
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
            label.widthAnchor.constraint(equalToConstant: 160).isActive = true
            statusLabel = label
            item.view = label
            return item

        default:
            return nil
        }
    }

    @objc private func toggleExpanded() {
        // A tap from another app should activate Codex and leave the full bar
        // open. The activation notification can arrive asynchronously, so do
        // not let the same tap immediately undo that expansion.
        if !codexIsActive {
            activateCodex()
            showExpanded()
            return
        }
        isExpanded ? hideExpanded() : showExpanded()
    }

    private func hideExpanded() {
        guard let touchBar else { return }
        collapseTimer?.invalidate()
        collapseTimer = nil
        // Keep the pet in Control Strip when the full panel is hidden. A
        // dismiss removes the system-modal session entirely; minimize returns
        // it to the registered tray item, matching the manual close behavior.
        CTPMinimizeSystemModalTouchBar(touchBar)
        isExpanded = false
        scheduleTrayRestore()
    }

    private func scheduleTrayRestore() {
        trayRestoreWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isExpanded, let trayItem = self.trayItem else { return }
            CTPAddSystemTrayItem(trayItem)
        }
        trayRestoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hideExpanded()
        }
    }

    @objc private func advanceAnimation() {
        frameIndex += 1
        updateViews()
    }

    private func updateViews() {
        trayButton?.title = face(for: current.state)
        trayButton?.contentTintColor = statusColor
        petLabel?.stringValue = face(for: current.state, expanded: true)
        petLabel?.textColor = statusColor
        statusLabel?.stringValue = current.activityLabel
        statusLabel?.textColor = statusColor
    }

    private var statusColor: NSColor {
        // The aggregate state may retain a completed/failed sibling while a
        // different thread is still working. The visible work summary should
        // stay blue whenever there is active work.
        if current.activeCount > 0 {
            return PetState.working(nil).color
        }
        switch current.state {
        case .working:
            return PetState.working(nil).color
        default:
            return current.state.color
        }
    }

    private func face(for state: PetState, expanded: Bool = false) -> String {
        let core: String
        switch state {
        case .idle:
            core = frameIndex % 9 == 0 ? "－ᴥ－" : "•ᴥ•"
        case .working:
            let frames = ["•̀ᴥ•́", "•̀ᴥ•", "•̀ᴥ•́", "•ᴥ•́"]
            core = frames[frameIndex % frames.count]
        case .connecting:
            let frames = ["•ᴥ•", "•ᴥ•·", "•ᴥ•··", "•ᴥ•···"]
            core = frames[frameIndex % frames.count]
        case .completed:
            let frames = ["ᵔᴥᵔ✦", "ᵔᴥᵔ✧"]
            core = frames[frameIndex % frames.count]
        default:
            core = state.compactFace
        }
        return expanded ? "ʕ\(core)ʔ" : core
    }

    @objc private func activateCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
