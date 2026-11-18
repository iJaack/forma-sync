import HealthKit

/// Turns raw sleep-analysis samples into one row of minutes per night.
/// A night belongs to the calendar day you wake up on: samples are assigned by (start + 6 h),
/// so anything starting between 18:00 of D-1 and 18:00 of D counts for day D.
enum SleepAggregator {
    static let nightShift: TimeInterval = 6 * 3600

    static func nightDate(for start: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: start.addingTimeInterval(nightShift))
    }

    /// Apple and WHOOP are always allowed; local builds may add comma-separated prefixes.
    static func sourcePrefixes(extraSources: String?) -> [String] {
        let extra = (extraSources ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return ["com.apple.", "com.whoop."] + extra
    }

    static func isAllowedSource(_ bundleID: String, prefixes: [String]) -> Bool {
        prefixes.contains { !$0.isEmpty && bundleID.hasPrefix($0) }
    }

    /// The samples of the ONE source used for each night. Several apps can write sleep (Apple Watch,
    /// WHOOP, ...): to avoid double counting prefer Apple sources, then sources with stages, then the longest.
    static func chosenSamples(from samples: [HKCategorySample], calendar: Calendar) -> [Date: [HKCategorySample]] {
        let prefixes = sourcePrefixes(extraSources: Bundle.main.object(
            forInfoDictionaryKey: "FormaExtraSleepSources"
        ) as? String)
        var groups: [Date: [String: [HKCategorySample]]] = [:]
        for sample in samples {
            let night = nightDate(for: sample.startDate, calendar: calendar)
            let source = sample.sourceRevision.source.bundleIdentifier
            guard isAllowedSource(source, prefixes: prefixes) else { continue }
            groups[night, default: [:]][source, default: []].append(sample)
        }
        var result: [Date: [HKCategorySample]] = [:]
        for (night, bySource) in groups {
            if let chosen = bySource.max(by: { score($0.key, $0.value) < score($1.key, $1.value) })?.value {
                result[night] = chosen
            }
        }
        return result
    }

    static func stageName(_ value: Int) -> String {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: value) else { return "unknown" }
        switch v {
        case .inBed: return "in_bed"
        case .awake: return "awake"
        case .asleepCore: return "asleep_core"
        case .asleepDeep: return "asleep_deep"
        case .asleepREM: return "asleep_rem"
        case .asleepUnspecified: return "asleep_unspecified"
        @unknown default: return "unknown"
        }
    }

    /// Minutes per stage for one night. Overlapping samples (duplicates re-written by an app, stages plus
    /// "asleep" on top, in-bed spans) are resolved on a timeline: every minute counts once, for its most
    /// specific stage (deep > REM > core > asleep > awake > in bed). Implausible nights are dropped.
    static func nights(from samples: [HKCategorySample], calendar: Calendar) -> [Date: [String: Double]] {
        var result: [Date: [String: Double]] = [:]
        for (night, chosen) in chosenSamples(from: samples, calendar: calendar) {
            let m = stageMinutes(chosen)
            let asleep = m.core + m.deep + m.rem + m.unspecified
            guard asleep > 0, asleep <= 16 * 60 else { continue }
            var row: [String: Double] = ["sleep_asleep_min": asleep.rounded(), "sleep_inbed_min": max(m.inBedSpan, asleep + m.awake).rounded()]
            if m.awake > 0 { row["sleep_awake_min"] = m.awake.rounded() }
            if m.core > 0 { row["sleep_core_min"] = m.core.rounded() }
            if m.deep > 0 { row["sleep_deep_min"] = m.deep.rounded() }
            if m.rem > 0 { row["sleep_rem_min"] = m.rem.rounded() }
            result[night] = row
        }
        return result
    }

    struct StageMinutes {
        var core = 0.0, deep = 0.0, rem = 0.0, unspecified = 0.0, awake = 0.0, inBedSpan = 0.0
    }

    private static func priority(_ value: Int) -> Int {
        guard let v = HKCategoryValueSleepAnalysis(rawValue: value) else { return 0 }
        switch v {
        case .asleepDeep: return 6
        case .asleepREM: return 5
        case .asleepCore: return 4
        case .asleepUnspecified: return 3
        case .awake: return 2
        case .inBed: return 1
        @unknown default: return 0
        }
    }

    static func stageMinutes(_ samples: [HKCategorySample]) -> StageMinutes {
        var bounds = Set<Date>()
        for s in samples where s.endDate > s.startDate {
            bounds.insert(s.startDate)
            bounds.insert(s.endDate)
        }
        let points = bounds.sorted()
        var m = StageMinutes()
        guard points.count > 1 else { return m }
        let sorted = samples.filter { $0.endDate > $0.startDate }.sorted { $0.startDate < $1.startDate }
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            var best = 0
            for s in sorted {
                if s.startDate >= b { break }
                if s.endDate > a { best = max(best, priority(s.value)) }
            }
            guard best > 0 else { continue }
            let minutes = b.timeIntervalSince(a) / 60
            m.inBedSpan += minutes
            switch best {
            case 6: m.deep += minutes
            case 5: m.rem += minutes
            case 4: m.core += minutes
            case 3: m.unspecified += minutes
            case 2: m.awake += minutes
            default: break
            }
        }
        return m
    }

    private static func isAsleep(_ value: Int) -> Bool {
        value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
            || value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
            || value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
            || value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
    }

    private static func score(_ bundleId: String, _ samples: [HKCategorySample]) -> Double {
        let asleepSeconds = samples.filter { isAsleep($0.value) }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
        let hasStages = samples.contains {
            $0.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || $0.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
        return asleepSeconds + (hasStages ? 1e7 : 0) + (bundleId.hasPrefix("com.apple.health") ? 1e8 : 0)
    }
}
