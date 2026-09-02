import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

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
        didSet {
            defaults.set(isEnabled, forKey: Key.isEnabled)
            recordingSettingsDidChange?(recordingSettings)
        }
    }

    @Published var isPaused: Bool {
        didSet {
            defaults.set(isPaused, forKey: Key.isPaused)
            recordingSettingsDidChange?(recordingSettings)
        }
    }

    @Published var retentionDays: Int {
        didSet {
            defaults.set(retentionDays, forKey: Key.retentionDays)
            recordingSettingsDidChange?(recordingSettings)
        }
    }

    @Published var maximumItems: Int {
        didSet {
            defaults.set(maximumItems, forKey: Key.maximumItems)
            recordingSettingsDidChange?(recordingSettings)
        }
    }

    @Published var excludedBundleIdentifiers: Set<String> {
        didSet {
            defaults.set(
                Array(excludedBundleIdentifiers).sorted(),
                forKey: Key.excludedBundleIdentifiers
            )
            recordingSettingsDidChange?(recordingSettings)
        }
    }

    @Published var loadURLPreviews: Bool {
        didSet { defaults.set(loadURLPreviews, forKey: Key.loadURLPreviews) }
    }

    private let defaults: UserDefaults
    var recordingSettingsDidChange: ((ClipboardRecordingSettings) -> Void)?

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
        let storedMaximumItems = defaults.integer(forKey: Key.maximumItems)
        let clampedMaximumItems = min(2_000, max(1, storedMaximumItems))
        maximumItems = clampedMaximumItems
        if clampedMaximumItems != storedMaximumItems {
            defaults.set(clampedMaximumItems, forKey: Key.maximumItems)
        }
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
            maximumItems: min(2_000, max(1, maximumItems)),
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
    case ready(URL, URLPreviewDocument)
    case unavailable(URL, URLPreviewUnavailableReason)
}

enum URLPreviewUnavailableReason: Equatable {
    case restrictedAddress
    case failed
}

struct URLPreviewDocument: Codable, Equatable, Sendable {
    let title: String
    let siteName: String?
    let imageData: Data?
}

protocol URLPreviewFetching: Sendable {
    func fetch(_ url: URL) async throws -> URLPreviewDocument
}

enum SafeURLPreviewError: Error, Equatable {
    case restrictedAddress
    case invalidResponse
    case redirectLimitExceeded
    case contentTooLarge
    case invalidContentType
    case invalidImage
}

