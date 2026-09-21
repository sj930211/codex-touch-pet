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
    private var petImageView: NSImageView?
    private var petFallbackLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var summaryLabel: NSTextField?
    private var connectionLabel: NSTextField?
    private let artwork = PetArtwork()
    private var animationTimer: Timer?
    private var taskCarouselTimer: Timer?
    private var trayRestoreWorkItem: DispatchWorkItem?
    private var collapseTimer: Timer?
    private var current = AggregatePetStatus(
        state: .disconnected,
        activeCount: 0,
        waitingCount: 0,
        trackedCount: 0
    )
    private var frameIndex = 0
    private var carouselIndex = 0
    private var isExpanded = false
    private var codexIsActive = false

    private struct PetMotion {
        let scale: CGFloat
        let x: CGFloat
        let y: CGFloat
        let opacity: CGFloat
    }

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
        trayButton.bezelColor = current.state.compactBackgroundColor
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
        taskCarouselTimer = Timer.scheduledTimer(
            timeInterval: 5.0,
            target: self,
            selector: #selector(advanceTaskCarousel),
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
        taskCarouselTimer?.invalidate()
        taskCarouselTimer = nil
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
        if current.carouselTasks.isEmpty {
            carouselIndex = 0
        } else {
            carouselIndex %= current.carouselTasks.count
        }
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
            let container = NSView()
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.toolTip = "Codex Touch Bar Pet"
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let fallback = NSTextField(labelWithString: face(for: current.state, expanded: true))
            fallback.alignment = .center
            fallback.font = .systemFont(ofSize: 19, weight: .medium)
            fallback.textColor = statusColor
            fallback.toolTip = "Codex Touch Bar Pet"
            fallback.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(imageView)
            container.addSubview(fallback)
            NSLayoutConstraint.activate([
                container.widthAnchor.constraint(equalToConstant: 48),
                container.heightAnchor.constraint(equalToConstant: 30),
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                fallback.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fallback.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                fallback.topAnchor.constraint(equalTo: container.topAnchor),
                fallback.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])

            petImageView = imageView
            petFallbackLabel = fallback
            petLabel = fallback
            item.view = container
            return item

        case Identifier.status:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let container = NSView()
            let primary = NSTextField(labelWithString: primaryStatusLabel)
            primary.alignment = .left
            primary.font = .systemFont(ofSize: 13, weight: .semibold)
            primary.textColor = .white
            primary.setContentHuggingPriority(.required, for: .horizontal)
            primary.setContentCompressionResistancePriority(.required, for: .horizontal)
            primary.translatesAutoresizingMaskIntoConstraints = false

            let summary = NSTextField(labelWithString: taskSummaryLabel)
            summary.alignment = .left
            summary.font = .systemFont(ofSize: 12, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.lineBreakMode = .byTruncatingTail
            summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            summary.translatesAutoresizingMaskIntoConstraints = false

            let connection = NSTextField(labelWithString: connectionStatusLabel)
            connection.alignment = .right
            connection.font = .systemFont(ofSize: 11, weight: .medium)
            connection.lineBreakMode = .byTruncatingTail
            connection.setContentHuggingPriority(.required, for: .horizontal)
            connection.setContentCompressionResistancePriority(.required, for: .horizontal)
            connection.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(primary)
            container.addSubview(summary)
            container.addSubview(connection)
            let preferredWidth = container.widthAnchor.constraint(equalToConstant: 540)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                preferredWidth,
                container.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
                container.heightAnchor.constraint(equalToConstant: 30),
                primary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                primary.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                summary.leadingAnchor.constraint(equalTo: primary.trailingAnchor, constant: 14),
                summary.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                summary.trailingAnchor.constraint(equalTo: connection.leadingAnchor, constant: -12),
                connection.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                connection.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                connection.widthAnchor.constraint(equalToConstant: 58)
            ])
            statusLabel = primary
            summaryLabel = summary
            connectionLabel = connection
            item.view = container
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

    @objc private func advanceTaskCarousel() {
        guard current.carouselTasks.count > 1 else { return }
        carouselIndex = (carouselIndex + 1) % current.carouselTasks.count
        updateViews()
    }

    private func updateViews() {
        let image = artwork.image(for: current.state)
        let animatedImage = image.map(animatedPetImage)
        // Preserve the approved full-color fox. Only the compact button
        // background carries the semantic state color.
        trayButton?.image = animatedImage
        trayButton?.title = image == nil ? face(for: current.state) : ""
        trayButton?.imagePosition = image == nil ? .noImage : .imageOnly
        trayButton?.bezelColor = current.state.compactBackgroundColor
        trayButton?.contentTintColor = nil
        petImageView?.image = animatedImage
        petImageView?.isHidden = image == nil
        petFallbackLabel?.isHidden = image != nil
        petLabel?.stringValue = face(for: current.state, expanded: true)
        petLabel?.textColor = statusColor
        statusLabel?.stringValue = primaryStatusLabel
        statusLabel?.textColor = statusColor
        summaryLabel?.stringValue = taskSummaryLabel
        summaryLabel?.textColor = summaryColor
        connectionLabel?.stringValue = connectionStatusLabel
        connectionLabel?.textColor = connectionColor
    }

    private func animatedPetImage(_ image: NSImage) -> NSImage {
        let motion = petMotion
        let canvas = NSImage(size: image.size)
        canvas.lockFocus()
        let width = image.size.width * motion.scale
        let height = image.size.height * motion.scale
        let destination = NSRect(
            x: (image.size.width - width) / 2 + image.size.width * motion.x,
            y: (image.size.height - height) / 2 + image.size.height * motion.y,
            width: width,
            height: height
        )
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: motion.opacity
        )
        canvas.unlockFocus()
        canvas.isTemplate = false
        return canvas
    }

    private var petMotion: PetMotion {
        switch current.state {
        case .idle, .interrupted, .disconnected:
            let scales: [CGFloat] = [0.94, 0.96, 0.98, 0.96]
            return PetMotion(scale: scales[frameIndex % scales.count], x: 0, y: 0, opacity: 1)
        case .working:
            let frames: [PetMotion] = [
                PetMotion(scale: 0.96, x: 0, y: 0, opacity: 1),
                PetMotion(scale: 0.98, x: 0, y: 0.018, opacity: 1),
                PetMotion(scale: 0.96, x: 0, y: 0, opacity: 1),
                PetMotion(scale: 0.95, x: 0, y: -0.008, opacity: 1)
            ]
            return frames[frameIndex % frames.count]
        case .connecting:
            let opacities: [CGFloat] = [0.66, 0.82, 1.0, 0.82]
            return PetMotion(scale: 0.96, x: 0, y: 0, opacity: opacities[frameIndex % opacities.count])
        case .waitingApproval, .waitingInput:
            let offsets: [CGFloat] = [0, 0.026, 0, -0.010]
            return PetMotion(scale: 0.97, x: 0, y: offsets[frameIndex % offsets.count], opacity: 1)
        case .completed:
            let scales: [CGFloat] = [0.94, 1.0, 0.97, 1.0]
            return PetMotion(scale: scales[frameIndex % scales.count], x: 0, y: 0, opacity: 1)
        case .failed, .systemError:
            let offsets: [CGFloat] = [-0.018, 0.018, -0.010, 0.010, 0]
            return PetMotion(scale: 0.96, x: offsets[frameIndex % offsets.count], y: 0, opacity: 1)
        }
    }

    private var primaryStatusLabel: String {
        if current.activeCount > 0 {
            return "Codex 正在工作"
        }
        return current.state.label
    }

    private var taskSummaryLabel: String {
        if current.activeCount > 0 {
            let tasks = current.carouselTasks.filter { task in
                if case .working = task.state { return true }
                return false
            }
            guard !tasks.isEmpty else {
                return "\(current.activeCount) 项任务 · 当前任务"
            }
            let task = tasks[carouselIndex % tasks.count]
            return "\(current.activeCount) 项任务 · \(task.displayTitle) · 已运行 \(runtimeLabel(for: task))"
        }
        switch current.state {
        case .idle:
            return "等待新任务"
        case .waitingApproval, .waitingInput:
            return current.waitingCount == 1
                ? "1 项任务需要处理"
                : "\(current.waitingCount) 项任务需要处理"
        case .completed:
            return "刚刚完成"
        case .interrupted:
            return "任务已停止"
        case .failed, .systemError:
            return "点击查看详情"
        case .connecting:
            return "正在连接"
        case .disconnected:
            return "未连接"
        case .working:
            return "当前任务"
        }
    }

    private func runtimeLabel(for task: PetTaskStatus) -> String {
        let start = task.startedAt ?? task.updatedAt
        let elapsed = max(0, Int(Date().timeIntervalSince(start)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var summaryColor: NSColor {
        if current.activeCount > 0 {
            return NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.92, alpha: 1)
        }
        return current.state.color
    }

    private var connectionStatusLabel: String {
        switch current.state {
        case .disconnected:
            return "● 未连接"
        case .connecting:
            return "● 连接中"
        case .interrupted:
            return "● 已停止"
        case .systemError, .failed:
            return "● 异常"
        default:
            return "● 在线"
        }
    }

    private var connectionColor: NSColor {
        switch current.state {
        case .disconnected:
            return PetState.disconnected.color
        case .interrupted:
            return .secondaryLabelColor
        case .systemError, .failed:
            return .systemRed
        case .connecting:
            return PetState.connecting.color
        default:
            return current.activeCount > 0
                ? PetState.working(nil).color
                : .secondaryLabelColor
        }
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
