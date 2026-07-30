import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
@preconcurrency import LinkPresentation

enum LauncherPerformanceTrace {
    private static let log = OSLog(
        subsystem: "com.yorozu.app",
        category: .pointsOfInterest
    )

    static func duration(
        _ name: StaticString,
        startedAt: TimeInterval
    ) {
        #if DEBUG
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        os_signpost(
            .event,
            log: log,
            name: name,
            "duration_ms=%{public}.3f",
            milliseconds
        )
        #endif
    }
}

struct ClipboardRecordingSettings: Sendable {
    let isEnabled: Bool
    let isPaused: Bool
    let retentionDays: Int
    let maximumItems: Int
    let excludedBundleIdentifiers: Set<String>
}

@MainActor
final class ClipboardPreferences: ObservableObject {
    private enum Key {
        static let isEnabled = "clipboard.isEnabled"
        static let isPaused = "clipboard.isPaused"
        static let retentionDays = "clipboard.retentionDays"
        static let maximumItems = "clipboard.maximumItems"
        static let excludedBundleIdentifiers = "clipboard.excludedBundleIdentifiers"
        static let loadURLPreviews = "clipboard.loadURLPreviews"
    }

    static let defaultExcludedBundleIdentifiers: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
    ]

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    @Published var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Key.isPaused) }
    }

    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    @Published var maximumItems: Int {
        didSet { defaults.set(maximumItems, forKey: Key.maximumItems) }
    }

    @Published var excludedBundleIdentifiers: Set<String> {
        didSet {
            defaults.set(
                Array(excludedBundleIdentifiers).sorted(),
                forKey: Key.excludedBundleIdentifiers
            )
        }
    }

    @Published var loadURLPreviews: Bool {
        didSet { defaults.set(loadURLPreviews, forKey: Key.loadURLPreviews) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.isEnabled: false,
            Key.isPaused: false,
            Key.retentionDays: 30,
            Key.maximumItems: 2_000,
            Key.excludedBundleIdentifiers: Array(Self.defaultExcludedBundleIdentifiers),
            Key.loadURLPreviews: false,
        ])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        isPaused = defaults.bool(forKey: Key.isPaused)
        retentionDays = max(1, defaults.integer(forKey: Key.retentionDays))
        maximumItems = max(1, defaults.integer(forKey: Key.maximumItems))
        let stored = defaults.stringArray(forKey: Key.excludedBundleIdentifiers)
            ?? Array(Self.defaultExcludedBundleIdentifiers)
        excludedBundleIdentifiers = Set(stored)
        loadURLPreviews = defaults.bool(forKey: Key.loadURLPreviews)
    }

    var recordingSettings: ClipboardRecordingSettings {
        ClipboardRecordingSettings(
            isEnabled: isEnabled,
            isPaused: isPaused,
            retentionDays: max(1, retentionDays),
            maximumItems: max(1, maximumItems),
            excludedBundleIdentifiers: excludedBundleIdentifiers
        )
    }

    func setExcluded(_ isExcluded: Bool, bundleIdentifier: String) {
        if isExcluded {
            excludedBundleIdentifiers.insert(bundleIdentifier)
        } else {
            excludedBundleIdentifiers.remove(bundleIdentifier)
        }
    }
}

enum URLPreviewState: Equatable {
    case idle
    case loading(URL)
    case ready(URL, Data)
    case unavailable(URL, URLPreviewUnavailableReason)
}

enum URLPreviewUnavailableReason: Equatable {
    case restrictedAddress
    case failed
}

@MainActor
final class URLPreviewService: ObservableObject {
    @Published private(set) var state: URLPreviewState = .idle

    private static let cacheLifetime: TimeInterval = 7 * 86_400
    private let store: LauncherStore?
    private var delayedTask: Task<Void, Never>?
    private var metadataProvider: LPMetadataProvider?
    private var requestID = UUID()
    private var requestedRawURL: String?
    private var requestedEnabled = false

    init(store: LauncherStore?) {
        self.store = store
    }

