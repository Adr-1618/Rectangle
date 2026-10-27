import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers
import Darwin

struct GesturePathPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct GestureActionStep: Codable, Equatable, Identifiable {
    var id: String
    var kind: GestureActionKind
    var value: String
    var path: String
    var label: String

    init(kind: GestureActionKind) {
        id = UUID().uuidString
        self.kind = kind
        value = kind == .delay ? "1" : ""
        path = ""
        label = ""
    }
}

enum GestureActionKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case windowAction, openApplication, runShortcut
    case saveFullScreenshot, saveSelectionScreenshot, copyFullScreenshot, copySelectionScreenshot
    case delay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windowAction: String(localized: "SnapGrid Window Action")
        case .openApplication: String(localized: "Open Application")
        case .runShortcut: String(localized: "Run Apple Shortcut")
        case .saveFullScreenshot: String(localized: "Save Full Screenshot")
        case .saveSelectionScreenshot: String(localized: "Save Selected Area")
        case .copyFullScreenshot: String(localized: "Copy Full Screenshot")
        case .copySelectionScreenshot: String(localized: "Copy Selected Area")
        case .delay: String(localized: "Wait")
        }
    }

    var symbolName: String {
        switch self {
        case .windowAction: "rectangle.inset.filled"
        case .openApplication: "app"
        case .runShortcut: "command"
        case .saveFullScreenshot, .saveSelectionScreenshot: "camera"
        case .copyFullScreenshot, .copySelectionScreenshot: "doc.on.clipboard"
        case .delay: "clock"
        }
    }

    var description: String? {
        switch self {
        case .saveFullScreenshot, .saveSelectionScreenshot:
            String(localized: "macOS saves the capture using its current screenshot settings.")
        case .copyFullScreenshot, .copySelectionScreenshot:
            String(localized: "The screenshot is placed on the clipboard.")
        case .runShortcut:
            String(localized: "Run a workflow from the Apple Shortcuts app.")
        case .delay:
            String(localized: "Pause before running the next action.")
        default:
            nil
        }
    }
}

struct CustomTrackpadGesture: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var path: [GesturePathPoint]
    var actions: [GestureActionStep]

    init(name: String, path: [GesturePathPoint]) {
        id = UUID().uuidString
        self.name = name
        self.path = path
        actions = []
    }
}

private enum TrackpadGesturePreference {
    static let enabled = "SnapGrid.TrackpadGestures.enabled"
    static let definitions = "SnapGrid.TrackpadGestures.definitions"
}

private struct PrivateTrackpadPoint { var x: Float; var y: Float }
private struct PrivateTrackpadVector { var position: PrivateTrackpadPoint; var velocity: PrivateTrackpadPoint }
private struct PrivateTrackpadTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalizedPosition: PrivateTrackpadVector
    var size: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolutePosition: PrivateTrackpadVector
    var field14: Int32
    var field15: Int32
    var density: Float
}

private typealias PrivateTrackpadFrameCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Void

/// Global trackpad recognition uses Apple's private MultitouchSupport framework.
/// It starts only after the user enables custom gestures in Preferences.
final class TrackpadGestureManager {
    static let shared = TrackpadGestureManager()

    private let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private let matchThreshold = 0.24
    private var framework: UnsafeMutableRawPointer?
    private var devices: [UnsafeMutableRawPointer] = []
    private var stopDevice: ((UnsafeMutableRawPointer?) -> Void)?
    private var frameCallback: PrivateTrackpadFrameCallback?
    private var wakeObserver: NSObjectProtocol?
    private(set) var isRunning = false

    private let stateLock = NSLock()
    private var livePath = [GesturePathPoint]()
    private var recordingCompletion: (([GesturePathPoint]?) -> Void)?

    private init() {}

    @discardableResult
    func refresh() -> Bool {
        guard UserDefaults.standard.bool(forKey: TrackpadGesturePreference.enabled) else {
            stop()
            return false
        }
        guard CGPreflightListenEventAccess() else {
            stop()
            return false
        }
        guard !isRunning else { return true }
        guard loadFrameworkAndStartDevices() else {
            isRunning = false
            return false
        }
        isRunning = true
        installWakeObserverIfNeeded()
        return true
    }

    func stop() {
        guard isRunning || !devices.isEmpty else { return }
        if let stopDevice {
            for device in devices { stopDevice(device) }
        }
        devices.removeAll()
        isRunning = false
        stateLock.lock()
        livePath.removeAll()
        recordingCompletion = nil
        stateLock.unlock()
    }