actor SafeURLPreviewFetcher: URLPreviewFetching {
    typealias AddressResolver = @Sendable (String) async throws -> [String]
    typealias ResponseLoader = @Sendable (
        URL,
        Int,
        [String]
    ) async throws -> SafeURLHTTPResponse

    private static let maximumHTMLBytes = 1 * 1_024 * 1_024
    private static let maximumImageBytes = 5 * 1_024 * 1_024
    private static let maximumRedirects = 5
    private let resolveAddresses: AddressResolver
    private let loadResponse: ResponseLoader

    init(
        resolveAddresses: @escaping AddressResolver = SafeURLPreviewFetcher
            .resolveAddresses,
        loadResponse: @escaping ResponseLoader = { url, maximumBytes, mimeTypes in
            try await BoundedURLRequest(
                url: url,
                maximumBytes: maximumBytes,
                acceptedMIMETypes: mimeTypes
            ).start()
        }
    ) {
        self.resolveAddresses = resolveAddresses
        self.loadResponse = loadResponse
    }

    func fetch(_ url: URL) async throws -> URLPreviewDocument {
        let htmlResponse = try await load(
            url,
            maximumBytes: Self.maximumHTMLBytes,
            acceptedMIMETypes: ["text/html"]
        )
        guard let html = String(data: htmlResponse.data, encoding: .utf8)
                ?? String(data: htmlResponse.data, encoding: .isoLatin1) else {
            throw SafeURLPreviewError.invalidResponse
        }
        let metadata = BoundedHTMLMetadataParser.parse(html)
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = htmlResponse.finalURL.host() ?? htmlResponse.finalURL.absoluteString
        var imageData: Data?
        if let imageValue = metadata.image,
           let imageURL = URL(
               string: imageValue,
               relativeTo: htmlResponse.finalURL
           )?.absoluteURL {
            imageData = try? await loadPreviewImage(imageURL)
        }
        let displayTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        return URLPreviewDocument(
            title: displayTitle,
            siteName: metadata.siteName,
            imageData: imageData
        )
    }

    private func loadPreviewImage(_ url: URL) async throws -> Data {
        let response = try await load(
            url,
            maximumBytes: Self.maximumImageBytes,
            acceptedMIMETypes: ["image/"]
        )
        return try await Task.detached(priority: .utility) {
            try Self.downsampleImage(response.data)
        }.value
    }

    private func load(
        _ initialURL: URL,
        maximumBytes: Int,
        acceptedMIMETypes: [String]
    ) async throws -> SafeURLHTTPResponse {
        var url = initialURL
        for redirectCount in 0...Self.maximumRedirects {
            try await validate(url)
            let response = try await loadResponse(
                url,
                maximumBytes,
                acceptedMIMETypes
            )
            if (300..<400).contains(response.statusCode) {
                guard redirectCount < Self.maximumRedirects else {
                    throw SafeURLPreviewError.redirectLimitExceeded
                }
                guard let location = response.headers["location"],
                      let redirectedURL = URL(
                          string: location,
                          relativeTo: url
                      )?.absoluteURL else {
                    throw SafeURLPreviewError.invalidResponse
                }
                url = redirectedURL
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw SafeURLPreviewError.invalidResponse
            }
            return response
        }
        throw SafeURLPreviewError.redirectLimitExceeded
    }

    private func validate(_ url: URL) async throws {
        guard let validatedURL = URLPreviewPolicy.previewableURL(
            from: url.absoluteString
        ),
        validatedURL == url,
        let host = url.host() else {
            throw SafeURLPreviewError.restrictedAddress
        }
        let addresses = try await resolveAddresses(host)
        guard !addresses.isEmpty,
              addresses.allSatisfy(URLPreviewPolicy.isPublicIPAddress) else {
            throw SafeURLPreviewError.restrictedAddress
        }
    }

    private nonisolated static func resolveAddresses(
        _ host: String
    ) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_UNSPEC,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0 else {
                throw SafeURLPreviewError.invalidResponse
            }
            defer { freeaddrinfo(result) }
            var addresses: [String] = []
            var cursor = result
            while let current = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let bytes = buffer.prefix { $0 != 0 }.map {
                        UInt8(bitPattern: $0)
                    }
                    addresses.append(String(decoding: bytes, as: UTF8.self))
                }
                cursor = current.pointee.ai_next
            }
            return Array(Set(addresses))
        }.value
    }

    nonisolated static func downsampleImage(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0,
              width <= 16_000_000 / height else {
            throw SafeURLPreviewError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw SafeURLPreviewError.invalidImage
        }

        for quality in [0.82, 0.68, 0.52] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw SafeURLPreviewError.invalidImage
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else {
                throw SafeURLPreviewError.invalidImage
            }
            if output.length <= 2 * 1_024 * 1_024 {
                return output as Data
            }
        }
        throw SafeURLPreviewError.contentTooLarge
    }
}

struct SafeURLHTTPResponse: Sendable {
    let data: Data
    let finalURL: URL
    let statusCode: Int
    let headers: [String: String]
}