    func load(rawURL: String, isEnabled: Bool) {
        guard requestedRawURL != rawURL || requestedEnabled != isEnabled else {
            return
        }
        cancel(resetState: true)
        requestedRawURL = rawURL
        requestedEnabled = isEnabled
        guard isEnabled else { return }
        guard let url = URLPreviewPolicy.previewableURL(from: rawURL) else {
            if let fallbackURL = URL(string: rawURL) {
                state = .unavailable(fallbackURL, .restrictedAddress)
            }
            return
        }

        let currentRequestID = UUID()
        requestID = currentRequestID
        state = .loading(url)
        delayedTask = Task { [weak self] in
            guard let self else { return }
            if await self.loadCachedMetadata(for: url, requestID: currentRequestID) {
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self.fetchMetadata(for: url, requestID: currentRequestID)
        }
    }

    func cancel(resetState: Bool = false) {
        requestedRawURL = nil
        requestedEnabled = false
        requestID = UUID()
        delayedTask?.cancel()
        delayedTask = nil
        metadataProvider?.cancel()
        metadataProvider = nil
        if resetState {
            state = .idle
        }
    }

    private func loadCachedMetadata(for url: URL, requestID: UUID) async -> Bool {
        guard self.requestID == requestID else { return false }

        if let cachedEntry = try? await store?.loadURLPreview(
            url: url.absoluteString,
            newerThan: Date().addingTimeInterval(-Self.cacheLifetime)
        ) {
            guard self.requestID == requestID, !Task.isCancelled else { return false }
            state = .ready(url, cachedEntry.metadataData)
            return true
        }
        return false
    }

    private func fetchMetadata(for url: URL, requestID: UUID) {
        guard self.requestID == requestID else { return }

        let provider = LPMetadataProvider()
        provider.shouldFetchSubresources = true
        provider.timeout = 8
        metadataProvider = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, error in
            let metadataData: Data?
            if error == nil, let metadata {
                metadataData = try? NSKeyedArchiver.archivedData(
                    withRootObject: metadata,
                    requiringSecureCoding: true
                )
            } else {
                metadataData = nil
            }
            Task { @MainActor [weak self] in
                await self?.finish(
                    url: url,
                    requestID: requestID,
                    metadataData: metadataData
                )
            }
        }
    }

    private func finish(
        url: URL,
        requestID: UUID,
        metadataData: Data?
    ) async {
        guard self.requestID == requestID else { return }
        metadataProvider = nil
        guard let metadataData else {
            state = .unavailable(url, .failed)
            return
        }

        state = .ready(url, metadataData)
        try? await store?.saveURLPreview(
            URLPreviewCacheEntry(
                url: url.absoluteString,
                metadataData: metadataData,
                fetchedAt: Date()
            )
        )
    }
}

@MainActor
final class SystemPasteboardReader {
    private static let ignoredTypes = Set([
        "org.nspasteboard.TransientType",
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType",
    ])

    var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    func readSnapshot(
        excluding excludedBundleIdentifiers: Set<String>
    ) -> RawClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.ignoredTypes) else { return nil }

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let sourceBundleIdentifier = sourceApplication?.bundleIdentifier
        if sourceBundleIdentifier == Bundle.main.bundleIdentifier
            || sourceBundleIdentifier.map(excludedBundleIdentifiers.contains) == true {
            return nil
        }

        let content: RawPasteboardContent
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL], !urls.isEmpty {
            let paths = urls
                .map { $0 as URL }
                .filter(\.isFileURL)
                .map { $0.standardizedFileURL.path }
            guard !paths.isEmpty, paths.count <= 100 else { return nil }
            content = .files(paths)
        } else if let data = pasteboard.data(forType: .png), !data.isEmpty {
            content = .image(data, format: .png)
        } else if let data = pasteboard.data(forType: .tiff), !data.isEmpty {
            content = .image(data, format: .tiff)
        } else if let value = pasteboard.string(forType: .string) {
            guard !value.isEmpty,
                  value.lengthOfBytes(using: .utf8) <= 1_048_576 else {
                return nil
            }
            content = .string(value)
        } else {
            return nil
        }

        return RawClipboardSnapshot(
            content: content,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceApplicationName: sourceApplication?.localizedName,
            copiedAt: Date()
        )
    }
}

enum RawImageFormat: Sendable {
    case png
    case tiff
}

enum RawPasteboardContent: Sendable {
    case string(String)
    case files([String])
    case image(Data, format: RawImageFormat)
}

struct RawClipboardSnapshot: Sendable {
    let content: RawPasteboardContent
    let sourceBundleIdentifier: String?
    let sourceApplicationName: String?
    let copiedAt: Date
}

