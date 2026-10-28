#if DEBUG
import AppKit
import Darwin

struct SoakPerformanceConfiguration: Equatable {
    let durationSeconds: Double
    let warmupSeconds: Double
    let sampleIntervalSeconds: Double

    init(arguments: [String]) throws {
        func value(_ name: String, default fallback: Double) throws -> Double {
            guard let index = arguments.firstIndex(of: name) else { return fallback }
            guard arguments.indices.contains(index + 1),
                  let number = Double(arguments[index + 1]), number.isFinite else {
                throw SoakPerformanceError.invalidConfiguration
            }
            return number
        }
        durationSeconds = try value("--soak-duration-seconds", default: 1_800)
        warmupSeconds = try value("--soak-warmup-seconds", default: 300)
        sampleIntervalSeconds = try value("--soak-sample-seconds", default: 30)
        guard (2...14_400).contains(durationSeconds),
              (0..<durationSeconds).contains(warmupSeconds),
              (1...60).contains(sampleIntervalSeconds) else {
            throw SoakPerformanceError.invalidConfiguration
        }
    }
}

enum SoakPerformanceError: Error {
    case invalidConfiguration
    case resourceSampleUnavailable
    case fixturesUnavailable
}

struct SoakProcessResources: Codable {
    let residentBytes: UInt64
    let cpuSeconds: Double

    static func current() throws -> Self {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        guard result == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw SoakPerformanceError.resourceSampleUnavailable
        }
        return Self(
            residentBytes: info.resident_size,
            cpuSeconds: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        )
    }
}

struct SoakLatencySample: Codable {
    let root: PalettePresentationPerformanceReport
    let clipboard: PalettePresentationPerformanceReport
    let snippets: PalettePresentationPerformanceReport
    let clipboardItemCount: Int
    let snippetCount: Int
}

struct SoakPerformanceSample: Codable {
    let elapsedSeconds: Double
    let residentBytes: UInt64
    let idleCPUPercent: Double
    let wakeEventCount: Int
    let cacheEstimatedBytes: Int
    let cacheConversationCount: Int
    let cacheEvictionCount: Int
    let latency: SoakLatencySample
}

struct SoakPerformanceReport: Codable {
    let requestedDurationSeconds: Double
    let warmupSeconds: Double
    let samples: [SoakPerformanceSample]

    var afterWarmupRSSGrowthBytes: UInt64? {
        let warmed = samples.filter { $0.elapsedSeconds >= warmupSeconds }
        guard let first = warmed.first, warmed.count >= 2 else { return nil }
        return (warmed.map(\.residentBytes).max() ?? first.residentBytes) - first.residentBytes
    }

    private enum CodingKeys: String, CodingKey {
        case requestedDurationSeconds, warmupSeconds, samples, afterWarmupRSSGrowthBytes
    }

    init(requestedDurationSeconds: Double, warmupSeconds: Double, samples: [SoakPerformanceSample]) {
        self.requestedDurationSeconds = requestedDurationSeconds
        self.warmupSeconds = warmupSeconds
        self.samples = samples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedDurationSeconds = try container.decode(Double.self, forKey: .requestedDurationSeconds)
        warmupSeconds = try container.decode(Double.self, forKey: .warmupSeconds)
        samples = try container.decode([SoakPerformanceSample].self, forKey: .samples)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestedDurationSeconds, forKey: .requestedDurationSeconds)
        try container.encode(warmupSeconds, forKey: .warmupSeconds)
        try container.encode(samples, forKey: .samples)
        try container.encodeIfPresent(afterWarmupRSSGrowthBytes, forKey: .afterWarmupRSSGrowthBytes)
    }
}

@MainActor
enum SoakPerformanceProbe {
    static func run(
        configuration: SoakPerformanceConfiguration,
        cache: AIMessageCache,
        measure: () async throws -> SoakLatencySample
    ) async throws -> SoakPerformanceReport {
        let wakeCounter = SoakWakeCounter()
        defer { wakeCounter.stop() }
        let start = ContinuousClock.now
        var samples: [SoakPerformanceSample] = []
        // Warm drawing before the first idle CPU interval. All data is synthetic.
        _ = try await measure()
        var cycle = 0
        while start.duration(to: .now).seconds < configuration.durationSeconds {
            try Task.checkCancellation()
            exerciseCache(cache, cycle: cycle)
            let idleStart = try SoakProcessResources.current()
            // CPU time only advances while awake; exclude system sleep from
            // its denominator instead of making a sleeping process look faster.
            let idleClock = SuspendingClock.now
            let remaining = configuration.durationSeconds - start.duration(to: .now).seconds
            if remaining <= 0 { break }
            try await Task.sleep(for: .seconds(min(remaining, configuration.sampleIntervalSeconds)))
            let resources = try SoakProcessResources.current()
            let idleDuration = idleClock.duration(to: .now).seconds
            let latency = try await measure()
            let statistics = cache.statistics
            samples.append(SoakPerformanceSample(
                elapsedSeconds: start.duration(to: .now).seconds,
                residentBytes: resources.residentBytes,
                idleCPUPercent: max(0, resources.cpuSeconds - idleStart.cpuSeconds)
                    / max(idleDuration, 0.001) * 100,
                wakeEventCount: wakeCounter.count,
                cacheEstimatedBytes: statistics.estimatedByteCount,
                cacheConversationCount: statistics.conversationCount,
                cacheEvictionCount: statistics.evictionCount,
                latency: latency
            ))
            cycle += 1
        }
        return SoakPerformanceReport(
            requestedDurationSeconds: configuration.durationSeconds,
            warmupSeconds: configuration.warmupSeconds,
            samples: samples
        )
    }

    private static func exerciseCache(_ cache: AIMessageCache, cycle: Int) {
        for index in 0..<16 {
            let reference = AIConversationReference(
                providerID: .openAIAPI, providerConversationID: "soak-\(cycle)-\(index)"
            )
            let message = AIChatMessage(
                id: "fixture", role: .assistant,
                text: "\(cycle)-\(index) " + String(repeating: "x", count: 2 * 1_024 * 1_024),
                citations: [], attachments: [], isStreaming: false
            )
            cache.store([message], for: reference)
        }
    }
}

@MainActor
private final class SoakWakeCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
#endif