private final class BoundedURLRequest:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private let url: URL
    private let maximumBytes: Int
    private let acceptedMIMETypes: [String]
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<SafeURLHTTPResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var terminalError: Error?
    private var completed = false

    init(url: URL, maximumBytes: Int, acceptedMIMETypes: [String]) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.acceptedMIMETypes = acceptedMIMETypes
    }

    func start() async throws -> SafeURLHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 8
                    configuration.timeoutIntervalForResource = 8
                    configuration.httpShouldSetCookies = false
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: nil
                    )
                    self.session = session
                    let task = session.dataTask(with: url)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            lock.withLock {
                terminalError = SafeURLPreviewError.invalidResponse
            }
            completionHandler(.cancel)
            return
        }

        let isRedirect = (300..<400).contains(response.statusCode)
        let mimeType = response.mimeType?.lowercased() ?? ""
        let acceptsMIME = isRedirect || acceptedMIMETypes.contains {
            $0.hasSuffix("/") ? mimeType.hasPrefix($0) : mimeType == $0
        }
        guard acceptsMIME else {
            lock.withLock {
                terminalError = SafeURLPreviewError.invalidContentType
            }
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength < 0
                || response.expectedContentLength <= maximumBytes else {
            lock.withLock {
                terminalError = SafeURLPreviewError.contentTooLarge
            }
            completionHandler(.cancel)
            return
        }
        lock.withLock {
            self.response = response
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock {
            let (newCount, overflow) = self.data.count.addingReportingOverflow(data.count)
            guard !overflow, newCount <= maximumBytes else {
                terminalError = SafeURLPreviewError.contentTooLarge
                return true
            }
            self.data.append(data)
            return false
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completion: (
            CheckedContinuation<SafeURLHTTPResponse, Error>?,
            Result<SafeURLHTTPResponse, Error>
        ) = lock.withLock {
            guard !completed else {
                return (nil, .failure(CancellationError()))
            }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            if let terminalError {
                return (continuation, .failure(terminalError))
            }
            if let error {
                return (continuation, .failure(error))
            }
            guard let response else {
                return (continuation, .failure(SafeURLPreviewError.invalidResponse))
            }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) {
                guard let key = $1.key as? String,
                      let value = $1.value as? String else {
                    return
                }
                $0[key.lowercased()] = value
            }
            return (
                continuation,
                .success(
                    SafeURLHTTPResponse(
                        data: data,
                        finalURL: response.url ?? url,
                        statusCode: response.statusCode,
                        headers: headers
                    )
                )
            )
        }
        self.session?.finishTasksAndInvalidate()
        completion.0?.resume(with: completion.1)
    }
}

enum BoundedHTMLMetadataParser {
    struct Metadata {
        let title: String?
        let siteName: String?
        let image: String?
    }

    static func parse(_ html: String) -> Metadata {
        Metadata(
            title: metaContent(property: "og:title", in: html)
                ?? elementContent(named: "title", in: html),
            siteName: metaContent(property: "og:site_name", in: html),
            image: metaContent(property: "og:image", in: html)
        )
    }