actor ClipboardCaptureProcessor {
    private static let maximumImageBytes = 20 * 1_024 * 1_024
    private static let maximumRawImageBytes = 64 * 1_024 * 1_024

    func process(_ snapshot: RawClipboardSnapshot) -> ClipboardCapture? {
        guard !Task.isCancelled else { return nil }

        let content: PasteboardContent
        let imageWidth: Int?
        let imageHeight: Int?
        switch snapshot.content {
        case let .string(value):
            if let url = URL(string: value),
               let scheme = url.scheme,
               !scheme.isEmpty,
               !url.isFileURL {
                content = .url(value)
            } else {
                content = .text(value)
            }
            imageWidth = nil
            imageHeight = nil
        case let .files(paths):
            content = .files(paths)
            imageWidth = nil
            imageHeight = nil
        case let .image(data, format):
            guard data.count <= Self.maximumRawImageBytes,
                  let image = Self.processImage(data, format: format),
                  image.data.count <= Self.maximumImageBytes else {
                return nil
            }
            content = .image(image.data)
            imageWidth = image.width
            imageHeight = image.height
        }

        guard !Task.isCancelled else { return nil }
        let hash = SHA256.hash(data: content.hashInput)
            .map { String(format: "%02x", $0) }
            .joined()
        let kind: ClipboardItemKind
        let textContent: String?
        let filePaths: [String]
        let imageData: Data?
        switch content {
        case let .text(value):
            kind = .text
            textContent = value
            filePaths = []
            imageData = nil
        case let .url(value):
            kind = .url
            textContent = value
            filePaths = []
            imageData = nil
        case let .files(paths):
            kind = .files
            textContent = nil
            filePaths = paths
            imageData = nil
        case let .image(data):
            kind = .image
            textContent = nil
            filePaths = []
            imageData = data
        }

        return ClipboardCapture(
            id: UUID(),
            kind: kind,
            contentHash: hash,
            textContent: textContent,
            filePaths: filePaths,
            imageData: imageData,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            normalizedSearchText: content.searchText.launcherNormalized,
            sourceBundleIdentifier: snapshot.sourceBundleIdentifier,
            sourceApplicationName: snapshot.sourceApplicationName,
            copiedAt: snapshot.copiedAt
        )
    }

    private nonisolated static func processImage(
        _ data: Data,
        format: RawImageFormat
    ) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }

        if format == .png {
            return (data, width, height)
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, width, height)
    }
}

private extension PasteboardContent {
    var hashInput: Data {
        switch self {
        case let .text(value):
            return Data("text\u{0}\(value)".utf8)
        case let .url(value):
            return Data("url\u{0}\(value)".utf8)
        case let .files(paths):
            return Data("files\u{0}\(paths.joined(separator: "\u{0}"))".utf8)
        case let .image(data):
            var value = Data("image\u{0}".utf8)
            value.append(data)
            return value
        }
    }
}

