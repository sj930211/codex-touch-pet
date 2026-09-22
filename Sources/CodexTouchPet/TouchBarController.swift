import AppKit
import QuartzCore
#if canImport(TouchBarPrivate)
import TouchBarPrivate
#endif

private final class TaskChipButton: NSButton {
    var threadID = ""
    private var accentColor: NSColor = .secondaryLabelColor

    override var intrinsicContentSize: NSSize {
        let contentSize = super.intrinsicContentSize
        return NSSize(width: contentSize.width + 16, height: 26)
    }

    func applyCapsuleStyle(accentColor: NSColor) {
        self.accentColor = accentColor
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.75
        updateCapsuleAppearance(isPressed: false)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        updateCapsuleAppearance(isPressed: flag)
    }

    private func updateCapsuleAppearance(isPressed: Bool) {
        let accentAlpha: CGFloat = isPressed ? 0.30 : 0.14
        layer?.backgroundColor = accentColor.withAlphaComponent(accentAlpha).cgColor
        layer?.borderColor = accentColor.withAlphaComponent(isPressed ? 0.82 : 0.48).cgColor
    }
}

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private enum Identifier {
        static let tray = NSTouchBarItem.Identifier("dev.codex.touch-pet.tray")
        static let pet = NSTouchBarItem.Identifier("dev.codex.touch-pet.pet")
        static let status = NSTouchBarItem.Identifier("dev.codex.touch-pet.status")
    }

    let isPrivateTouchBarAvailable = CTPPrivateTouchBarAvailable()
    private(set) var settings = AppSettings()

    private var touchBar: NSTouchBar?
    private var trayItem: NSCustomTouchBarItem?
    private var trayButton: NSButton?
    private var petLabel: NSTextField?
    private var petImageView: NSImageView?
    private var petFallbackLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var taskScrollView: NSScrollView?
    private var taskStackView: NSStackView?
    private var connectionLabel: NSTextField?
    private var taskChipOrder: [String] = []
    private var renderedTaskChips: [TaskChipSnapshot] = []
    private var renderedTaskFallback: String?
    private let artwork = PetArtwork()
    private var animationTimer: Timer?
    private var trayRestoreWorkItem: DispatchWorkItem?
    private var collapseTimer: Timer?
    private var current = AggregatePetStatus(
        state: .disconnected,
        connectionState: .disconnected,
        activeCount: 0,
        waitingCount: 0,
        trackedCount: 0
    )
    private var frameIndex = 0
    private var isExpanded = false
    private var codexIsActive = false

    private struct PetMotion {
        let scale: CGFloat
        let x: CGFloat
        let y: CGFloat
        let rotation: CGFloat
        let opacity: CGFloat
    }

    private struct TaskChipSnapshot: Equatable {
        let threadID: String
        let fullTitle: String
        let abbreviatedTitle: String
        let state: PetAnimationIdentity
    }

    private struct TaskChipStyle {
        let color: NSColor
        let stateLabel: String
    }

    private enum AnimationFrameLimit {
        static let completed = 7
        static let error = 7
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
        trayButton.bezelColor = compactBackgroundColor
        trayItem.view = trayButton
        self.trayItem = trayItem
        self.trayButton = trayButton
        syncTrayRegistration()

        animationTimer = Timer.scheduledTimer(
            timeInterval: 0.10,
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
        let stateChanged = current.state.animationIdentity != status.state.animationIdentity
        let connectionChanged = current.connectionState != status.connectionState
        if stateChanged || connectionChanged {
            prepareStateCrossfade()
        }
        current = status
        if stateChanged {
            frameIndex = 0
        }
        updateViews()
    }

    /// Called by the application activation observer. The full bar follows the
    /// Codex window, while the compact Control Strip item remains registered.
    func handleCodexActivation(isActive: Bool) {
        precondition(Thread.isMainThread)
        guard codexIsActive != isActive else { return }
        codexIsActive = isActive
        if isActive {
            if settings.shouldAutoExpand {
                showExpanded()
            }
        } else {
            hideExpanded()
        }
    }

    func applySettings(_ newSettings: AppSettings) {
        precondition(Thread.isMainThread)
        let previousSettings = settings
        settings = newSettings
        frameIndex = 0

        if newSettings.quietMode {
            hideExpanded()
        } else if !previousSettings.shouldAutoExpand,
                  newSettings.shouldAutoExpand,
                  codexIsActive {
            showExpanded()
        }
        syncTrayRegistration()
        updateViews()
    }

    func showExpanded() {
        guard isPrivateTouchBarAvailable, let touchBar else { return }
        collapseTimer?.invalidate()
        collapseTimer = nil
        if let trayItem {
            CTPAddSystemTrayItem(trayItem)
        }
        CTPPresentSystemModalTouchBar(touchBar, Identifier.tray)
        isExpanded = true
        if !settings.keepCompactPet, let trayItem {
            // The private modal API exposes no callback when the user presses
            // the system collapse control. Once presentation has completed,
            // unregister the anchor so that path cannot leave a compact item.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak trayItem] in
                guard let self,
                      self.isExpanded,
                      !self.settings.keepCompactPet,
                      let trayItem else { return }
                CTPRemoveSystemTrayItem(trayItem)
            }
        }
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

            let taskScroll = NSScrollView()
            taskScroll.drawsBackground = false
            taskScroll.borderType = .noBorder
            taskScroll.hasHorizontalScroller = false
            taskScroll.hasVerticalScroller = false
            taskScroll.autohidesScrollers = true
            taskScroll.horizontalScrollElasticity = .automatic
            taskScroll.verticalScrollElasticity = .none
            taskScroll.scrollerStyle = .overlay
            taskScroll.translatesAutoresizingMaskIntoConstraints = false

            let taskStack = NSStackView()
            taskStack.orientation = .horizontal
            taskStack.alignment = .centerY
            taskStack.distribution = .fill
            taskStack.spacing = 6
            taskStack.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 10)
            taskStack.frame = NSRect(x: 0, y: 0, width: 1, height: 28)
            taskScroll.documentView = taskStack

            let connection = NSTextField(labelWithString: connectionStatusLabel)
            connection.alignment = .right
            connection.font = .systemFont(ofSize: 11, weight: .medium)
            connection.lineBreakMode = .byTruncatingTail
            connection.setContentHuggingPriority(.required, for: .horizontal)
            connection.setContentCompressionResistancePriority(.required, for: .horizontal)
            connection.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(primary)
            container.addSubview(taskScroll)
            container.addSubview(connection)
            let preferredWidth = container.widthAnchor.constraint(equalToConstant: 540)
            preferredWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                preferredWidth,
                container.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
                container.heightAnchor.constraint(equalToConstant: 30),
                primary.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                primary.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                taskScroll.leadingAnchor.constraint(equalTo: primary.trailingAnchor, constant: 10),
                taskScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
                taskScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
                taskScroll.trailingAnchor.constraint(equalTo: connection.leadingAnchor, constant: -8),
                connection.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                connection.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                connection.widthAnchor.constraint(equalToConstant: 58)
            ])
            statusLabel = primary
            taskScrollView = taskScroll
            taskStackView = taskStack
            connectionLabel = connection
            rebuildTaskRailIfNeeded(force: true)
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
        if settings.keepCompactPet {
            CTPMinimizeSystemModalTouchBar(touchBar)
        } else {
            CTPDismissSystemModalTouchBar(touchBar)
        }
        isExpanded = false
        syncTrayRegistration()
    }

    private func scheduleTrayRestore() {
        trayRestoreWorkItem?.cancel()
        guard settings.keepCompactPet else {
            if let trayItem {
                CTPRemoveSystemTrayItem(trayItem)
            }
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isExpanded,
                  self.settings.keepCompactPet,
                  let trayItem = self.trayItem else { return }
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
        if shouldAdvancePetAnimation {
            if artwork.animationLoops(for: current.state),
               let frameCount = artwork.animationFrameCount(for: current.state) {
                frameIndex = (frameIndex + 1) % frameCount
            } else {
                frameIndex += 1
            }
        }
        updatePetArtwork()
    }

    private func updateViews() {
        updatePetArtwork()
        trayButton?.bezelColor = compactBackgroundColor
        trayButton?.contentTintColor = nil
        petLabel?.stringValue = face(for: current.state, expanded: true)
        petLabel?.textColor = statusColor
        statusLabel?.stringValue = primaryStatusLabel
        statusLabel?.textColor = statusColor
        rebuildTaskRailIfNeeded()
        connectionLabel?.stringValue = connectionStatusLabel
        connectionLabel?.textColor = connectionColor
    }

    private func updatePetArtwork() {
        let usesSpriteAnimation = artwork.hasAnimatedFrames(for: current.state)
        let frame = effectiveMotion == .standard ? frameIndex : 0
        let image = artwork.image(for: current.state, frameIndex: frame)
        let animatedImage = image.map { usesSpriteAnimation ? $0 : animatedPetImage($0) }
        // Preserve the approved full-color fox. Only the compact button
        // background carries the semantic state color.
        trayButton?.image = animatedImage
        trayButton?.title = image == nil ? face(for: current.state) : ""
        trayButton?.imagePosition = image == nil ? .noImage : .imageOnly
        petImageView?.image = animatedImage
        petImageView?.isHidden = image == nil
        petFallbackLabel?.isHidden = image != nil
    }

    private func animatedPetImage(_ image: NSImage) -> NSImage {
        let motion = petMotion
        let canvas = NSImage(size: image.size)
        canvas.lockFocus()

        let transform = NSAffineTransform()
        transform.translateX(
            by: image.size.width * (0.5 + motion.x),
            yBy: image.size.height * (0.5 + motion.y)
        )
        transform.rotate(byDegrees: motion.rotation)
        transform.scale(by: motion.scale)
        transform.translateX(by: -image.size.width / 2, yBy: -image.size.height / 2)
        transform.concat()
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .sourceOver,
            fraction: motion.opacity
        )
        canvas.unlockFocus()
        canvas.isTemplate = false
        return canvas
    }

    private var petMotion: PetMotion {
        if artwork.hasAnimatedFrames(for: current.state) {
            return PetMotion(scale: 1, x: 0, y: 0, rotation: 0, opacity: 1)
        }
        guard effectiveMotion == .standard else {
            return PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
        }
        switch current.state {
        case .idle, .interrupted, .disconnected:
            let frames: [PetMotion] = [
                PetMotion(scale: 1.08, x: 0, y: -0.006, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: -0.7, opacity: 1),
                PetMotion(scale: 1.12, x: 0, y: 0.008, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0.7, opacity: 1)
            ]
            return frames[frameIndex % frames.count]
        case .working:
            let frames: [PetMotion] = [
                PetMotion(scale: 1.10, x: -0.020, y: 0, rotation: -1.8, opacity: 1),
                PetMotion(scale: 1.13, x: -0.008, y: 0.018, rotation: -0.6, opacity: 1),
                PetMotion(scale: 1.11, x: 0.010, y: 0.004, rotation: 0.8, opacity: 1),
                PetMotion(scale: 1.14, x: 0.024, y: 0.022, rotation: 1.8, opacity: 1),
                PetMotion(scale: 1.11, x: 0.008, y: 0.003, rotation: 0.5, opacity: 1),
                PetMotion(scale: 1.09, x: -0.010, y: -0.008, rotation: -0.8, opacity: 1)
            ]
            return frames[frameIndex % frames.count]
        case .connecting:
            let frames: [PetMotion] = [
                PetMotion(scale: 1.10, x: -0.045, y: 0, rotation: -2.2, opacity: 1),
                PetMotion(scale: 1.12, x: -0.022, y: 0.014, rotation: -1.0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.12, x: 0.022, y: 0.014, rotation: 1.0, opacity: 1),
                PetMotion(scale: 1.10, x: 0.045, y: 0, rotation: 2.2, opacity: 1),
                PetMotion(scale: 1.11, x: 0.022, y: 0.010, rotation: 1.0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.11, x: -0.022, y: 0.010, rotation: -1.0, opacity: 1)
            ]
            return frames[frameIndex % frames.count]
        case .waitingApproval, .waitingInput:
            guard settings.shouldPlayCompletionAndWaitingPrompts else {
                return PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
            }
            let frames: [PetMotion] = [
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.12, x: -0.014, y: 0.014, rotation: -2.5, opacity: 1),
                PetMotion(scale: 1.13, x: -0.020, y: 0.026, rotation: -4.0, opacity: 1),
                PetMotion(scale: 1.12, x: -0.014, y: 0.014, rotation: -2.5, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
            ]
            return frames[frameIndex % frames.count]
        case .completed:
            guard settings.shouldPlayCompletionAndWaitingPrompts,
                  frameIndex < AnimationFrameLimit.completed else {
                return PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
            }
            let frames: [PetMotion] = [
                PetMotion(scale: 1.08, x: 0, y: -0.012, rotation: 0, opacity: 1),
                PetMotion(scale: 1.13, x: -0.016, y: 0.022, rotation: -2.5, opacity: 1),
                PetMotion(scale: 1.16, x: 0, y: 0.050, rotation: 0, opacity: 1),
                PetMotion(scale: 1.13, x: 0.016, y: 0.022, rotation: 2.5, opacity: 1),
                PetMotion(scale: 1.09, x: 0, y: -0.010, rotation: 0, opacity: 1),
                PetMotion(scale: 1.12, x: 0, y: 0.010, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
            ]
            return frames[frameIndex]
        case .failed, .systemError:
            guard frameIndex < AnimationFrameLimit.error else {
                return PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
            }
            let frames: [PetMotion] = [
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1),
                PetMotion(scale: 1.10, x: -0.035, y: 0, rotation: -3.0, opacity: 1),
                PetMotion(scale: 1.10, x: 0.035, y: 0, rotation: 3.0, opacity: 1),
                PetMotion(scale: 1.10, x: -0.024, y: 0, rotation: -2.0, opacity: 1),
                PetMotion(scale: 1.10, x: 0.024, y: 0, rotation: 2.0, opacity: 1),
                PetMotion(scale: 1.09, x: -0.010, y: -0.010, rotation: -1.0, opacity: 1),
                PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
            ]
            return frames[frameIndex]
        }
    }

    private var effectiveMotion: EffectivePetMotion {
        settings.effectiveMotion(
            systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private var shouldAdvancePetAnimation: Bool {
        guard effectiveMotion == .standard else { return false }
        if let frameCount = artwork.animationFrameCount(for: current.state) {
            return artwork.animationLoops(for: current.state) || frameIndex < frameCount - 1
        }
        switch current.state {
        case .waitingApproval, .waitingInput:
            return settings.shouldPlayCompletionAndWaitingPrompts
        case .completed:
            return settings.shouldPlayCompletionAndWaitingPrompts
                && frameIndex < AnimationFrameLimit.completed - 1
        case .failed, .systemError:
            return frameIndex < AnimationFrameLimit.error - 1
        default:
            return true
        }
    }

    private var primaryStatusLabel: String {
        switch current.connectionState {
        case .stale:
            return "状态过期"
        case .incompatible:
            return "不兼容"
        case .disconnected where current.tasks.isEmpty:
            return "未连接"
        default:
            break
        }
        if current.activeCount > 0 {
            return "工作中"
        }
        return current.state.label
    }

    private var taskRailFallbackLabel: String {
        switch current.connectionState {
        case .stale:
            return "最后状态可能已失效"
        case .incompatible:
            return "请查看诊断信息"
        case .disconnected:
            return "等待 Codex 启动"
        case .connecting, .reconnecting:
            return "连接中"
        default:
            return "等待新任务"
        }
    }

    private var visibleTaskRailTasks: [PetTaskStatus] {
        switch current.connectionState {
        case .stale, .incompatible, .disconnected:
            return []
        case .connecting, .reconnecting, .online:
            return current.touchBarTasks
        }
    }

    private func rebuildTaskRailIfNeeded(force: Bool = false) {
        guard let taskScrollView, let taskStackView else { return }

        let visibleTasks = visibleTaskRailTasks
        let visibleIDs = Set(visibleTasks.map(\.threadId))
        taskChipOrder.removeAll { !visibleIDs.contains($0) }
        for task in visibleTasks where !taskChipOrder.contains(task.threadId) {
            taskChipOrder.append(task.threadId)
        }

        var tasksByID: [String: PetTaskStatus] = [:]
        for task in visibleTasks where tasksByID[task.threadId] == nil {
            tasksByID[task.threadId] = task
        }
        let orderedTasks = taskChipOrder.compactMap { tasksByID[$0] }
        let snapshots = orderedTasks.map {
            TaskChipSnapshot(
                threadID: $0.threadId,
                fullTitle: $0.displayTitle,
                abbreviatedTitle: $0.abbreviatedTitle(),
                state: $0.state.animationIdentity
            )
        }
        let fallback = snapshots.isEmpty ? taskRailFallbackLabel : nil
        guard force || snapshots != renderedTaskChips || fallback != renderedTaskFallback else { return }

        let previousOffset = taskScrollView.contentView.bounds.origin.x
        for view in taskStackView.arrangedSubviews {
            taskStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if snapshots.isEmpty {
            let label = NSTextField(labelWithString: fallback ?? "等待新任务")
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            taskStackView.addArrangedSubview(label)
        } else {
            for (task, snapshot) in zip(orderedTasks, snapshots) {
                taskStackView.addArrangedSubview(taskChipButton(for: task, snapshot: snapshot))
            }
        }

        renderedTaskChips = snapshots
        renderedTaskFallback = fallback
        resizeTaskRail(preservingX: previousOffset)
        DispatchQueue.main.async { [weak self] in
            self?.resizeTaskRail(preservingX: previousOffset)
        }
    }

    private func taskChipButton(for task: PetTaskStatus, snapshot: TaskChipSnapshot) -> NSButton {
        let style = taskChipStyle(for: task.state)
        let button = TaskChipButton(
            title: snapshot.abbreviatedTitle,
            target: self,
            action: #selector(openTask(_:))
        )
        button.threadID = snapshot.threadID
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10.5, weight: .semibold)
        button.attributedTitle = NSAttributedString(
            string: snapshot.abbreviatedTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)
            ]
        )
        button.contentTintColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        button.alignment = .center
        button.lineBreakMode = .byTruncatingTail
        button.toolTip = "\(snapshot.fullTitle) · \(style.stateLabel)"
        button.setAccessibilityLabel("\(snapshot.fullTitle)，\(style.stateLabel)")
        button.applyCapsuleStyle(accentColor: style.color)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 26),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 112)
        ])
        return button
    }

    private func taskChipStyle(for state: PetState) -> TaskChipStyle {
        switch state {
        case .working:
            return TaskChipStyle(color: PetState.working(nil).color, stateLabel: "工作中")
        case .waitingApproval:
            return TaskChipStyle(color: .systemOrange, stateLabel: "待确认")
        case .waitingInput:
            return TaskChipStyle(color: .systemOrange, stateLabel: "待回复")
        case .completed:
            return TaskChipStyle(color: .systemGreen, stateLabel: "已完成")
        case .failed:
            return TaskChipStyle(color: .systemRed, stateLabel: "失败")
        case .systemError:
            return TaskChipStyle(color: .systemRed, stateLabel: "系统异常")
        case .interrupted:
            return TaskChipStyle(color: .secondaryLabelColor, stateLabel: "已停止")
        case .idle:
            return TaskChipStyle(color: .secondaryLabelColor, stateLabel: "空闲")
        case .connecting:
            return TaskChipStyle(color: PetState.connecting.color, stateLabel: "连接中")
        case .disconnected:
            return TaskChipStyle(color: PetState.disconnected.color, stateLabel: "未连接")
        }
    }

    private func resizeTaskRail(preservingX offset: CGFloat) {
        guard let taskScrollView, let taskStackView else { return }
        taskStackView.needsLayout = true
        taskStackView.layoutSubtreeIfNeeded()
        let viewportSize = taskScrollView.contentSize
        let width = max(taskStackView.fittingSize.width, viewportSize.width)
        taskStackView.frame = NSRect(x: 0, y: 0, width: width, height: max(1, viewportSize.height))
        let maximumOffset = max(0, width - viewportSize.width)
        taskScrollView.contentView.scroll(to: NSPoint(x: min(max(0, offset), maximumOffset), y: 0))
        taskScrollView.reflectScrolledClipView(taskScrollView.contentView)
    }

    private var connectionStatusLabel: String {
        current.connectionState.label
    }

    private var connectionColor: NSColor {
        current.connectionState.color
    }

    private var statusColor: NSColor {
        if current.connectionState == .stale || current.connectionState == .incompatible {
            return current.connectionState.color
        }
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

    private var compactBackgroundColor: NSColor {
        current.connectionState.compactBackgroundColor ?? current.state.compactBackgroundColor
    }

    private func face(for state: PetState, expanded: Bool = false) -> String {
        let core: String
        let animatedFrame = effectiveMotion == .standard ? frameIndex : 0
        switch state {
        case .idle:
            core = animatedFrame > 0 && animatedFrame % 9 == 0 ? "－ᴥ－" : "•ᴥ•"
        case .working:
            let frames = ["•̀ᴥ•́", "•̀ᴥ•", "•̀ᴥ•́", "•ᴥ•́"]
            core = frames[animatedFrame % frames.count]
        case .connecting:
            let frames = ["•ᴥ•", "•ᴥ•·", "•ᴥ•··", "•ᴥ•···"]
            core = frames[animatedFrame % frames.count]
        case .completed:
            core = animatedFrame > 0 && animatedFrame < AnimationFrameLimit.completed
                ? "ᵔᴥᵔ✧"
                : "ᵔᴥᵔ✦"
        default:
            core = state.compactFace
        }
        return expanded ? "ʕ\(core)ʔ" : core
    }

    private func syncTrayRegistration() {
        guard let trayItem else { return }
        if isExpanded {
            trayRestoreWorkItem?.cancel()
            trayRestoreWorkItem = nil
            CTPAddSystemTrayItem(trayItem)
        } else if settings.keepCompactPet {
            scheduleTrayRestore()
        } else {
            trayRestoreWorkItem?.cancel()
            trayRestoreWorkItem = nil
            CTPRemoveSystemTrayItem(trayItem)
        }
    }

    private func prepareStateCrossfade() {
        let views = [trayButton, petImageView, petFallbackLabel, statusLabel, taskScrollView, connectionLabel]
            .compactMap { $0 }
        views.forEach { view in
            view.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.15
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layer?.add(transition, forKey: "state-crossfade")
        }
    }

    @objc private func activateCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    @objc private func openTask(_ sender: TaskChipButton) {
        guard let deepLink = CodexThreadLink.url(threadID: sender.threadID),
              let codexURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [deepLink],
            withApplicationAt: codexURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}
