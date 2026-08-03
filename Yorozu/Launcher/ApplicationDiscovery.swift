import AppKit
import CoreServices
import Foundation

actor FileSystemApplicationDiscoverer: ApplicationDiscovering {
    private struct Candidate: Sendable {
        let application: DiscoveredApplication
    }

    private let ownBundleIdentifier: String
    private let roots: [(url: URL, priority: Int)]

    init(
        ownBundleIdentifier: String = "com.yorozu.app",
        roots: [(URL, Int)]? = nil
    ) {
        self.ownBundleIdentifier = ownBundleIdentifier
        if let roots {
            self.roots = roots
        } else {
            self.roots = Self.standardRoots()
        }
    }

    nonisolated static func standardRoots() -> [(url: URL, priority: Int)] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        return [
            (homeApplications, 0),
            (URL(fileURLWithPath: "/Applications", isDirectory: true), 1),
            (URL(fileURLWithPath: "/System/Applications", isDirectory: true), 2),
        ]
    }

    func discoverApplications() async throws -> [DiscoveredApplication] {
        var candidates: [Candidate] = []
        for root in roots where FileManager.default.fileExists(atPath: root.url.path) {
            try Task.checkCancellation()
            candidates.append(
                contentsOf: try scan(root: root.url, priority: root.priority)
            )
        }

        let grouped = Dictionary(grouping: candidates, by: \.application.id)
        var selected: [DiscoveredApplication] = []
        selected.reserveCapacity(grouped.count)

        for (_, group) in grouped {
            try Task.checkCancellation()
            if group.count == 1, let application = group.first?.application {
                selected.append(application)
                continue
            }

            let bundleIdentifier = group.compactMap(\.application.bundleIdentifier).first
            let preferredURL: URL?
            if let bundleIdentifier {
                preferredURL = await MainActor.run {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)?
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                }
            } else {
                preferredURL = nil
            }

            if let winner = Self.selectCandidate(
                group.map(\.application),
                preferredURL: preferredURL
            ) {
                selected.append(winner)
            }
        }

        return selected.sorted {
            ($0.localizedName ?? $0.displayName)
                .localizedStandardCompare($1.localizedName ?? $1.displayName) == .orderedAscending
        }
    }

    nonisolated static func selectCandidate(
        _ candidates: [DiscoveredApplication],
        preferredURL: URL?
    ) -> DiscoveredApplication? {
        if let preferredURL,
           let preferred = candidates.first(where: {
               $0.canonicalURL.standardizedFileURL == preferredURL.standardizedFileURL
           }) {
            return preferred
        }
        return candidates.min {
            if $0.rootPriority != $1.rootPriority {
                return $0.rootPriority < $1.rootPriority
            }
            return $0.canonicalURL.path < $1.canonicalURL.path
        }
    }

    private func scan(root: URL, priority: Int) throws -> [Candidate] {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var candidates: [Candidate] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() == "app",
                  let application = makeApplication(url: url, rootPriority: priority) else {
                continue
            }
            candidates.append(Candidate(application: application))
        }
        return candidates
    }

    private func makeApplication(
        url: URL,
        rootPriority: Int
    ) -> DiscoveredApplication? {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: canonicalURL),
              let executableURL = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        let bundleIdentifier = bundle.bundleIdentifier
        guard bundleIdentifier != ownBundleIdentifier else { return nil }

        let localizedInfo = bundle.localizedInfoDictionary ?? [:]
        let info = bundle.infoDictionary ?? [:]
        let localizedName =
            localizedInfo["CFBundleDisplayName"] as? String
            ?? localizedInfo["CFBundleName"] as? String
        let displayName =
            info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? canonicalURL.deletingPathExtension().lastPathComponent
        let version = info["CFBundleShortVersionString"] as? String
        let identity: ApplicationIdentity
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            identity = ApplicationIdentity(rawValue: "bundle:\(bundleIdentifier.lowercased())")
        } else {
            identity = ApplicationIdentity(rawValue: "path:\(canonicalURL.path)")
        }

        let normalizedSearchText = [
            localizedName,
            displayName,
            bundleIdentifier,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .launcherNormalized

        return DiscoveredApplication(
            id: identity,
            bundleIdentifier: bundleIdentifier,
            canonicalURL: canonicalURL,
            displayName: displayName,
            localizedName: localizedName,
            version: version,
            normalizedSearchText: normalizedSearchText,
            rootPriority: rootPriority
        )
    }
}

/// Watches the same roots as application discovery without adding work to palette presentation.
/// FSEvents coalesces filesystem changes before this callback reaches the app.
final class ApplicationDirectoryMonitor: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let onChange: @Sendable () -> Void

        init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, context, numberOfEvents, _, flags, _ in
        guard numberOfEvents > 0, let context else { return }

        let eventFlags = UnsafeBufferPointer(
            start: flags,
            count: numberOfEvents
        )
        let containsRelevantEvent = eventFlags.contains { flag in
            flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0
        }
        guard containsRelevantEvent else { return }

        Unmanaged<CallbackBox>
            .fromOpaque(context)
            .takeUnretainedValue()
            .onChange()
    }

    private let roots: [URL]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(
        label: "com.yorozu.app.application-index-monitor",
        qos: .utility
    )
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    init(
        roots: [URL]? = nil,
        latency: TimeInterval = 0.75,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.roots = roots
            ?? FileSystemApplicationDiscoverer.standardRoots().map(\.url)
        self.latency = latency
        self.onChange = onChange
    }

    @discardableResult
    func start() -> Bool {
        queue.sync {
            guard stream == nil else { return true }

            let box = CallbackBox(onChange: onChange)
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            guard let newStream = FSEventStreamCreate(
                nil,
                Self.callback,
                &context,
                roots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagWatchRoot
                        | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagUseCFTypes
                )
            ) else {
                return false
            }

            callbackBox = box
            stream = newStream
            FSEventStreamSetDispatchQueue(newStream, queue)
            guard FSEventStreamStart(newStream) else {
                FSEventStreamInvalidate(newStream)
                FSEventStreamRelease(newStream)
                stream = nil
                callbackBox = nil
                return false
            }
            return true
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            callbackBox = nil
        }
    }

    deinit {
        stop()
    }
}