    @discardableResult
    func beginRecording(completion: @escaping ([GesturePathPoint]?) -> Void) -> Bool {
        guard isRunning else { return false }
        stateLock.lock()
        livePath.removeAll()
        recordingCompletion = completion
        stateLock.unlock()
        return true
    }

    func cancelRecording() {
        stateLock.lock()
        livePath.removeAll()
        recordingCompletion = nil
        stateLock.unlock()
    }

    private func loadFrameworkAndStartDevices() -> Bool {
        if framework == nil { framework = dlopen(frameworkPath, RTLD_NOW) }
        guard let framework,
              let createDeviceList: (@convention(c) () -> Unmanaged<CFMutableArray>?) = symbol("MTDeviceCreateList", from: framework),
              let registerFrameCallback: (@convention(c) (UnsafeMutableRawPointer?, PrivateTrackpadFrameCallback?) -> Void) = symbol("MTRegisterContactFrameCallback", from: framework),
              let startDevice: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Void) = symbol("MTDeviceStart", from: framework),
              let stopDevice: (@convention(c) (UnsafeMutableRawPointer?) -> Void) = symbol("MTDeviceStop", from: framework),
              let deviceList = createDeviceList()?.takeUnretainedValue(),
              CFArrayGetCount(deviceList) > 0
        else { return false }

        self.stopDevice = stopDevice
        let callback: PrivateTrackpadFrameCallback = { _, rawTouches, count, _, _ in
            let touches = rawTouches?.assumingMemoryBound(to: PrivateTrackpadTouch.self)
            TrackpadGestureManager.shared.receiveFrame(touches, count: Int(count))
        }
        frameCallback = callback

