/// ShortcutManager.swift

import Cocoa
import CoreGraphics
import MASShortcut

protocol ShortcutBindingStore {
    func configure()
    func registerDefaultShortcuts(_ shortcuts: [String: MASShortcut])
    func bindShortcut(withDefaultsKey defaultsKey: String, toAction action: @escaping () -> Void)
    func breakBinding(withDefaultsKey defaultsKey: String)
}

struct MASShortcutBindingStore: ShortcutBindingStore {
    func configure() {
        MASShortcutBinder.shared()?.bindingOptions = [NSBindingOption.valueTransformerName: MASDictionaryTransformerName]
    }

    func registerDefaultShortcuts(_ shortcuts: [String: MASShortcut]) {
        MASShortcutBinder.shared()?.registerDefaultShortcuts(shortcuts)
    }

    func bindShortcut(withDefaultsKey defaultsKey: String, toAction action: @escaping () -> Void) {
        MASShortcutBinder.shared()?.bindShortcut(withDefaultsKey: defaultsKey, toAction: action)
    }

    func breakBinding(withDefaultsKey defaultsKey: String) {
        MASShortcutBinder.shared()?.breakBinding(withDefaultsKey: defaultsKey)
    }
}

typealias ShortcutRebindScheduler = (@escaping () -> Void) -> Void

class ShortcutManager {

    let windowManager: WindowManager
    private let screenDetection: ScreenDetection
    private let bindingStore: ShortcutBindingStore
    private let mouseButtonBindingStore: MouseButtonBindingStore
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let shortcutsProvider: () -> [WindowAction: MASShortcut]
    private let appDisabledProvider: () -> Bool
    private let windowUnderCursorProvider: (MouseButtonPress) -> AccessibilityElement?
    private let scheduler: ShortcutRebindScheduler
    private let todoSessionStateChanged: (Bool) -> Void
    private var boundShortcutActions = Set<WindowAction>()
    private var shortcutIdentities = [WindowAction: ShortcutCycle.ShortcutIdentity]()
    private var isUpdatingShortcutBindings = false
    private var shortcutsSuspendedForRecording = false
    private var sessionIsActive: Bool
    private var sessionRebindPending = false
    private var sessionGeneration = 0

