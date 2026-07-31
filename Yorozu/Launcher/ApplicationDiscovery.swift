import AppKit
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
            let homeApplications = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
            self.roots = [
                (homeApplications, 0),
                (URL(fileURLWithPath: "/Applications", isDirectory: true), 1),
                (URL(fileURLWithPath: "/System/Applications", isDirectory: true), 2),
            ]
        }
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