        for index in 0..<CFArrayGetCount(deviceList) {
            guard let device = CFArrayGetValueAtIndex(deviceList, index) else { continue }
            let pointer = UnsafeMutableRawPointer(mutating: device)
            registerFrameCallback(pointer, callback)
            startDevice(pointer, 0)
            devices.append(pointer)
        }
        return !devices.isEmpty
    }

    private func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer) -> T? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private func installWakeObserverIfNeeded() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stop()
            _ = self.refresh()
        }
    }

    private func receiveFrame(_ touches: UnsafeMutablePointer<PrivateTrackpadTouch>?, count: Int) {
        var active = [PrivateTrackpadTouch]()
        if let touches {
            for index in 0..<max(0, count) where touches[index].state == 4 {
                active.append(touches[index])
            }
        }

        stateLock.lock()
        if active.isEmpty {
            guard !livePath.isEmpty else {
                stateLock.unlock()
                return
            }
            let captured = livePath
            livePath.removeAll()
            let completion = recordingCompletion
            recordingCompletion = nil
            stateLock.unlock()

            guard let normalized = GesturePathRecognition.normalized(captured) else {
                if let completion { DispatchQueue.main.async { completion(nil) } }
                return
            }
            if let completion {
                DispatchQueue.main.async { completion(normalized) }
            } else {
                DispatchQueue.main.async { [weak self] in self?.recognize(normalized) }
            }
            return
        }

        if active.count == 3 {
            let x = active.reduce(Float.zero) { $0 + $1.normalizedPosition.position.x } / 3
            let y = active.reduce(Float.zero) { $0 + $1.normalizedPosition.position.y } / 3
            let point = GesturePathPoint(x: Double(x), y: Double(y))
            if let last = livePath.last {
                if hypot(point.x - last.x, point.y - last.y) > 0.006 { livePath.append(point) }
            } else {
                livePath.append(point)
            }
        }
        stateLock.unlock()
    }

    private func recognize(_ input: [GesturePathPoint]) {
        guard UserDefaults.standard.bool(forKey: TrackpadGesturePreference.enabled) else { return }
        let definitions = Self.loadDefinitions()
        guard !definitions.isEmpty else { return }

        let match = definitions
            .map { (gesture: $0, distance: GesturePathRecognition.distance(input, $0.path)) }
            .filter { $0.distance <= matchThreshold }
            .min { $0.distance < $1.distance }
        if let match { runActions(match.gesture.actions, index: 0) }
    }

    private func runActions(_ actions: [GestureActionStep], index: Int) {
        guard actions.indices.contains(index) else { return }
        let step = actions[index]
        switch step.kind {
        case .windowAction:
            if let action = WindowAction.active.first(where: { $0.name == step.value }) { action.post() }
            continueActions(actions, index: index, delay: 0.25)
        case .openApplication:
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: step.value)
                ?? (step.path.isEmpty ? nil : URL(fileURLWithPath: step.path))
            guard let appURL else { continueActions(actions, index: index, delay: 0.1); return }
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                DispatchQueue.main.async { self.runActions(actions, index: index + 1) }
            }
        case .runShortcut:
            guard !step.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continueActions(actions, index: index, delay: 0.1)
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", step.value]
            process.terminationHandler = { _ in
                DispatchQueue.main.async { self.runActions(actions, index: index + 1) }
            }
            do { try process.run() }
            catch { continueActions(actions, index: index, delay: 0.1) }
        case .saveFullScreenshot:
            postScreenshotShortcut(keyCode: 20, copyToClipboard: false)
            continueActions(actions, index: index, delay: 0.25)
        case .saveSelectionScreenshot:
            postScreenshotShortcut(keyCode: 21, copyToClipboard: false)
            continueActions(actions, index: index, delay: 0.25)
        case .copyFullScreenshot:
            postScreenshotShortcut(keyCode: 20, copyToClipboard: true)
            continueActions(actions, index: index, delay: 0.25)
        case .copySelectionScreenshot:
            postScreenshotShortcut(keyCode: 21, copyToClipboard: true)
            continueActions(actions, index: index, delay: 0.25)
        case .delay:
            continueActions(actions, index: index, delay: min(max(Double(step.value) ?? 1, 0.1), 30))
        }
    }

    private func continueActions(_ actions: [GestureActionStep], index: Int, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.runActions(actions, index: index + 1)
        }
    }

    private func postScreenshotShortcut(keyCode: CGKeyCode, copyToClipboard: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        var flags: CGEventFlags = [.maskCommand, .maskShift]
        if copyToClipboard { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func loadDefinitions() -> [CustomTrackpadGesture] {
        guard let data = UserDefaults.standard.data(forKey: TrackpadGesturePreference.definitions),
              let decoded = try? JSONDecoder().decode([CustomTrackpadGesture].self, from: data)
        else { return [] }
        return decoded
    }

    deinit {
        stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let framework { dlclose(framework) }
    }
}

private enum GesturePathRecognition {
    private static let sampleCount = 48

    static func normalized(_ points: [GesturePathPoint]) -> [GesturePathPoint]? {
        guard points.count >= 8 else { return nil }
        let samples = resample(points)
        guard !samples.isEmpty else { return nil }
        let minX = samples.map(\.x).min() ?? 0
        let maxX = samples.map(\.x).max() ?? 0
        let minY = samples.map(\.y).min() ?? 0
        let maxY = samples.map(\.y).max() ?? 0
        let scale = max(maxX - minX, maxY - minY)
        guard scale > 0.04 else { return nil }
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        return samples.map { GesturePathPoint(x: ($0.x - centerX) / scale, y: ($0.y - centerY) / scale) }
    }

    static func distance(_ first: [GesturePathPoint], _ second: [GesturePathPoint]) -> Double {
        guard first.count == sampleCount, second.count == sampleCount else { return .infinity }
        func meanDistance(reversed: Bool) -> Double {
            first.indices.reduce(0.0) { sum, index in
                let other = second[reversed ? second.count - 1 - index : index]
                return sum + hypot(first[index].x - other.x, first[index].y - other.y)
            } / Double(first.count)
        }
        return min(meanDistance(reversed: false), meanDistance(reversed: true))
    }

    private static func resample(_ points: [GesturePathPoint]) -> [GesturePathPoint] {
        guard points.count > 1 else { return [] }
        var distances = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            distances[index] = distances[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        guard let total = distances.last, total > 0 else { return [] }

        var result = [GesturePathPoint]()
        result.reserveCapacity(sampleCount)
        var segment = 1
        for sample in 0..<sampleCount {
            let target = total * Double(sample) / Double(sampleCount - 1)
            while segment < distances.count - 1 && distances[segment] < target { segment += 1 }
            let segmentStart = distances[segment - 1]
            let segmentLength = distances[segment] - segmentStart
            let fraction = segmentLength == 0 ? 0 : (target - segmentStart) / segmentLength
            let start = points[segment - 1]
            let end = points[segment]
            result.append(GesturePathPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            ))
        }
        return result
    }
}


@available(macOS 11.0, *)
final class TrackpadGesturesViewController: NSViewController {
    private var hostingController: NSHostingController<TrackpadGesturesSettingsView>!

    override func viewDidLoad() {
        super.viewDidLoad()
        hostingController = NSHostingController(rootView: TrackpadGesturesSettingsView())
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

@available(macOS 11.0, *)
private struct TrackpadGesturesSettingsView: View {
    @AppStorage(TrackpadGesturePreference.enabled) private var isEnabled = false
    @State private var gestures = [CustomTrackpadGesture]()
    @State private var accessReady = false
    @State private var isRecording = false
    @State private var pendingPath = [GesturePathPoint]()
    @State private var gestureName = ""
    @State private var isNamingGesture = false
    @State private var actionSearch = ""
    @State private var captureStatus = ""

    private var availableActions: [WindowAction] {
        WindowAction.active
            .filter { actionSearch.isEmpty || ($0.settingsDisplayName ?? $0.displayName ?? $0.name).localizedCaseInsensitiveContains(actionSearch) }
            .sorted { ($0.settingsDisplayName ?? $0.displayName ?? $0.name).localizedStandardCompare($1.settingsDisplayName ?? $1.displayName ?? $1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Custom Trackpad Gestures")
                        .font(.largeTitle.weight(.semibold))
                    Text("Draw a shape with three fingers, then attach an ordered series of actions.")
                        .foregroundColor(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Enable custom gestures", isOn: $isEnabled)
                            .onChange(of: isEnabled) { _ in
                                accessReady = TrackpadGestureManager.shared.refresh()
                            }
                        Text(statusText)
                            .font(.callout)
                            .foregroundColor(accessReady || !isEnabled ? Color.secondary : Color.orange)

                        HStack(spacing: 10) {
                            if isRecording {
                                Button("Cancel Recording") {
                                    TrackpadGestureManager.shared.cancelRecording()
                                    isRecording = false
                                    captureStatus = String(localized: "Recording cancelled.")
                                }
                            } else {
                                Button("Record New Gesture") { recordGesture() }
                                    .disabled(!isEnabled || !accessReady)
                            }
                            Button("Request Permission") {
                                _ = CGRequestListenEventAccess()
                                accessReady = TrackpadGestureManager.shared.refresh()
                            }
                            Button("Open Input Monitoring Settings") { openInputMonitoringSettings() }
                            Button("Check Access") {
                                accessReady = TrackpadGestureManager.shared.refresh()
                            }
                            .disabled(!isEnabled || isRecording)
                        }
                        if !captureStatus.isEmpty {
                            Text(captureStatus)
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Gesture Capture", systemImage: "hand.draw")
                }

                HStack {
                    Text("Your Gestures")
                        .font(.headline)
                    Spacer()
                    TextField("Filter window actions", text: $actionSearch)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }

                if gestures.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "scribble.variable")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("No gestures recorded yet")
                            .font(.headline)
                        Text("Enable gestures and record a shape such as an X.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .background(Color(NSColor.controlBackgroundColor)).cornerRadius(14)
                } else {
                    VStack(spacing: 14) {
                        ForEach(gestures.indices, id: \.self) { index in
                            CustomGestureCard(
                                gesture: $gestures[index],
                                actions: availableActions,
                                isEnabled: isEnabled,
                                onDelete: { gestures.remove(at: index) }
                            )
                        }
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SnapGrid needs Input Monitoring to read trackpad movement. It listens only while custom gestures are enabled.")
                        Text("macOS may also act on three-finger movement. If a gesture conflicts, adjust it in System Settings → Trackpad → More Gestures.")
                        Text("A gesture is recorded and recognized as a continuous path made with three fingers.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Permissions and Compatibility", systemImage: "lock.shield")
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear {
            gestures = TrackpadGestureManager.loadDefinitions()
            accessReady = TrackpadGestureManager.shared.refresh()
        }
        .onChange(of: gestures) { newValue in
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: "SnapGrid.TrackpadGestures.definitions")
        }
        .sheet(isPresented: $isNamingGesture) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Name This Gesture").font(.headline)
                Text("Give the movement a name, for example X.")
                    .foregroundColor(.secondary)
                TextField("Gesture Name", text: $gestureName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { pendingPath.removeAll(); isNamingGesture = false }
                    Button("Save") { saveRecordedGesture(); isNamingGesture = false }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
        .frame(minWidth: 820, minHeight: 680)
    }

    private var statusText: String {
        if !isEnabled { return String(localized: "Gestures are off until you enable them.") }
        if accessReady { return String(localized: "Ready. Draw a saved shape with three fingers anywhere on the trackpad.") }
        return String(localized: "Allow Input Monitoring, then choose Check Access. Gestures stay inactive until you enable them.")
    }

    private func recordGesture() {
        guard TrackpadGestureManager.shared.beginRecording(completion: { path in
            isRecording = false
            guard let path else {
                captureStatus = String(localized: "Gesture was too short. Try recording it again.")
                return
            }
            pendingPath = path
            gestureName = ""
            captureStatus = ""
            isNamingGesture = true
        }) else {
            accessReady = TrackpadGestureManager.shared.refresh()
            return
        }
        captureStatus = String(localized: "Draw one continuous shape with three fingers, then lift them.")
        isRecording = true
    }

    private func saveRecordedGesture() {
        let trimmedName = gestureName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, pendingPath.count >= 8 else { return }
        gestures.append(CustomTrackpadGesture(name: trimmedName, path: pendingPath))
        pendingPath.removeAll()
        gestureName = ""
        captureStatus = String(localized: "Gesture saved. Add one or more actions below it.")
    }

    private func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }
}

@available(macOS 11.0, *)
private struct CustomGestureCard: View {
    @Binding var gesture: CustomTrackpadGesture
    let actions: [WindowAction]
    let isEnabled: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                GesturePathPreview(points: gesture.path)
                    .frame(width: 82, height: 66)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Gesture Name", text: $gesture.name)
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                    Text("\(gesture.actions.count) " + String(localized: "Actions"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete Gesture")
            }

            if gesture.actions.isEmpty {
                Text("Add actions to run when this shape is recognized.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                ForEach(gesture.actions.indices, id: \.self) { index in
                    actionRow(at: index)
                    if index < gesture.actions.count - 1 { Divider() }
                }
            }

            Menu {
                ForEach(GestureActionKind.allCases) { kind in
                    Button {
                        gesture.actions.append(GestureActionStep(kind: kind))
                    } label: {
                        Label(kind.title, systemImage: kind.symbolName)
                    }
                }
            } label: {
                Label("Add Action", systemImage: "plus")
            }
            .disabled(!isEnabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor)).cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.18), lineWidth: 1))
    }

    @ViewBuilder
    private func actionRow(at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(gesture.actions[index].kind.title, systemImage: gesture.actions[index].kind.symbolName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button { moveAction(at: index, offset: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Move Action Up")
                Button { moveAction(at: index, offset: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == gesture.actions.count - 1)
                    .help("Move Action Down")
                Button { gesture.actions.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove Action")
            }
            actionConfiguration(at: index)
                .disabled(!isEnabled)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionConfiguration(at index: Int) -> some View {
        switch gesture.actions[index].kind {
        case .windowAction:
            Picker("Window Action", selection: $gesture.actions[index].value) {
                Text("Choose an action").tag("")
                ForEach(actions, id: \.name) { action in
                    Text(action.settingsDisplayName ?? action.displayName ?? action.name).tag(action.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .openApplication:
            Button(gesture.actions[index].label.isEmpty ? "Choose Application…" : gesture.actions[index].label) {
                chooseApplication(at: index)
            }
            .buttonStyle(.bordered)
        case .runShortcut:
            TextField("Name in Apple Shortcuts", text: $gesture.actions[index].value)
                .textFieldStyle(.roundedBorder)
        case .saveFullScreenshot, .saveSelectionScreenshot, .copyFullScreenshot, .copySelectionScreenshot:
            Text(gesture.actions[index].kind.description ?? "")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .delay:
            HStack {
                Text("Wait")
                TextField("Seconds", text: $gesture.actions[index].value)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("Seconds")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func moveAction(at index: Int, offset: Int) {
        let destination = index + offset
        guard gesture.actions.indices.contains(destination) else { return }
        gesture.actions.swapAt(index, destination)
    }

    private func chooseApplication(at index: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        gesture.actions[index].path = url.path
        gesture.actions[index].value = Bundle(url: url)?.bundleIdentifier ?? ""
        gesture.actions[index].label = url.deletingPathExtension().lastPathComponent
    }
}

@available(macOS 11.0, *)
private struct GesturePathPreview: View {
    let points: [GesturePathPoint]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard !points.isEmpty else { return }
                let mapped = points.map { point in
                    CGPoint(
                        x: geometry.size.width * (point.x + 0.5),
                        y: geometry.size.height * (0.5 - point.y)
                    )
                }
                path.move(to: mapped[0])
                for point in mapped.dropFirst() { path.addLine(to: point) }
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .padding(8)
        }
    }
}