    private static func metaContent(property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            #"<meta\b[^>]*(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*content\s*=\s*["']([^"']*)["'][^>]*>"#,
            #"<meta\b[^>]*content\s*=\s*["']([^"']*)["'][^>]*(?:property|name)\s*=\s*["']\#(escaped)["'][^>]*>"#,
        ]
        return patterns.lazy.compactMap { firstCapture(pattern: $0, in: html) }.first
            .map(decodeEntities)
    }

    private static func elementContent(named name: String, in html: String) -> String? {
        guard let captured = firstCapture(
            pattern: #"<\#(name)\b[^>]*>(.*?)</\#(name)\s*>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let stripped = captured.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return decodeEntities(stripped)
    }

    private static func firstCapture(
        pattern: String,
        in value: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: options
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[captureRange])
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

@MainActor
final class URLPreviewService: ObservableObject {
    @Published private(set) var state: URLPreviewState = .idle

    private static let cacheLifetime: TimeInterval = 7 * 86_400
    private static let maximumFailedPreviewCount = 256
    private let store: LauncherStore?
    private let fetcher: any URLPreviewFetching
    private let fetchDelay: Duration
    private let networkEnabled: Bool
    private var delayedTask: Task<Void, Never>?
    private var requestID = UUID()
    private var requestedRawURL: String?
    private var requestedEnabled = false
    private var failedPreviewURLs: Set<String> = []

    init(
        store: LauncherStore?,
        fetcher: any URLPreviewFetching = SafeURLPreviewFetcher(),
        fetchDelay: Duration = .milliseconds(350),
        networkEnabled: Bool = true
    ) {
        self.store = store
        self.fetcher = fetcher
        self.fetchDelay = fetchDelay
        self.networkEnabled = networkEnabled
    }

    func load(rawURL: String, isEnabled: Bool) {
        guard requestedRawURL != rawURL || requestedEnabled != isEnabled else {
            return
        }
        cancel(resetState: true)
        requestedRawURL = rawURL
        requestedEnabled = isEnabled
        guard isEnabled, networkEnabled else { return }
        guard let url = URLPreviewPolicy.previewableURL(from: rawURL) else {
            if let fallbackURL = URL(string: rawURL) {
                state = .unavailable(fallbackURL, .restrictedAddress)
            }
            return
        }
        guard !failedPreviewURLs.contains(url.absoluteString) else {
            state = .unavailable(url, .failed)
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
            try? await Task.sleep(for: self.fetchDelay)
            guard !Task.isCancelled else { return }
            await self.fetchMetadata(for: url, requestID: currentRequestID)
        }
    }

    func cancel(resetState: Bool = false) {
        requestedRawURL = nil
        requestedEnabled = false
        requestID = UUID()
        delayedTask?.cancel()
        delayedTask = nil
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
            if let document = try? JSONDecoder().decode(
                URLPreviewDocument.self,
                from: cachedEntry.metadataData
            ) {
                state = .ready(url, document)
                return true
            }
        }
        return false
    }

    private func fetchMetadata(for url: URL, requestID: UUID) async {
        guard self.requestID == requestID else { return }
        let document = try? await fetcher.fetch(url)
        await finish(url: url, requestID: requestID, document: document)
    }

    private func finish(
        url: URL,
        requestID: UUID,
        document: URLPreviewDocument?
    ) async {
        guard self.requestID == requestID else { return }
        guard let document else {
            failedPreviewURLs.insert(url.absoluteString)
            if failedPreviewURLs.count > Self.maximumFailedPreviewCount,
               let oldestArbitraryEntry = failedPreviewURLs.first {
                failedPreviewURLs.remove(oldestArbitraryEntry)
            }
            state = .unavailable(url, .failed)
            return
        }

        state = .ready(url, document)
        if let data = try? JSONEncoder().encode(document) {
            try? await store?.saveURLPreview(
            URLPreviewCacheEntry(
                url: url.absoluteString,
                    metadataData: data,
                fetchedAt: Date()
            )
            )
        }
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
    private let catalog: ClipboardCatalog
    private let onSnapshot: @MainActor @Sendable (FeatureSnapshot<ClipboardItem>) -> Void
    private var settings: ClipboardRecordingSettings
    private var task: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var captureGeneration = 0
    private var lastChangeCount = -1
    private var suppressionDeadline = Date.distantPast

    init(
        reader: SystemPasteboardReader,
        processor: ClipboardCaptureProcessor = ClipboardCaptureProcessor(),
        settings: ClipboardRecordingSettings,
        catalog: ClipboardCatalog,
        onSnapshot: @escaping @MainActor @Sendable (FeatureSnapshot<ClipboardItem>) -> Void
    ) {
        self.reader = reader
        self.processor = processor
        self.settings = settings
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

    func update(settings: ClipboardRecordingSettings) {
        self.settings = settings
    }

    private func runLoop() async {
        var wasRecording = false
        while !Task.isCancelled {
            let currentSettings = settings
            let isRecording =
                currentSettings.isEnabled && !currentSettings.isPaused
            if isRecording {
                if wasRecording {
                    await poll(settings: currentSettings)
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

struct PasteboardSnapshot: Equatable, Sendable {
    let items: [PasteboardItemSnapshot]
}

enum PasteboardSnapshotResult: Equatable, Sendable {
    case captured(PasteboardSnapshot)
    case preservationLimitExceeded
}

enum PasteboardReplacementResult: Equatable, Sendable {
    case written(changeCount: Int)
    case invalidContent
    case preservationLimitExceeded
    case writeFailedAndRestored
    case writeFailedAndRestoreFailed

    var wasWritten: Bool {
        if case .written = self {
            return true
        }
        return false
    }
}

enum PasteResult: Equatable, Sendable {
    case pasted
    case copiedBecausePermissionDenied
    case copiedBecauseTargetUnavailable
    case copiedBecauseActivationFailed
    case failedBecauseClipboardCouldNotBePreserved
    case failed
}

@MainActor
protocol PasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshotResult
    func replace(
        with content: PasteboardContent,
        preserving snapshot: PasteboardSnapshot
    ) -> PasteboardReplacementResult
    @discardableResult
    func restore(_ snapshot: PasteboardSnapshot) -> Bool
}

@MainActor
final class SystemPasteboardAccessor: PasteboardAccessing {
    private enum PreparedContent {
        case items([any NSPasteboardWriting])
    }

    private static let maximumSnapshotItems = 16
    private static let maximumSnapshotTypesPerItem = 32
    private static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    private let pasteboard: NSPasteboard
    private let writeObjects: ([any NSPasteboardWriting]) -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        writeObjects: (([any NSPasteboardWriting]) -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.writeObjects = writeObjects ?? { pasteboard.writeObjects($0) }
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> PasteboardSnapshotResult {
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        guard pasteboardItems.count <= Self.maximumSnapshotItems else {
            return .preservationLimitExceeded
        }

        var totalBytes = 0
        var snapshots: [PasteboardItemSnapshot] = []
        snapshots.reserveCapacity(pasteboardItems.count)
        for item in pasteboardItems {
            guard item.types.count <= Self.maximumSnapshotTypesPerItem else {
                return .preservationLimitExceeded
            }
            var values: [PasteboardTypeData] = []
            values.reserveCapacity(item.types.count)
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                let (nextTotal, overflow) = totalBytes.addingReportingOverflow(data.count)
                guard !overflow, nextTotal <= Self.maximumSnapshotBytes else {
                    return .preservationLimitExceeded
                }
                totalBytes = nextTotal
                values.append(PasteboardTypeData(type: type.rawValue, data: data))
            }
            snapshots.append(PasteboardItemSnapshot(values: values))
        }
        return .captured(PasteboardSnapshot(items: snapshots))
    }

    func replace(
        with content: PasteboardContent,
        preserving snapshot: PasteboardSnapshot
    ) -> PasteboardReplacementResult {
        guard let prepared = prepare(content) else {
            return .invalidContent
        }
        pasteboard.clearContents()
        let didWrite: Bool
        switch prepared {
        case let .items(items):
            didWrite = writeObjects(items)
        }
        guard didWrite else {
            return restore(snapshot)
                ? .writeFailedAndRestored
                : .writeFailedAndRestoreFailed
        }
        return .written(changeCount: pasteboard.changeCount)
    }

    @discardableResult
    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        let items: [NSPasteboardItem] = snapshot.items.compactMap { itemSnapshot in
            let item = NSPasteboardItem()
            for value in itemSnapshot.values {
                guard item.setData(
                    value.data,
                    forType: NSPasteboard.PasteboardType(value.type)
                ) else {
                    return nil
                }
            }
            return item
        }
        guard items.count == snapshot.items.count else {
            return false
        }

        pasteboard.clearContents()
        guard !items.isEmpty else {
            return true
        }
        return writeObjects(items)
    }

    private func prepare(_ content: PasteboardContent) -> PreparedContent? {
        switch content {
        case let .text(value):
            let item = NSPasteboardItem()
            guard item.setString(value, forType: .string) else { return nil }
            return .items([item])
        case let .url(value):
            let item = NSPasteboardItem()
            guard item.setString(value, forType: .string),
                  item.setString(value, forType: .URL) else {
                return nil
            }
            return .items([item])
        case let .files(paths):
            let urls = paths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty, urls.count == paths.count else { return nil }
            return .items(urls.map { $0 as NSURL })
        case let .image(data):
            guard !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else {
                return nil
            }
            let item = NSPasteboardItem()
            guard item.setData(data, forType: .png) else { return nil }
            return .items([item])
        }
    }
}

@MainActor
protocol PasteTargetApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isActive: Bool { get }
    var isFrontmost: Bool { get }
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

    var processIdentifier: pid_t {
        application.processIdentifier
    }

    var isActive: Bool {
        application.isActive
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    var isTerminated: Bool {
        application.isTerminated
    }

    @discardableResult
    func activate() -> Bool {
        // The palette currently owns activation. Yield it explicitly before
        // requesting the target so AppKit can perform a coordinated handoff.
        NSApp.yieldActivation(to: application)
        return application.activate(from: .current, options: [])
    }
}

@MainActor
struct PasteCoordinatorDependencies {
    var isAccessibilityTrusted: () -> Bool
    var postPasteShortcut: (pid_t) -> Bool
    var sleep: (Duration) async -> Void
    var activationPollInterval: Duration
    var activationPollAttempts: Int
    var activationGracePeriod: Duration
    var restorationDelay: Duration

    static let live = PasteCoordinatorDependencies(
        isAccessibilityTrusted: {
            AXIsProcessTrusted()
        },
        postPasteShortcut: { processIdentifier in
            guard processIdentifier > 0,
                  let source = CGEventSource(stateID: .combinedSessionState),
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
            // Route the shortcut to the verified target process. Posting to
            // the global HID stream can race with focus handoff and deliver
            // Command-V back to Yorozu or another newly active application.
            keyDown.postToPid(processIdentifier)
            keyUp.postToPid(processIdentifier)
            return true
        },
        sleep: { duration in
            try? await Task.sleep(for: duration)
        },
        activationPollInterval: .milliseconds(25),
        activationPollAttempts: 40,
        activationGracePeriod: .milliseconds(50),
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

    func copy(_ content: PasteboardContent) async -> PasteboardReplacementResult {
        guard case let .captured(original) = pasteboard.snapshot() else {
            return .preservationLimitExceeded
        }
        await suppressClipboardMonitor(.seconds(2))
        return pasteboard.replace(with: content, preserving: original)
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
        guard case let .captured(original) = pasteboard.snapshot() else {
            return .failedBecauseClipboardCouldNotBePreserved
        }
        await suppressClipboardMonitor(.seconds(2))
        let replacement = pasteboard.replace(with: content, preserving: original)
        guard case let .written(injectedChangeCount) = replacement else {
            if replacement == .preservationLimitExceeded {
                return .failedBecauseClipboardCouldNotBePreserved
            }
            return .failed
        }

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
        guard isReadyForPaste(targetApplication) else {
            return .copiedBecauseActivationFailed
        }
        guard dependencies.postPasteShortcut(targetApplication.processIdentifier) else {
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
        if isReadyForPaste(targetApplication) {
            return .active
        }

        for _ in 0..<max(1, dependencies.activationPollAttempts) {
            if Task.isCancelled || targetApplication.isTerminated {
                return .unavailable
            }
            await dependencies.sleep(dependencies.activationPollInterval)
            if isReadyForPaste(targetApplication) {
                return .active
            }
        }

        return targetApplication.isTerminated ? .unavailable : .timedOut
    }

    private func isReadyForPaste(
        _ targetApplication: any PasteTargetApplication
    ) -> Bool {
        targetApplication.isActive && targetApplication.isFrontmost
    }
}