actor ClipboardMonitor {
    private let reader: SystemPasteboardReader
    private let processor: ClipboardCaptureProcessor
    private let preferences: ClipboardPreferences
    private let catalog: ClipboardCatalog
    private let onSnapshot: @MainActor @Sendable (FeatureSnapshot<ClipboardItem>) -> Void
    private var task: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var lastChangeCount = -1
    private var suppressionDeadline = Date.distantPast

    init(
        reader: SystemPasteboardReader,
        processor: ClipboardCaptureProcessor = ClipboardCaptureProcessor(),
        preferences: ClipboardPreferences,
        catalog: ClipboardCatalog,
        onSnapshot: @escaping @MainActor @Sendable (FeatureSnapshot<ClipboardItem>) -> Void
    ) {
        self.reader = reader
        self.processor = processor
        self.preferences = preferences
        self.catalog = catalog
        self.onSnapshot = onSnapshot
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        captureTask?.cancel()
        captureTask = nil
    }

    func suppress(for duration: Duration = .seconds(2)) {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let interval = Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
        suppressionDeadline = Date().addingTimeInterval(interval)
    }

    private func runLoop() async {
        var wasRecording = false
        while !Task.isCancelled {
            let settings = await preferences.recordingSettings
            let isRecording = settings.isEnabled && !settings.isPaused
            if isRecording {
                if wasRecording {
                    await poll(settings: settings)
                } else {
                    // Establish a new baseline so content copied while recording
                    // was disabled or paused is never imported retroactively.
                    lastChangeCount = await reader.changeCount
                    wasRecording = true
                }
                try? await Task.sleep(for: .milliseconds(350))
            } else {
                wasRecording = false
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll(settings: ClipboardRecordingSettings) async {
        let changeCount = await reader.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard Date() >= suppressionDeadline else { return }

        guard let rawSnapshot = await reader.readSnapshot(
            excluding: settings.excludedBundleIdentifiers
        ) else {
            return
        }

        captureGeneration += 1
        let generation = captureGeneration
        captureTask?.cancel()
        captureTask = Task { [processor, catalog, onSnapshot] in
            let captureStartedAt = ProcessInfo.processInfo.systemUptime
            guard let capture = await processor.process(rawSnapshot),
                  !Task.isCancelled else {
                return
            }
            LauncherPerformanceTrace.duration(
                "clipboard_capture",
                startedAt: captureStartedAt
            )

            let persistenceStartedAt = ProcessInfo.processInfo.systemUptime
            let snapshot = await catalog.record(
                capture,
                retentionDays: settings.retentionDays,
                maximumItems: settings.maximumItems
            )
            LauncherPerformanceTrace.duration(
                "clipboard_persistence",
                startedAt: persistenceStartedAt
            )
            guard !Task.isCancelled else { return }
            await self.publish(snapshot, generation: generation, using: onSnapshot)
        }
    }

    private func publish(
        _ snapshot: FeatureSnapshot<ClipboardItem>,
        generation: Int,
        using callback: @MainActor @Sendable (FeatureSnapshot<ClipboardItem>) -> Void
    ) async {
        guard generation == captureGeneration else { return }
        await callback(snapshot)
    }
}

struct PasteboardTypeData: Equatable, Sendable {
    let type: String
    let data: Data
}

struct PasteboardItemSnapshot: Equatable, Sendable {
    let values: [PasteboardTypeData]
}

enum PasteResult: Equatable, Sendable {
    case pasted
    case copiedBecausePermissionDenied
    case copiedBecauseTargetUnavailable
    case copiedBecauseActivationFailed
    case failed
}

@MainActor
protocol PasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> [PasteboardItemSnapshot]
    func write(_ content: PasteboardContent) -> Bool
    func restore(_ snapshots: [PasteboardItemSnapshot])
}

@MainActor
final class SystemPasteboardAccessor: PasteboardAccessing {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            PasteboardItemSnapshot(
                values: item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return PasteboardTypeData(type: type.rawValue, data: data)
                }
            )
        }
    }

    func write(_ content: PasteboardContent) -> Bool {
        pasteboard.clearContents()
        switch content {
        case let .text(value):
            return pasteboard.setString(value, forType: .string)
        case let .url(value):
            let item = NSPasteboardItem()
            item.setString(value, forType: .string)
            item.setString(value, forType: .URL)
            return pasteboard.writeObjects([item])
        case let .files(paths):
            let urls = paths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return false }
            return pasteboard.writeObjects(urls as [NSURL])
        case let .image(data):
            guard !data.isEmpty else { return false }
            return pasteboard.setData(data, forType: .png)
        }
    }

    func restore(_ snapshots: [PasteboardItemSnapshot]) {
        pasteboard.clearContents()
        let items = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for value in snapshot.values {
                item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

@MainActor
protocol PasteTargetApplication: AnyObject {
    var isActive: Bool { get }
    var isTerminated: Bool { get }
    @discardableResult
    func activate() -> Bool
}

@MainActor
final class RunningApplicationPasteTarget: PasteTargetApplication {
    private let application: NSRunningApplication

    init(application: NSRunningApplication) {
        self.application = application
    }

    var isActive: Bool {
        application.isActive
    }

    var isTerminated: Bool {
        application.isTerminated
    }

    @discardableResult
    func activate() -> Bool {
        application.activate(options: [])
    }
}

@MainActor
struct PasteCoordinatorDependencies {
    var isAccessibilityTrusted: () -> Bool
    var postPasteShortcut: () -> Bool
    var sleep: (Duration) async -> Void
    var activationPollInterval: Duration
    var activationPollAttempts: Int
    var activationGracePeriod: Duration
    var restorationDelay: Duration

    static let live = PasteCoordinatorDependencies(
        isAccessibilityTrusted: {
            AXIsProcessTrusted()
        },
        postPasteShortcut: {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(
                      keyboardEventSource: source,
                      virtualKey: 0x09,
                      keyDown: true
                  ),
                  let keyUp = CGEvent(
                      keyboardEventSource: source,
                      virtualKey: 0x09,
                      keyDown: false
                  ) else {
                return false
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        },
        sleep: { duration in
            try? await Task.sleep(for: duration)
        },
        activationPollInterval: .milliseconds(40),
        activationPollAttempts: 25,
        activationGracePeriod: .milliseconds(20),
        restorationDelay: .milliseconds(800)
    )
}

@MainActor
final class PasteCoordinator {
    private enum ActivationWaitResult {
        case active
        case unavailable
        case timedOut
    }

    private let pasteboard: any PasteboardAccessing
    private let suppressClipboardMonitor: (Duration) async -> Void
    private let dependencies: PasteCoordinatorDependencies

    init(monitor: ClipboardMonitor) {
        pasteboard = SystemPasteboardAccessor()
        suppressClipboardMonitor = { duration in
            await monitor.suppress(for: duration)
        }
        dependencies = .live
    }

    init(
        pasteboard: any PasteboardAccessing,
        suppressClipboardMonitor: @escaping (Duration) async -> Void,
        dependencies: PasteCoordinatorDependencies
    ) {
        self.pasteboard = pasteboard
        self.suppressClipboardMonitor = suppressClipboardMonitor
        self.dependencies = dependencies
    }

    var isAccessibilityGranted: Bool {
        dependencies.isAccessibilityTrusted()
    }

    func copy(_ content: PasteboardContent) async -> Bool {
        await suppressClipboardMonitor(.seconds(2))
        return pasteboard.write(content)
    }

    func paste(
        _ content: PasteboardContent,
        into targetApplication: NSRunningApplication?,
        completion: @escaping @MainActor (PasteResult) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(.failed)
                return
            }
            let target = targetApplication.map {
                RunningApplicationPasteTarget(application: $0)
            }
            completion(await performPaste(content, into: target))
        }
    }

    func performPaste(
        _ content: PasteboardContent,
        into targetApplication: (any PasteTargetApplication)?
    ) async -> PasteResult {
        let original = pasteboard.snapshot()
        await suppressClipboardMonitor(.seconds(2))
        guard pasteboard.write(content) else {
            return .failed
        }

        let injectedChangeCount = pasteboard.changeCount
        guard let targetApplication else {
            return .copiedBecauseTargetUnavailable
        }
        guard dependencies.isAccessibilityTrusted() else {
            if !targetApplication.isTerminated {
                targetApplication.activate()
            }
            return .copiedBecausePermissionDenied
        }
        guard !targetApplication.isTerminated else {
            return .copiedBecauseTargetUnavailable
        }
        guard targetApplication.activate() else {
            return .copiedBecauseActivationFailed
        }

        switch await waitForActivation(of: targetApplication) {
        case .active:
            break
        case .unavailable:
            return .copiedBecauseTargetUnavailable
        case .timedOut:
            return .copiedBecauseActivationFailed
        }

        await dependencies.sleep(dependencies.activationGracePeriod)
        guard !targetApplication.isTerminated else {
            return .copiedBecauseTargetUnavailable
        }
        guard targetApplication.isActive else {
            return .copiedBecauseActivationFailed
        }
        guard dependencies.postPasteShortcut() else {
            return .failed
        }

        await dependencies.sleep(dependencies.restorationDelay)
        if pasteboard.changeCount == injectedChangeCount {
            await suppressClipboardMonitor(.seconds(2))
            pasteboard.restore(original)
        }
        return .pasted
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func waitForActivation(
        of targetApplication: any PasteTargetApplication
    ) async -> ActivationWaitResult {
        if targetApplication.isActive {
            return .active
        }

        for _ in 0..<max(1, dependencies.activationPollAttempts) {
            if Task.isCancelled || targetApplication.isTerminated {
                return .unavailable
            }
            await dependencies.sleep(dependencies.activationPollInterval)
            if targetApplication.isActive {
                return .active
            }
        }

        return targetApplication.isTerminated ? .unavailable : .timedOut
    }
}
