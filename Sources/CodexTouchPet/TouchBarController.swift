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

/// Auto Layout sizes the playfield, not each animation step. A layer-backed
/// sprite can move locally without invalidating the entire Touch Bar layout.
private final class PetSpriteImageView: NSImageView {
    // Source frames are 192x208; their intrinsic size must not resize the
    // manually laid-out 48x30 Touch Bar sprite when the image changes.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private final class PetPlayfieldView: NSView {
    let imageView = PetSpriteImageView(frame: NSRect(x: 0, y: 0, width: 48, height: 30))
    private var spriteOffset = NSPoint.zero

    func moveSprite(to offset: NSPoint) {
        guard spriteOffset != offset else { return }
        spriteOffset = offset
        positionSprite()
    }

    override func layout() {
        super.layout()
        positionSprite()
    }

    private func positionSprite() {
        let origin = NSPoint(
            x: bounds.midX + spriteOffset.x - imageView.frame.width / 2,
            y: bounds.midY + spriteOffset.y - imageView.frame.height / 2
        )
        if imageView.frame.origin != origin { imageView.setFrameOrigin(origin) }
    }
}

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private enum Identifier {
        static let tray = NSTouchBarItem.Identifier("dev.codex.touch-pet.tray")
        static let content = NSTouchBarItem.Identifier("dev.codex.touch-pet.content")
    }

    let isPrivateTouchBarAvailable = CTPPrivateTouchBarAvailable()
    private(set) var settings = AppSettings()

    private var touchBar: NSTouchBar?
    private var trayItem: NSCustomTouchBarItem?
    private var trayButton: NSButton?
    private var petLabel: NSTextField?
    private var petImageView: NSImageView?
    private var petPlayfield: PetPlayfieldView?
    private var petAreaWidthConstraint: NSLayoutConstraint?
    private var toolPropScene: ToolPropSceneView?
    private var toolSceneProps: [ToolPropIdentity] = []
    private var toolSceneElapsed: TimeInterval = 0
    private var toolSceneLastTick: TimeInterval?
    private var petFallbackLabel: NSTextField?
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
    private var lastAnimationAdvanceAt: CFTimeInterval = 0
    private let animationClock: () -> CFTimeInterval
    private let systemReduceMotion: () -> Bool
    private var idleActivityDirector: PetIdleActivityDirector
    private var renderedIdleActivity: PetIdleActivityDirector.Activity = .wander
    private var renderedIdleSegmentID = 0
    private var idleMotion = PetIdleActivityDirector.Motion(
        activity: .wander,
        x: 0,
        y: 0,
        rotation: 0,
        scale: 1.08
    )
    private var isExpanded = false
    private(set) var codexIsActive = false

    private struct PetMotion: Equatable {
        let scale: CGFloat
        let x: CGFloat
        let y: CGFloat
        let rotation: CGFloat
        let opacity: CGFloat
    }

    private var fallbackArtwork: (source: NSImage, motion: PetMotion, image: NSImage)?

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

    init(
        animationClock: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        systemReduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        idleActivityDirector: PetIdleActivityDirector = PetIdleActivityDirector()
    ) {
        self.animationClock = animationClock
        self.systemReduceMotion = systemReduceMotion
        self.idleActivityDirector = idleActivityDirector
        super.init()
    }

    func start() {
        guard isPrivateTouchBarAvailable else { return }

        let touchBar = NSTouchBar()
        touchBar.delegate = self
        // Keep the expanded UI in one item. macOS may place sibling custom
        // items outside the visible modal area when one of them is principal;
        // a single container keeps the task rail attached to the pet.
        touchBar.defaultItemIdentifiers = [Identifier.content]
        touchBar.principalItemIdentifier = Identifier.content
        self.touchBar = touchBar

        let trayItem = makeTrayItem()
        self.trayItem = trayItem
        // Register immediately at launch; the delayed path is only a recovery
        // for modal/app-activation transitions.
        CTPAddSystemTrayItem(trayItem)
        syncTrayRegistration()

        animationTimer = Timer.scheduledTimer(
            // Tick the director frequently, but advance artwork at a slower,
            // state-specific cadence. This avoids the old 600ms six-frame
            // loop that looked like a fast flicker on the Touch Bar.
            timeInterval: 1.0 / 30.0,
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

    private func makeTrayItem() -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Identifier.tray)
        let button = NSButton(title: "🐾", target: self, action: #selector(toggleExpanded))
        configureTrayButton(button)
        item.view = button
        trayButton = button
        return item
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
            lastAnimationAdvanceAt = 0
            idleActivityDirector.reset()
            renderedIdleActivity = .wander
            renderedIdleSegmentID = 0
            idleMotion = PetIdleActivityDirector.Motion(activity: .wander, x: 0, y: 0, rotation: 0, scale: 1.08)
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
        guard identifier == Identifier.content else { return nil }

        let item = NSCustomTouchBarItem(identifier: identifier)
        let container = NSView()
        let petView = makeExpandedPetView()
        let statusView = makeExpandedStatusView()
        petView.translatesAutoresizingMaskIntoConstraints = false
        statusView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(petView)
        container.addSubview(statusView)
        let petWidth = petView.widthAnchor.constraint(
            equalToConstant: PetActivityLayout.petWidth(wideIdle: usesWideIdlePlayfield)
        )
        petAreaWidthConstraint = petWidth
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: PetActivityLayout.contentWidth),
            container.heightAnchor.constraint(equalToConstant: 30),
            petView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            petView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            petWidth,
            petView.heightAnchor.constraint(equalToConstant: 30),
            statusView.leadingAnchor.constraint(equalTo: petView.trailingAnchor, constant: PetActivityLayout.itemGap),
            statusView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            statusView.heightAnchor.constraint(equalToConstant: 30)
        ])
        taskScrollView?.isHidden = usesWideIdlePlayfield
        item.view = container
        return item
    }

    private func makeExpandedPetView() -> NSView {
        let container = PetPlayfieldView()
        let scene = ToolPropSceneView()
        scene.translatesAutoresizingMaskIntoConstraints = false
        let imageView = container.imageView
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.toolTip = "Codex Touch Bar Pet"
        // This subview is laid out manually by PetPlayfieldView. Do not turn
        // its changing frame back into autoresizing-mask constraints.
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true

        let fallback = NSTextField(labelWithString: face(for: current.state, expanded: true))
        fallback.alignment = .center
        fallback.font = .systemFont(ofSize: 19, weight: .medium)
        fallback.textColor = statusColor
        fallback.toolTip = "Codex Touch Bar Pet"
        fallback.translatesAutoresizingMaskIntoConstraints = false

        // The fox crosses parked props when walking between targets. Keep
        // its face in front throughout those transitions.
        container.addSubview(scene)
        container.addSubview(imageView)
        container.addSubview(fallback)
        NSLayoutConstraint.activate([
            scene.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scene.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scene.topAnchor.constraint(equalTo: container.topAnchor),
            scene.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            fallback.widthAnchor.constraint(equalToConstant: 48),
            fallback.heightAnchor.constraint(equalToConstant: 30),
            fallback.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        petPlayfield = container
        petImageView = imageView
        petFallbackLabel = fallback
        petLabel = fallback
        toolPropScene = scene
        return container
    }

    private func makeExpandedStatusView() -> NSView {
        let container = NSView()
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
        // Do not let the stack stretch a single capsule across the whole
        // viewport; extra space belongs to horizontal scrolling, not the
        // task button itself.
        taskStack.distribution = .equalSpacing
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

        container.addSubview(taskScroll)
        container.addSubview(connection)
        NSLayoutConstraint.activate([
            taskScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            taskScroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            taskScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            taskScroll.trailingAnchor.constraint(equalTo: connection.leadingAnchor, constant: -8),
            connection.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            connection.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            connection.widthAnchor.constraint(equalToConstant: 58)
        ])
        taskScrollView = taskScroll
        taskStackView = taskStack
        connectionLabel = connection
        rebuildTaskRailIfNeeded(force: true)
        return container
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
        // Minimize first so macOS returns to the Control Strip transition, then
        // re-register a fresh compact item after the modal session settles.
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
                  self.settings.keepCompactPet else { return }
            // Re-add the same item after dismissing a modal session. Removing
            // and recreating it can leave the Control Strip cache with a
            // stale item that is registered but not rendered.
            guard let trayItem = self.trayItem else { return }
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
        if current.state == .idle, current.activeCount == 0, current.waitingCount == 0 {
            // Idle poses share the director's segment clock. This also replays
            // a second jump correctly even if its activity enum is unchanged.
            updatePetArtwork()
            return
        }
        let now = animationClock()
        let interval = animationFrameInterval
        if lastAnimationAdvanceAt == 0 {
            lastAnimationAdvanceAt = now
        } else if now - lastAnimationAdvanceAt >= interval, shouldAdvancePetAnimation {
            let elapsed = now - lastAnimationAdvanceAt
            let steps = max(1, min(Int(elapsed / interval), 3))
            lastAnimationAdvanceAt += interval * Double(steps)
            let idleActivity = current.state == .idle ? idleMotion.activity : nil
            if let frameCount = artwork.animationFrameCount(
                for: current.state,
                activity: idleActivity,
                direction: idleMotion.direction
            ) {
                if artwork.animationLoops(
                    for: current.state,
                    activity: idleActivity,
                    direction: idleMotion.direction
                ) {
                    frameIndex = (frameIndex + steps) % frameCount
                } else {
                    frameIndex = min(frameIndex + steps, frameCount - 1)
                }
            } else {
                frameIndex += steps
            }
        }
        updatePetArtwork()
    }

    private func updateViews() {
        updatePlayfieldLayout()
        updatePetArtwork()
        if let trayButton { configureTrayButton(trayButton) }
        petLabel?.stringValue = face(for: current.state, expanded: true)
        petLabel?.textColor = statusColor
        rebuildTaskRailIfNeeded()
        connectionLabel?.stringValue = connectionStatusLabel
        connectionLabel?.textColor = connectionColor
    }

    private func updatePetArtwork() {
        updateIdleMotion()
        let idleActivity = current.state == .idle ? idleMotion.activity : nil
        let usesSpriteAnimation = artwork.hasAnimatedFrames(
            for: current.state,
            activity: idleActivity,
            direction: idleMotion.direction
        )
        let frame = effectiveMotion == .standard ? frameIndex : 0
        let image = artwork.image(
            for: current.state,
            activity: idleActivity,
            direction: idleMotion.direction,
            frameIndex: frame
        )
        let animatedImage = image.map { usesSpriteAnimation ? $0 : fallbackPetImage($0) }
        let toolScene = updateToolScene()
        petPlayfield?.moveSprite(to: toolScene.position ?? NSPoint(x: idleMotion.x, y: idleMotion.y))
        // Preserve the approved full-color fox. Only the compact button
        // background carries the semantic state color.
        if let trayButton {
            if trayButton.image !== animatedImage { trayButton.image = animatedImage }
            let title = image == nil ? face(for: current.state) : ""
            if trayButton.title != title { trayButton.title = title }
            let position: NSControl.ImagePosition = image == nil ? .noImage : .imageOnly
            if trayButton.imagePosition != position { trayButton.imagePosition = position }
        }
        if let petImageView {
            let pose = toolScene.pose ?? animatedImage
            if petImageView.image !== pose { petImageView.image = pose }
            if petImageView.isHidden != (image == nil) { petImageView.isHidden = image == nil }
        }
        if let petFallbackLabel, petFallbackLabel.isHidden != (image != nil) {
            petFallbackLabel.isHidden = image != nil
        }
    }

    private func updateToolScene() -> (pose: NSImage?, position: NSPoint?) {
        let props: [ToolProp]
        if current.activeCount > 0, current.connectionState == .online { props = current.toolProps }
        else { props = [] }
        let identities = props.map(\.identity)
        let now = animationClock()
        if identities != toolSceneProps {
            toolSceneProps = identities
            toolSceneElapsed = 0
            toolSceneLastTick = now
        }
        let working: Bool
        if case .working = current.state { working = true } else { working = false }
        let animated = effectiveMotion == .standard && working
        if let previous = toolSceneLastTick, animated {
            toolSceneElapsed += max(0, min(0.1, now - previous))
        }
        toolSceneLastTick = now
        toolPropScene?.update(props: props, elapsed: toolSceneElapsed, animated: animated)
        guard !props.isEmpty else { return (nil, nil) }
        // A waiting sibling has visual priority, but must not hide software
        // still in use by another thread. Keep those props parked and retain
        // the waiting fox instead of borrowing a working/play pose.
        guard working else {
            return (nil, NSPoint(x: ToolPropChoreography.foxX - PetActivityLayout.normalPetWidth / 2, y: 0))
        }
        let sample = ToolPropChoreography.sample(elapsed: toolSceneElapsed, count: props.count, animated: animated)
        // The compact button retains the working fox. Only the expanded
        // scene borrows the approved ground-walk and paw/tail-play poses.
        let pose = artwork.image(for: .idle, activity: sample.walking ? .run : .play,
            direction: sample.direction, frameIndex: sample.foxFrame)
        return (pose, NSPoint(x: sample.foxX - PetActivityLayout.normalPetWidth / 2, y: 0))
    }

    private func configureTrayButton(_ button: NSButton) {
        // The compact entry follows the square system control-strip treatment;
        // task chips remain capsules in the expanded task rail.
        button.isBordered = false
        button.bezelStyle = .texturedSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = 0
        button.layer?.masksToBounds = true
        button.layer?.backgroundColor = compactBackgroundColor.cgColor
        button.contentTintColor = nil
        button.imageScaling = .scaleProportionallyUpOrDown
    }

    private var animationFrameInterval: CFTimeInterval {
        if current.state == .idle {
            return idleMotion.activity.frameInterval
        }
        switch current.state {
        case .idle:
            return 0.24
        case .working:
            return 0.16
        case .connecting, .disconnected:
            return 0.20
        case .waitingApproval, .waitingInput:
            return 0.22
        case .completed, .failed, .systemError, .interrupted:
            return 0.18
        }
    }

    private func updateIdleMotion() {
        guard petPlayfield != nil else { return }
        guard current.state == .idle,
              current.activeCount == 0,
              current.waitingCount == 0,
              effectiveMotion == .standard else {
            idleActivityDirector.reset()
            renderedIdleActivity = .wander
            renderedIdleSegmentID = 0
            idleMotion = PetIdleActivityDirector.Motion(activity: .wander, x: 0, y: 0, rotation: 0, scale: 1.08)
            return
        }
        idleMotion = idleActivityDirector.motion(
            at: animationClock(),
            travel: PetActivityLayout.travel(wideIdle: usesWideIdlePlayfield)
        )
        if idleMotion.segmentID != renderedIdleSegmentID {
            if idleMotion.activity != renderedIdleActivity {
                preparePetPoseCrossfade()
            }
            renderedIdleActivity = idleMotion.activity
            renderedIdleSegmentID = idleMotion.segmentID
            frameIndex = 0
            lastAnimationAdvanceAt = 0
        }
        frameIndex = Int(idleMotion.elapsed / idleMotion.activity.frameInterval)
    }

    private var usesWideIdlePlayfield: Bool {
        current.state == .idle
            && current.connectionState == .online
            && current.activeCount == 0
            && current.waitingCount == 0
            && current.touchBarTasks.isEmpty
    }

    private func updatePlayfieldLayout() {
        let wideIdle = usesWideIdlePlayfield
        let width = PetActivityLayout.petWidth(wideIdle: wideIdle)
        if let petAreaWidthConstraint, petAreaWidthConstraint.constant != width {
            idleActivityDirector.reset()
            renderedIdleActivity = .wander
            renderedIdleSegmentID = 0
            idleMotion = PetIdleActivityDirector.Motion(activity: .wander, x: 0, y: 0, rotation: 0, scale: 1)
            frameIndex = 0
            lastAnimationAdvanceAt = 0
            petAreaWidthConstraint.constant = width
        }
        taskScrollView?.isHidden = wideIdle
    }

    private func preparePetPoseCrossfade() {
        for view in [trayButton, petImageView].compactMap({ $0 }) {
            view.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.10
            view.layer?.add(transition, forKey: "petPose")
        }
    }

    private func fallbackPetImage(_ image: NSImage) -> NSImage {
        let motion = petMotion
        if let fallbackArtwork, fallbackArtwork.source === image, fallbackArtwork.motion == motion {
            return fallbackArtwork.image
        }
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
        fallbackArtwork = (image, motion, canvas)
        return canvas
    }

    private var petMotion: PetMotion {
        let idleActivity = current.state == .idle ? idleMotion.activity : nil
        if artwork.hasAnimatedFrames(
            for: current.state,
            activity: idleActivity,
            direction: idleMotion.direction
        ) {
            return PetMotion(scale: 1, x: 0, y: 0, rotation: 0, opacity: 1)
        }
        guard effectiveMotion == .standard else {
            return PetMotion(scale: 1.10, x: 0, y: 0, rotation: 0, opacity: 1)
        }
        switch current.state {
        case .idle:
            return PetMotion(
                scale: idleMotion.scale,
                x: 0,
                y: idleMotion.y / 30,
                rotation: idleMotion.rotation,
                opacity: 1
            )
        case .interrupted, .disconnected:
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
            systemReduceMotion: systemReduceMotion()
        )
    }

    private var shouldAdvancePetAnimation: Bool {
        guard effectiveMotion == .standard else { return false }
        let idleActivity = current.state == .idle ? idleMotion.activity : nil
        if let frameCount = artwork.animationFrameCount(
            for: current.state,
            activity: idleActivity,
            direction: idleMotion.direction
        ) {
            return artwork.animationLoops(
                for: current.state,
                activity: idleActivity,
                direction: idleMotion.direction
            )
                || frameIndex < frameCount - 1
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
        case .online where current.state == .idle && current.activeCount == 0 && current.waitingCount == 0:
            return ""
        default:
            return ""
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
        let fallbackText = snapshots.isEmpty ? taskRailFallbackLabel : ""
        let fallback = fallbackText.isEmpty ? nil : fallbackText
        guard force || snapshots != renderedTaskChips || fallback != renderedTaskFallback else { return }

        let previousOffset = taskScrollView.contentView.bounds.origin.x
        for view in taskStackView.arrangedSubviews {
            taskStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if snapshots.isEmpty, let fallback {
            let label = NSTextField(labelWithString: fallback)
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
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.toolTip = "\(snapshot.fullTitle) · \(style.stateLabel)"
        button.setAccessibilityLabel("\(snapshot.fullTitle)，\(style.stateLabel)")
        button.applyCapsuleStyle(accentColor: style.color)
        button.translatesAutoresizingMaskIntoConstraints = false
        let width = min(112, max(64, button.intrinsicContentSize.width))
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 26),
            button.widthAnchor.constraint(equalToConstant: width)
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
        let views = [trayButton, petImageView, petFallbackLabel, taskScrollView, connectionLabel]
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