    init(
        windowManager: WindowManager,
        screenDetection: ScreenDetection = ScreenDetection(),
        bindingStore: ShortcutBindingStore = MASShortcutBindingStore(),
        mouseButtonBindingStore: MouseButtonBindingStore = MouseButtonShortcutMonitor(),
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        shortcutsProvider: @escaping () -> [WindowAction: MASShortcut] = { ShortcutCycle.shortcutsByAction() },
        activeStateProvider: () -> Bool = {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            return session?[kCGSessionOnConsoleKey] as? Bool ?? true
        },
        appDisabledProvider: @escaping () -> Bool = { ApplicationToggle.shortcutsDisabled },
        windowUnderCursorProvider: @escaping (MouseButtonPress) -> AccessibilityElement? = { press in
            AccessibilityElement.getWindowElementUnderCursor(at: press.location, eventWindowID: press.windowId)
        },
        scheduler: @escaping ShortcutRebindScheduler = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: action)
        },
        todoSessionStateChanged: @escaping (Bool) -> Void = { isActive in
            TodoManager.setShortcutBindingsSessionActive(isActive)
            StackBadgeManager.setShortcutBindingsSessionActive(isActive)
        }
    ) {
        self.windowManager = windowManager
        self.screenDetection = screenDetection
        self.bindingStore = bindingStore
        self.mouseButtonBindingStore = mouseButtonBindingStore
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.shortcutsProvider = shortcutsProvider
        self.appDisabledProvider = appDisabledProvider
        self.windowUnderCursorProvider = windowUnderCursorProvider
        self.scheduler = scheduler
        self.todoSessionStateChanged = todoSessionStateChanged
        self.sessionIsActive = activeStateProvider()

        bindingStore.configure()
        todoSessionStateChanged(sessionIsActive)

        registerDefaults()

        bindShortcuts()

        subscribeAll(selector: #selector(windowActionTriggered))

        notificationCenter.addObserver(self, selector: #selector(defaultShortcutsChanged), name: .changeDefaults, object: nil)
        notificationCenter.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(shortcutRecordingChanged), name: .shortcutRecording, object: nil)
        workspaceNotificationCenter.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceNotificationCenter.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    public func reloadFromDefaults() {
        unsubscribeWindowActions()
        unbindShortcuts()
        registerDefaults()
        bindShortcuts()
        subscribeAll(selector: #selector(windowActionTriggered))
    }

    public func bindShortcuts() {
        guard sessionIsActive,
              !sessionRebindPending,
              !shortcutsSuspendedForRecording,
              !appDisabledProvider()
        else { return }

        let shortcutsByAction = shortcutsProvider()
        let groups = ShortcutCycle.groups(shortcutsByAction: shortcutsByAction)

        shortcutIdentities = ShortcutCycle.shortcutIdentities(shortcutsByAction: shortcutsByAction)

        for group in groups {
            let representativeAction = group.representativeAction

            if MouseButtonShortcut.isMouseButton(group.shortcut) {
                mouseButtonBindingStore.bindShortcut(group.shortcut, toAction: { [weak self] press in
                    self?.executeMouseButtonShortcut(group, press: press)
                })
                continue
            }

            boundShortcutActions.insert(representativeAction)

            if group.isCycle {
                bindingStore.bindShortcut(withDefaultsKey: representativeAction.name, toAction: { [weak self] in
                    self?.executeCycle(group)
                })
            } else {
                bindingStore.bindShortcut(withDefaultsKey: representativeAction.name, toAction: representativeAction.post)
            }
        }
    }

    public func unbindShortcuts() {
        isUpdatingShortcutBindings = true
        defer { isUpdatingShortcutBindings = false }

        for action in Set(WindowAction.active).union(boundShortcutActions) {
            bindingStore.breakBinding(withDefaultsKey: action.name)
        }

        boundShortcutActions.removeAll()
        mouseButtonBindingStore.breakAllBindings()
    }

    public func getKeyEquivalent(action: WindowAction) -> (String?, NSEvent.ModifierFlags)? {
        guard let masShortcut = ShortcutCycle.shortcut(for: action),
              !MouseButtonShortcut.isMouseButton(masShortcut)
        else { return nil }
        return (masShortcut.keyCodeStringForKeyEquivalent, masShortcut.modifierFlags)
    }

    deinit {
        notificationCenter.removeObserver(self)
        workspaceNotificationCenter.removeObserver(self)
    }

    private func registerDefaults() {

        let defaultShortcuts = WindowAction.active.reduce(into: [String: MASShortcut]()) { dict, windowAction in
            guard let defaultShortcut = Defaults.alternateDefaultShortcuts.enabled
                ? windowAction.alternateDefault
                : windowAction.spectacleDefault
            else { return }
            let shortcut = MASShortcut(keyCode: defaultShortcut.keyCode, modifierFlags: NSEvent.ModifierFlags(rawValue: defaultShortcut.modifierFlags))
            dict[windowAction.name] = shortcut
        }

        bindingStore.registerDefaultShortcuts(defaultShortcuts)
    }

    @objc private func sessionDidResignActive(_ notification: Notification) {
        guard sessionIsActive else { return }

        sessionIsActive = false
        sessionRebindPending = false
        sessionGeneration &+= 1
        unbindShortcuts()
        todoSessionStateChanged(false)
    }

    @objc private func sessionDidBecomeActive(_ notification: Notification) {
        guard !sessionIsActive else { return }

        sessionIsActive = true
        sessionRebindPending = true
        sessionGeneration &+= 1
        let generation = sessionGeneration

        scheduler { [weak self] in
            guard let self,
                  self.sessionIsActive,
                  self.sessionRebindPending,
                  self.sessionGeneration == generation
            else { return }

            self.sessionRebindPending = false
            self.unbindShortcuts()
            self.bindShortcuts()
            self.todoSessionStateChanged(true)
        }
    }

    @objc func windowActionTriggered(notification: NSNotification) {
        guard let parameters = notification.object as? ExecutionParameters else { return }
        execute(parameters)
    }

    private func execute(_ originalParameters: ExecutionParameters) {
        var parameters = originalParameters
        // Snap previews use completion to dismiss after placement finishes. If this
        // method returns before handing off to WindowManager, finish that cleanup here.
        // After handoff, WindowManager owns completion (including animated moves);
        // running it here as well would dismiss the preview before the move finishes.
        var completionHandledByWindowManager = false
        defer { if !completionHandledByWindowManager { originalParameters.completion?() } }
        Notification.Name.windowActionWillExecute.post(object: parameters)

        if parameters.action == .snapLayoutPicker {
            guard let windowElement = parameters.windowElement ?? AccessibilityElement.getFrontWindowElement() else {
                NSSound.beep()
                return
            }
            let windowId = parameters.windowId ?? windowElement.getWindowId()
            SnapLayoutPickerPanel.shared.show { [weak self] selectedAction in
                self?.execute(ExecutionParameters(
                    selectedAction,
                    windowElement: windowElement,
                    windowId: windowId,
                    source: parameters.source
                ))
            }
            return
        }

        if Defaults.restoreThenMinimize.enabled != false,
           parameters.action == .restore,
           let windowElement = parameters.windowElement ?? AccessibilityElement.getFrontWindowElement(),
           let windowId = parameters.windowId ?? windowElement.getWindowId(),
           let restoreRect = AppDelegate.windowHistory.restoreRects[windowId],
           AppDelegate.windowHistory.consumeRestoreMinimize(
                windowID: windowId,
                currentFrame: windowManager.logicalFrame(for: windowElement),
                restoredFrame: restoreRect
           ) {
            guard windowElement.minimize() else {
                AppDelegate.windowHistory.armRestoreMinimize(windowID: windowId)
                NSSound.beep()
                return
            }
            AppDelegate.windowHistory.restoreRects.removeValue(forKey: windowId)
            AppDelegate.windowHistory.preMaximizeRects.removeValue(forKey: windowId)
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
            return
        }



        if MultiWindowManager.execute(parameters: parameters) {
            return
        }

        if TodoManager.execute(parameters: parameters) {
            return
        }

        // Check if repeat cycles displays
        if Defaults.subsequentExecutionMode.value == .cycleMonitor,
           parameters.source != .titleBar,
           parameters.action.classification != .size,
           parameters.action.classification != .display {
            guard let windowElement = parameters.windowElement ?? AccessibilityElement.getFrontWindowElement(),
                  let windowId = parameters.windowId ?? windowElement.getWindowId()
            else {
                NSSound.beep()
                return
            }

            if isRepeatAction(parameters: parameters, windowElement: windowElement, windowId: windowId),
               RepeatedMaximizeRestore.restoreRect(for: parameters.action, windowId: windowId, windowRect: windowManager.logicalFrame(for: windowElement)) == nil {
                if let screen = screenDetection.detectScreens(using: windowElement)?.adjacentScreens?.next{
                    parameters = ExecutionParameters(parameters.action, updateRestoreRect: parameters.updateRestoreRect, screen: screen, windowElement: windowElement, windowId: windowId, source: parameters.source, preservesFocus: parameters.preservesFocus, completion: parameters.completion, cancellation: parameters.cancellation)
                    // Bypass any other subsequent action by removing the last action
                    AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
                }
            }
        }

        completionHandledByWindowManager = true
        windowManager.execute(parameters)
    }

    /// Mouse buttons work on the focused window, like keys, unless they've
    /// been set to work on the window under the pointer.
    private func executeMouseButtonShortcut(_ group: ShortcutCycle.Group, press: MouseButtonPress) {
        guard Defaults.mouseButtonShortcutsUseWindowUnderCursor.enabled else {
            if group.isCycle {
                executeCycle(group)
            } else {
                execute(ExecutionParameters(group.representativeAction))
            }
            return
        }

        guard let windowElement = windowUnderCursorProvider(press) else {
            NSSound.beep()
            return
        }

        if group.isCycle {
            executeCycle(group, windowUnderCursor: windowElement)
        } else {
            execute(ExecutionParameters(group.representativeAction, windowElement: windowElement,
                                        windowId: windowElement.getWindowId(), preservesFocus: true))
        }
    }

    private func executeCycle(_ group: ShortcutCycle.Group, windowUnderCursor: AccessibilityElement? = nil) {
        guard let windowElement = windowUnderCursor ?? AccessibilityElement.getFrontWindowElement(),
              let windowId = windowElement.getWindowId()
        else {
            NSSound.beep()
            return
        }

        let logicalFrame = windowManager.logicalFrame(for: windowElement)
        let lastAction = AppDelegate.windowHistory.lastRectangleActions[windowId]
        if ShortcutCycle.isStale(lastAction: lastAction, currentWindowRect: logicalFrame) {
            AppDelegate.windowHistory.lastRectangleActions.removeValue(forKey: windowId)
        }

        let selectedAction = ShortcutCycle.action(
            in: group,
            lastAction: AppDelegate.windowHistory.lastRectangleActions[windowId],
            currentWindowRect: logicalFrame
        )
        execute(ExecutionParameters(selectedAction, windowElement: windowElement, windowId: windowId,
                                    preservesFocus: windowUnderCursor != nil))
    }

    @objc private func defaultShortcutsChanged() {
        registerDefaults()
        reloadShortcutBindingsIfNeeded()
    }

    @objc private func userDefaultsChanged(_ notification: Notification) {
        reloadShortcutBindingsIfNeeded()
    }

    private func reloadShortcutBindingsIfNeeded() {
        guard !isUpdatingShortcutBindings && !shortcutsSuspendedForRecording else { return }

        MASShortcutMigration.syncRenamedSideShortcutAliases()
        let currentShortcuts = shortcutsProvider()
        let currentIdentities = ShortcutCycle.shortcutIdentities(shortcutsByAction: currentShortcuts)
        guard currentIdentities != shortcutIdentities else { return }

        unbindShortcuts()
        if !appDisabledProvider() {
            bindShortcuts()
        } else {
            shortcutIdentities = currentIdentities
        }
    }

    @objc private func shortcutRecordingChanged(_ notification: Notification) {
        guard let isRecording = notification.object as? Bool else { return }

        if isRecording {
            guard !shortcutsSuspendedForRecording else { return }
            shortcutsSuspendedForRecording = true
            unbindShortcuts()
        } else {
            guard shortcutsSuspendedForRecording else { return }
            shortcutsSuspendedForRecording = false
            if !appDisabledProvider() {
                bindShortcuts()
            } else {
                let currentShortcuts = shortcutsProvider()
                shortcutIdentities = ShortcutCycle.shortcutIdentities(shortcutsByAction: currentShortcuts)
            }
        }

        TodoManager.setShortcutBindingsSuspended(isRecording)
        StackBadgeManager.setShortcutBindingsSuspended(isRecording)
    }

    private func isRepeatAction(parameters: ExecutionParameters, windowElement: AccessibilityElement, windowId: CGWindowID) -> Bool {

        if parameters.action == .maximize {
            if screenDetection.detectScreens(using: windowElement)?.currentScreen.visibleFrame.size == windowManager.logicalFrame(for: windowElement).size {
                return true
            }
        }
        if parameters.action == AppDelegate.windowHistory.lastRectangleActions[windowId]?.action {
            return true
        }
        return false
    }

    private func subscribe(notification: WindowAction, selector: Selector) {
        notificationCenter.addObserver(self, selector: selector, name: notification.notificationName, object: nil)
    }

    private func unsubscribeWindowActions() {
        for windowAction in WindowAction.active {
            notificationCenter.removeObserver(self, name: windowAction.notificationName, object: nil)
        }
    }

    private func subscribeAll(selector: Selector) {
        for windowAction in WindowAction.active {
            subscribe(notification: windowAction, selector: selector)
        }
    }
}

struct ShortcutCycle {

    struct ShortcutIdentity: Hashable {
        let keyCode: Int
        let modifierFlags: UInt

        init(_ shortcut: MASShortcut) {
            keyCode = shortcut.keyCode
            modifierFlags = shortcut.modifierFlags.rawValue
        }
    }

    struct Group {
        let shortcut: MASShortcut
        let actions: [WindowAction]

        var representativeAction: WindowAction { actions[0] }
        var isCycle: Bool { actions.count > 1 }

        func action(after previousAction: WindowAction?) -> WindowAction {
            guard let previousAction,
                  let index = actions.firstIndex(of: previousAction)
            else {
                return representativeAction
            }

            return actions[(index + 1) % actions.count]
        }
    }

    static func shortcut(for action: WindowAction, userDefaults: UserDefaults = .standard) -> MASShortcut? {
        return shortcut(forDefaultsKey: action.name, userDefaults: userDefaults)
    }

    static func shortcut(forDefaultsKey defaultsKey: String, userDefaults: UserDefaults = .standard) -> MASShortcut? {
        guard let shortcutDict = userDefaults.dictionary(forKey: defaultsKey),
              let dictTransformer = ValueTransformer(forName: NSValueTransformerName(rawValue: MASDictionaryTransformerName)),
              let shortcut = dictTransformer.transformedValue(shortcutDict) as? MASShortcut
        else {
            return nil
        }

        return shortcut
    }

    static func shortcutsByAction(actions: [WindowAction] = WindowAction.active, userDefaults: UserDefaults = .standard) -> [WindowAction: MASShortcut] {
        actions.reduce(into: [WindowAction: MASShortcut]()) { dict, action in
            if let shortcut = shortcut(for: action, userDefaults: userDefaults) {
                dict[action] = shortcut
            }
        }
    }

    static func shortcutIdentities(shortcutsByAction: [WindowAction: MASShortcut]) -> [WindowAction: ShortcutIdentity] {
        shortcutsByAction.reduce(into: [WindowAction: ShortcutIdentity]()) { dict, item in
            dict[item.key] = ShortcutIdentity(item.value)
        }
    }

    static func groups(actions: [WindowAction] = WindowAction.active,
                       shortcutsByAction: [WindowAction: MASShortcut]) -> [Group] {
        var groups = [Group]()
        var groupIndexesByShortcut = [ShortcutIdentity: Int]()

        for action in actions {
            guard let shortcut = shortcutsByAction[action] else { continue }

            let identity = ShortcutIdentity(shortcut)
            if let groupIndex = groupIndexesByShortcut[identity] {
                let group = groups[groupIndex]
                groups[groupIndex] = Group(shortcut: group.shortcut, actions: group.actions + [action])
            } else {
                groupIndexesByShortcut[identity] = groups.count
                groups.append(Group(shortcut: shortcut, actions: [action]))
            }
        }

        return groups
    }

    static func action(in group: Group, lastAction: RectangleAction?, currentWindowRect: CGRect?) -> WindowAction {
        guard !isStale(lastAction: lastAction, currentWindowRect: currentWindowRect) else {
            return group.representativeAction
        }

        return group.action(after: lastAction?.action)
    }

    static func isStale(lastAction: RectangleAction?, currentWindowRect: CGRect?) -> Bool {
        guard let lastAction, let currentWindowRect else { return false }
        return currentWindowRect != lastAction.rect
    }
}


/// A lightweight native picker that routes a selected layout through the existing
/// window-action pipeline. The focused window is captured before the panel appears.
private final class SnapLayoutPickerPanel: NSPanel {
    static let shared = SnapLayoutPickerPanel()

    private var selectionHandler: ((WindowAction) -> Void)?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                   styleMask: [.titled, .closable, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        title = String(localized: "Snap Layouts")
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentView = makeContentView()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(onSelection: @escaping (WindowAction) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            selectionHandler = onSelection
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
            if let screen {
                setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                       y: screen.visibleFrame.midY - frame.height / 2))
            }
            makeKeyAndOrderFront(nil)
        }
    }

    private func makeContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        let subtitle = NSTextField(labelWithString: String(localized: "Choose where to place the front window"))
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        let supportedActions: [WindowAction] = [
            .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .topLeft, .topRight, .bottomLeft, .bottomRight,
            .firstThird, .centerThird, .lastThird,
            .firstTwoThirds, .centerTwoThirds, .lastTwoThirds
        ]
        let actionByID = Dictionary(uniqueKeysWithValues: supportedActions.map { ($0.rawValue, $0) })
        let defaultOrder = supportedActions.map(\\.rawValue)
        let order = Defaults.snapPickerActionOrder.typedValue ?? defaultOrder
        let hidden = Defaults.snapPickerHiddenActions.typedValue ?? []
        let visibleActions = order.compactMap { rawValue -> WindowAction? in
            guard !hidden.contains(rawValue) else { return nil }
            return actionByID[rawValue]
        }
        addLayoutGrid(actions: visibleActions, to: root)

        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelSelection))
        cancel.bezelStyle = .rounded
        let footer = NSStackView(views: [NSView(), cancel])
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        root.addArrangedSubview(footer)
        root.widthAnchor.constraint(equalToConstant: 560).isActive = true

        let container = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func addLayoutGrid(actions: [WindowAction], to root: NSStackView) {
        let label = NSTextField(labelWithString: String(localized: "Available positions"))
        label.font = .boldSystemFont(ofSize: 13)
        root.addArrangedSubview(label)

        guard !actions.isEmpty else {
            let emptyState = NSTextField(labelWithString: String(localized: "All positions are hidden. Enable one in Settings to use the picker."))
            emptyState.textColor = .secondaryLabelColor
            root.addArrangedSubview(emptyState)
            return
        }

        for start in stride(from: 0, to: actions.count, by: 4) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            for action in actions[start..<min(start + 4, actions.count)] {
                let title = action.displayName ?? action.name
                let button = NSButton(title: title, target: self, action: #selector(selectLayout(_:)))
                button.tag = action.rawValue
                button.bezelStyle = .rounded
                button.image = action.image
                button.imagePosition = .imageAbove
                button.setButtonType(.momentaryPushIn)
                button.heightAnchor.constraint(equalToConstant: 64).isActive = true
                row.addArrangedSubview(button)
            }
            root.addArrangedSubview(row)
        }
    }

    @objc private func selectLayout(_ sender: NSButton) {
        guard let action = WindowAction(rawValue: sender.tag) else { return }
        let selection = selectionHandler
        selectionHandler = nil
        orderOut(nil)
        selection?(action)
    }

    @objc private func cancelSelection() {
        selectionHandler = nil
        orderOut(nil)
    }
}
