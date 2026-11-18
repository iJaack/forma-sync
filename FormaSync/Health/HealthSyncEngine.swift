import Foundation
import HealthKit

/// Reads Health data and pushes it to Forma in the "forma-sync/2" format.
///
/// Recent sync (every run):
/// - HKObserverQuery + background delivery wake the app when Health gets new samples (key types only).
/// - HKAnchoredObjectQuery (anchors persisted only after a successful POST) says which days changed in the
///   last 30 days; for those days every catalog type is recomputed with HKStatisticsCollectionQuery, which
///   de-duplicates overlapping sources (iPhone + Apple Watch) like the Health app does.
///
/// History (12 months, one calendar-month window at a time, newest first):
/// - Progress is saved after each month, so it resumes after a crash, a kill or a background timeout.
/// - Foreground runs do all remaining months; a background refresh does at most one.
actor HealthSyncEngine {
    static let shared = HealthSyncEngine()
    static let historyMonths = 12

    private let store = HKHealthStore()
    private let recentDays = 30
    private let sleepEventDays = 14
    private let anchorPrefix = "anchor2."
    private var observersStarted = false
    private var currentTask: Task<Void, Never>?
    private var currentID: UUID?
    private var pendingReason: SyncReason?
    /// Last time the running sync made progress (a HealthKit read or a POST finished).
    private var lastProgress = Date.distantPast
    /// A sync with no progress for this long is considered stuck: it is abandoned and a new one may start.
    static let staleAfter: TimeInterval = 180
    /// Every single HealthKit query is abandoned after this long (a stuck query must never block the app).
    private let queryTimeout: TimeInterval = 90

    private struct AnchoredResult {
        var samples: [HKSample]
        var deleted: [HKDeletedObject]
        var anchor: HKQueryAnchor?
    }

    private struct EffortSample {
        var start: Date
        var value: Double
        var estimated: Bool
    }

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    // MARK: - Authorization & observers

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw SyncError.healthUnavailable }
        try await store.requestAuthorization(toShare: [], read: MetricCatalog.readTypes)
        UserDefaults.standard.set(MetricCatalog.authorizationVersion, forKey: Keys.authorizationVersion)
    }

    /// True when the catalog contains types the user has not been asked about yet (e.g. after updating from v1).
    func authorizationNeedsUpdate() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            let status = try await store.statusForAuthorizationRequest(toShare: [], read: MetricCatalog.readTypes)
            return status == .shouldRequest
        } catch {
            return UserDefaults.standard.integer(forKey: Keys.authorizationVersion) < MetricCatalog.authorizationVersion
        }
    }

    func startObservers() {
        guard HKHealthStore.isHealthDataAvailable(), !observersStarted else { return }
        observersStarted = true
        for type in MetricCatalog.observedTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if error != nil {
                    completionHandler()
                    return
                }
                Task {
                    await HealthSyncEngine.shared.sync(reason: .observer)
                    completionHandler()
                }
            }
            store.execute(query)
            let urgent = type is HKWorkoutType || type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            store.enableBackgroundDelivery(for: type, frequency: urgent ? .immediate : .hourly) { _, _ in }
        }
    }

    // MARK: - History controls

    func resetHistory() {
        UserDefaults.standard.set(0, forKey: Keys.historyDone)
    }

    func cancelCurrent() {
        currentTask?.cancel()
    }

    private func progress() async {
        lastProgress = Date()
        await MainActor.run { SyncStatusStore.shared.heartbeat() }
    }

    // MARK: - Sync entry point (coalesces concurrent requests, never waits on a stuck run)

    func sync(reason: SyncReason) async {
        if currentTask != nil {
            let stale = Date().timeIntervalSince(lastProgress) > Self.staleAfter
            if !stale {
                // A healthy run is in progress: a manual request is queued and runs right after it.
                if reason == .manual || reason == .history || reason == .foreground { pendingReason = reason }
                return
            }
            // Stuck run (e.g. a HealthKit query that never answered): abandon it and start fresh.
            currentTask?.cancel()
            currentTask = nil
            currentID = nil
        }
        var next: SyncReason? = reason
        while let r = next {
            pendingReason = nil
            let id = UUID()
            lastProgress = Date()
            let task = Task { await self.perform(reason: r) }
            currentTask = task
            currentID = id
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard currentID == id else { return }   // abandoned as stale: a newer run owns the state
            currentTask = nil
            currentID = nil
            next = pendingReason
        }
    }

    private func perform(reason: SyncReason) async {
        await MainActor.run {
            SyncStatusStore.shared.begin()
            BackgroundAssertion.begin()
        }
        var summary = SyncSummary(noChanges: true)
        var firstError: Error?
        do {
            summary = try await runRecent(reason: reason)
        } catch {
            firstError = error
        }
        // The 12-month history does not depend on the recent sync succeeding (only a locked phone,
        // a missing configuration or a cancellation stop it).
        let budget = historyBudget(for: reason)
        if budget > 0 && !Self.isFatal(firstError) {
            do {
                summary.add(try await runHistory(maxMonths: budget))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let error = firstError {
            let message: String
            if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible {
                message = SyncError.healthLocked.localizedDescription
            } else if error is CancellationError {
                message = "Sincronizzazione interrotta, riprendo alla prossima apertura."
            } else {
                message = error.localizedDescription
            }
            await MainActor.run { SyncStatusStore.shared.fail(message, reason: reason) }
        } else {
            let result = summary
            await MainActor.run { SyncStatusStore.shared.finish(result, reason: reason) }
        }
        let done = UserDefaults.standard.integer(forKey: Keys.historyDone)
        await MainActor.run {
            SyncStatusStore.shared.historyIdle(done: done)
            BackgroundAssertion.end()
        }
    }

    private static func isFatal(_ error: Error?) -> Bool {
        guard let error = error else { return false }
        if error is CancellationError { return true }
        if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible { return true }
        if let syncError = error as? SyncError {
            switch syncError {
            case .notConfigured, .healthUnavailable, .healthLocked: return true
            default: return false
            }
        }
        return false
    }

    private func historyBudget(for reason: SyncReason) -> Int {
        let done = UserDefaults.standard.integer(forKey: Keys.historyDone)
        guard done < Self.historyMonths else { return 0 }
        switch reason {
        case .manual, .foreground, .history: return Self.historyMonths
        case .backgroundRefresh: return 1
        case .observer: return 0
        }
    }

    // MARK: - Recent changes (last 30 days)

    private func runRecent(reason: SyncReason) async throws -> SyncSummary {
        guard HKHealthStore.isHealthDataAvailable() else { throw SyncError.healthUnavailable }
        guard let config = IngestConfig.load() else { throw SyncError.notConfigured }
        let defaults = UserDefaults.standard

        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
              let recentStart = calendar.date(byAdding: .day, value: -(recentDays - 1), to: today),
              let sleepEventStart = calendar.date(byAdding: .day, value: -(sleepEventDays - 1), to: today),
              let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
              let workoutResendStart = calendar.date(byAdding: .day, value: -2, to: today) else {
            throw SyncError.unexpectedResponse
        }
        let firstRun = defaults.integer(forKey: Keys.recentFormat) < 2
        let since = HKQuery.predicateForSamples(withStart: recentStart, end: nil, options: [])
        let lastWeek = days(from: weekStart, through: today)

        var newAnchors: [String: HKQueryAnchor] = [:]
        var changed = false
        var affected = Set<Date>([today, yesterday])
        var deletedEvents: [String] = []

        // 1) Key quantity types: which days have new or deleted samples?
        for spec in MetricCatalog.quantities where spec.observe {
            let key = anchorPrefix + spec.key
            let previous = firstRun ? nil : loadAnchor(key)
            let type = spec.type
            guard let result = try await tolerant(nil as AnchoredResult?, {
                try await self.anchoredQuery(type: type, predicate: since, anchor: previous)
            }) else { continue }
            if let anchor = result.anchor { newAnchors[key] = anchor }
            if !result.samples.isEmpty || (!result.deleted.isEmpty && !firstRun) { changed = true }
            for sample in result.samples {
                affected.insert(calendar.startOfDay(for: sample.startDate))
                affected.insert(calendar.startOfDay(for: sample.endDate))
            }
            if !result.deleted.isEmpty && !firstRun { affected.formUnion(lastWeek) }
        }

        // 2) Sleep: which nights changed?
        let sleepKey = anchorPrefix + "sleep"
        let sleepPrevious = firstRun ? nil : loadAnchor(sleepKey)
        if let result = try await tolerant(nil as AnchoredResult?, {
            try await self.anchoredQuery(type: MetricCatalog.sleep, predicate: since, anchor: sleepPrevious)
        }) {
            if let anchor = result.anchor { newAnchors[sleepKey] = anchor }
            if !result.samples.isEmpty || !result.deleted.isEmpty { changed = true }
            for sample in result.samples {
                affected.insert(SleepAggregator.nightDate(for: sample.startDate, calendar: calendar))
            }
            if !result.deleted.isEmpty && !firstRun {
                affected.formUnion(lastWeek)
                deletedEvents += result.deleted.map { $0.uuid.uuidString }
            }
        }

        // 3) Mindful sessions.
        let mindfulKey = anchorPrefix + "mindful"
        let mindfulPrevious = firstRun ? nil : loadAnchor(mindfulKey)
        var mindfulNew: [HKCategorySample] = []
        if let result = try await tolerant(nil as AnchoredResult?, {
            try await self.anchoredQuery(type: MetricCatalog.mindful, predicate: since, anchor: mindfulPrevious)
        }) {
            if let anchor = result.anchor { newAnchors[mindfulKey] = anchor }
            if !result.samples.isEmpty || !result.deleted.isEmpty { changed = true }
            mindfulNew = result.samples.compactMap { $0 as? HKCategorySample }
            for sample in mindfulNew { affected.insert(calendar.startOfDay(for: sample.startDate)) }
            if !result.deleted.isEmpty && !firstRun {
                affected.formUnion(lastWeek)
                deletedEvents += result.deleted.map { $0.uuid.uuidString }
            }
        }

        // 4) Workouts: new ones in full, deleted ones by UUID.
        let workoutKey = anchorPrefix + "workout"
        let workoutPrevious = firstRun ? nil : loadAnchor(workoutKey)
        var workouts: [HKWorkout] = []
        var deletedWorkouts: [String] = []
        if let result = try await tolerant(nil as AnchoredResult?, {
            try await self.anchoredQuery(type: MetricCatalog.workout, predicate: since, anchor: workoutPrevious)
        }) {
            if let anchor = result.anchor { newAnchors[workoutKey] = anchor }
            workouts = result.samples.compactMap { $0 as? HKWorkout }
            // On the first run the anchor is nil and HealthKit also lists old deletions: nothing to delete on the server.
            deletedWorkouts = firstRun ? [] : result.deleted.map { $0.uuid.uuidString }
            if !workouts.isEmpty || !deletedWorkouts.isEmpty { changed = true }
        }

        if !changed && !firstRun && reason != .manual && reason != .history {
            saveAnchors(newAnchors)
            return SyncSummary(noChanges: true)
        }
        if firstRun { affected.formUnion(days(from: recentStart, through: today)) }

        // Re-send the last 3 days of workouts too: effort ratings and HR statistics can arrive later.
        let recentWorkouts = try await tolerant([HKSample](), {
            try await self.samples(MetricCatalog.workout, from: workoutResendStart, to: tomorrow)
        }).compactMap { $0 as? HKWorkout }
        var seen = Set(workouts.map { $0.uuid })
        for workout in recentWorkouts where !seen.contains(workout.uuid) {
            workouts.append(workout)
            seen.insert(workout.uuid)
        }

        // 5) Build the payload for the affected days.
        let dayList = affected.filter { $0 >= recentStart && $0 <= today }.sorted()
        var payload = IngestPayload(app: appName, tz: TimeZone.current.identifier)
        payload.quantities = try await dailyQuantities(days: dayList)
        let eventNights = Set(dayList.filter { $0 >= sleepEventStart })
        if !eventNights.isEmpty {
            payload.events += try await sleepEvents(nights: eventNights)
        }
        payload.events += mindfulNew.map { mindfulEvent($0) }
        payload.workouts = try await workoutDTOs(workouts)
        payload.deleted_workouts = deletedWorkouts
        payload.deleted_events = deletedEvents

        // 6) POST, then persist anchors.
        let background = reason == .observer || reason == .backgroundRefresh
        let posts = try await send(payload, config: config, background: background)
        saveAnchors(newAnchors)
        defaults.set(2, forKey: Keys.recentFormat)
        return SyncSummary(days: dayList.count, values: payload.quantities.count, events: payload.events.count,
                           workouts: payload.workouts.count,
                           deleted: payload.deleted_workouts.count + payload.deleted_events.count,
                           posts: posts, noChanges: false)
    }

    // MARK: - History (12 months, month by month)

    private func runHistory(maxMonths: Int) async throws -> SyncSummary {
        guard let config = IngestConfig.load() else { throw SyncError.notConfigured }
        let defaults = UserDefaults.standard
        let today = calendar.startOfDay(for: Date())
        guard let base = calendar.date(byAdding: .day, value: 1, to: today) else { return SyncSummary(noChanges: true) }

        var summary = SyncSummary(noChanges: true)
        var done = defaults.integer(forKey: Keys.historyDone)
        var processed = 0
        while done < Self.historyMonths && processed < maxMonths {
            try Task.checkCancellation()
            let month = done
            await MainActor.run { SyncStatusStore.shared.historyRunning(month: month + 1, total: HealthSyncEngine.historyMonths) }
            // Window `month`: [base - (month+1) months, base - month months), newest first.
            guard let start = calendar.date(byAdding: .month, value: -(month + 1), to: base),
                  let end = calendar.date(byAdding: .month, value: -month, to: base),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: end) else { break }
            let dayList = days(from: start, through: lastDay)

            var payload = IngestPayload(app: appName, tz: TimeZone.current.identifier)
            payload.quantities = try await dailyQuantities(days: dayList)
            let mindful = try await tolerant([HKSample](), {
                try await self.samples(MetricCatalog.mindful, from: start, to: end)
            }).compactMap { $0 as? HKCategorySample }
            payload.events = mindful.map { mindfulEvent($0) }
            let workouts = try await tolerant([HKSample](), {
                try await self.samples(MetricCatalog.workout, from: start, to: end)
            }).compactMap { $0 as? HKWorkout }
            payload.workouts = try await workoutDTOs(workouts)

            let posts = try await send(payload, config: config, background: false)
            summary.add(SyncSummary(days: dayList.count, values: payload.quantities.count, events: payload.events.count,
                                    workouts: payload.workouts.count, deleted: 0, posts: posts, noChanges: false))
            done += 1
            processed += 1
            defaults.set(done, forKey: Keys.historyDone)
            let finished = done
            await MainActor.run { SyncStatusStore.shared.historyIdle(done: finished) }
        }
        return summary
    }

    // MARK: - Payload builders

    private var appName: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "2.0"
        return "forma-sync-ios/\(version)"
    }

    /// Daily values of every catalog type, stand hours, mindful minutes and sleep minutes for `days`.
    private func dailyQuantities(days dayList: [Date]) async throws -> [QuantityDTO] {
        guard let first = dayList.first, let last = dayList.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        let wanted = Set(dayList)
        var out: [QuantityDTO] = []

        for spec in MetricCatalog.quantities where spec.unitIsCompatible {
            try Task.checkCancellation()
            let values = try await tolerant([Date: [Agg: Double]](), {
                try await self.dailyStatistics(spec, from: first, to: end)
            })
            for day in values.keys.sorted() where wanted.contains(day) {
                guard let row = values[day] else { continue }
                for agg in spec.effectiveAggs {
                    if let v = row[agg] {
                        out.append(QuantityDTO(type: spec.key, unit: spec.unitLabel, date: dayString(day),
                                               start: nil, end: nil, value: v, agg: agg.rawValue))
                    }
                }
            }
        }

        // Stand hours (category samples, one per hour stood).
        let stand = try await tolerant([HKSample](), {
            try await self.samples(MetricCatalog.standHour, from: first, to: end)
        })
        var standByDay: [Date: Int] = [:]
        for case let sample as HKCategorySample in stand where sample.value == HKCategoryValueAppleStandHour.stood.rawValue {
            standByDay[calendar.startOfDay(for: sample.startDate), default: 0] += 1
        }
        for day in standByDay.keys.sorted() where wanted.contains(day) {
            out.append(QuantityDTO(type: "apple_stand_hour", unit: "count", date: dayString(day), start: nil, end: nil,
                                   value: Double(standByDay[day] ?? 0), agg: "count"))
        }

        // Mindful minutes.
        let mindful = try await tolerant([HKSample](), {
            try await self.samples(MetricCatalog.mindful, from: first, to: end)
        })
        var mindfulByDay: [Date: Double] = [:]
        for sample in mindful {
            mindfulByDay[calendar.startOfDay(for: sample.startDate), default: 0] += sample.endDate.timeIntervalSince(sample.startDate) / 60
        }
        for day in mindfulByDay.keys.sorted() where wanted.contains(day) {
            out.append(QuantityDTO(type: "mindful_minutes", unit: "min", date: dayString(day), start: nil, end: nil,
                                   value: (mindfulByDay[day] ?? 0).rounded(), agg: "sum"))
        }

        // Sleep minutes per night (night = the day you wake up).
        let sleep = try await tolerant([HKSample](), {
            try await self.samples(MetricCatalog.sleep, from: first.addingTimeInterval(-SleepAggregator.nightShift), to: end)
        }).compactMap { $0 as? HKCategorySample }
        let nights = SleepAggregator.nights(from: sleep, calendar: calendar)
        for night in nights.keys.sorted() where wanted.contains(night) {
            guard let row = nights[night] else { continue }
            for key in row.keys.sorted() {
                if let v = row[key] {
                    out.append(QuantityDTO(type: key, unit: "min", date: dayString(night), start: nil, end: nil, value: v, agg: "sum"))
                }
            }
        }
        return out
    }

    /// Individual sleep-stage segments (only the source chosen for each night).
    private func sleepEvents(nights: Set<Date>) async throws -> [EventDTO] {
        guard let first = nights.min(), let last = nights.max(),
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [] }
        let samples = try await tolerant([HKSample](), {
            try await self.samples(MetricCatalog.sleep, from: first.addingTimeInterval(-SleepAggregator.nightShift), to: end)
        }).compactMap { $0 as? HKCategorySample }
        var out: [EventDTO] = []
        let chosen = SleepAggregator.chosenSamples(from: samples, calendar: calendar)
        for night in chosen.keys.sorted() where nights.contains(night) {
            for sample in chosen[night] ?? [] {
                out.append(EventDTO(id: sample.uuid.uuidString, type: "sleep_analysis",
                                    value: SleepAggregator.stageName(sample.value),
                                    start: isoFormatter.string(from: sample.startDate),
                                    end: isoFormatter.string(from: sample.endDate),
                                    day: dayString(night),
                                    extra: ["source": sample.sourceRevision.source.bundleIdentifier]))
            }
        }
        return out
    }

    private func mindfulEvent(_ sample: HKCategorySample) -> EventDTO {
        EventDTO(id: sample.uuid.uuidString, type: "mindful_session", value: "mindful",
                 start: isoFormatter.string(from: sample.startDate), end: isoFormatter.string(from: sample.endDate),
                 day: dayString(calendar.startOfDay(for: sample.startDate)),
                 extra: ["source": sample.sourceRevision.source.bundleIdentifier])
    }

    private func workoutDTOs(_ workouts: [HKWorkout]) async throws -> [WorkoutDTO] {
        guard !workouts.isEmpty else { return [] }
        var efforts: [EffortSample] = []
        if #available(iOS 18.0, *) {
            let unit = HKUnit.appleEffortScore()
            let lo = (workouts.map { $0.startDate }.min() ?? Date()).addingTimeInterval(-3600)
            let hi = (workouts.map { $0.endDate }.max() ?? Date()).addingTimeInterval(3600)
            for (index, type) in MetricCatalog.effortTypes.enumerated() {
                let found = try await tolerant([HKSample](), { try await self.samples(type, from: lo, to: hi) })
                for case let sample as HKQuantitySample in found where sample.quantity.is(compatibleWith: unit) {
                    efforts.append(EffortSample(start: sample.startDate, value: sample.quantity.doubleValue(for: unit),
                                                estimated: index == 1))
                }
            }
        }
        var out: [WorkoutDTO] = []
        for workout in workouts.sorted(by: { $0.startDate < $1.startDate }) {
            try Task.checkCancellation()
            out.append(try await workoutDTO(workout, efforts: efforts))
        }
        return out
    }

    private func workoutDTO(_ workout: HKWorkout, efforts: [EffortSample]) async throws -> WorkoutDTO {
        let bpm = Units.bpm
        let kcal = workout.statistics(for: MetricCatalog.activeEnergy)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        var distance: Double?
        for id in MetricCatalog.workoutDistances {
            if let q = workout.statistics(for: HKQuantityType(id))?.sumQuantity(), q.is(compatibleWith: Units.km) {
                distance = q.doubleValue(for: Units.km)
                break
            }
        }

        // Heart rate: the workout's own statistics, else computed from the HR samples in its time window.
        let hr = workout.statistics(for: MetricCatalog.heartRate)
        var avgHR = hr?.averageQuantity()?.doubleValue(for: bpm)
        var maxHR = hr?.maximumQuantity()?.doubleValue(for: bpm)
        var minHR = hr?.minimumQuantity()?.doubleValue(for: bpm)
        if avgHR == nil {
            let start = workout.startDate, end = workout.endDate
            let range = try await tolerant(HeartRange(), { try await self.heartRange(from: start, to: end) })
            avgHR = range.avg
            maxHR = maxHR ?? range.max
            minHR = minHR ?? range.min
        }

        var extra: [String: Double] = [:]
        let extras: [(String, HKQuantityTypeIdentifier, HKUnit)] = [
            ("running_power", .runningPower, .watt()),
            ("running_speed", .runningSpeed, Units.mps),
            ("running_stride_length", .runningStrideLength, .meter()),
            ("running_vertical_oscillation", .runningVerticalOscillation, Units.cm),
            ("running_ground_contact_time", .runningGroundContactTime, Units.ms),
            ("cycling_power", .cyclingPower, .watt()),
            ("cycling_speed", .cyclingSpeed, Units.mps),
            ("cycling_cadence", .cyclingCadence, Units.bpm),
        ]
        for (key, id, unit) in extras {
            guard let stats = workout.statistics(for: HKQuantityType(id)) else { continue }
            if let q = stats.averageQuantity(), q.is(compatibleWith: unit) { extra[key + "_avg"] = round(q.doubleValue(for: unit), 3) }
            if let q = stats.maximumQuantity(), q.is(compatibleWith: unit) { extra[key + "_max"] = round(q.doubleValue(for: unit), 3) }
        }
        let strokes = workout.statistics(for: HKQuantityType(.swimmingStrokeCount))?.sumQuantity()?.doubleValue(for: .count())

        let meta = workout.metadata ?? [:]
        var elevation: Double?
        if let q = meta[HKMetadataKeyElevationAscended] as? HKQuantity, q.is(compatibleWith: .meter()) {
            elevation = round(q.doubleValue(for: .meter()), 1)
        }
        if let q = meta[HKMetadataKeyElevationDescended] as? HKQuantity, q.is(compatibleWith: .meter()) {
            extra["elevation_descended_m"] = round(q.doubleValue(for: .meter()), 1)
        }
        if let q = meta[HKMetadataKeyAverageMETs] as? HKQuantity, q.is(compatibleWith: Units.met) {
            extra["avg_mets"] = round(q.doubleValue(for: Units.met), 2)
        }
        if let q = meta[HKMetadataKeyWeatherTemperature] as? HKQuantity, q.is(compatibleWith: .degreeCelsius()) {
            extra["weather_temp_c"] = round(q.doubleValue(for: .degreeCelsius()), 1)
        }
        if let q = meta[HKMetadataKeyWeatherHumidity] as? HKQuantity, q.is(compatibleWith: .percent()) {
            extra["weather_humidity_pct"] = round(q.doubleValue(for: .percent()) * 100, 0)
        }
        let indoor = (meta[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue

        // Effort (iOS 18+): the user's rating wins over Apple's estimate.
        func effort(estimated: Bool) -> Double? {
            let candidates = efforts.filter { e in
                e.estimated == estimated &&
                    (abs(e.start.timeIntervalSince(workout.startDate)) < 300 ||
                     (e.start >= workout.startDate && e.start <= workout.endDate))
            }
            return candidates.min(by: {
                abs($0.start.timeIntervalSince(workout.startDate)) < abs($1.start.timeIntervalSince(workout.startDate))
            })?.value
        }

        return WorkoutDTO(
            id: workout.uuid.uuidString,
            type: workout.workoutActivityType.italianName,
            activity: String(workout.workoutActivityType.rawValue),
            day: dayString(calendar.startOfDay(for: workout.startDate)),
            start: isoFormatter.string(from: workout.startDate),
            end: isoFormatter.string(from: workout.endDate),
            duration_min: (workout.duration / 6).rounded() / 10,
            distance_km: distance.map { round($0, 2) },
            kcal: kcal.map { $0.rounded() },
            avg_hr: avgHR.map { $0.rounded() },
            max_hr: maxHR.map { $0.rounded() },
            min_hr: minHR.map { $0.rounded() },
            elevation_m: elevation,
            effort: effort(estimated: false) ?? effort(estimated: true),
            effort_estimated: effort(estimated: true),
            swim_strokes: strokes.map { $0.rounded() },
            indoor: indoor,
            extra: extra.isEmpty ? nil : extra,
            source_bundle: workout.sourceRevision.source.bundleIdentifier,
            source_name: workout.sourceRevision.source.name
        )
    }

    private func send(_ payload: IngestPayload, config: IngestConfig, background: Bool) async throws -> Int {
        guard !payload.isEmpty else { return 0 }
        var posts = 0
        for chunk in payload.chunked(limit: 250) {
            try Task.checkCancellation()
            _ = try await IngestClient.post(chunk, config: config, maxAttempts: background ? 3 : 4)
            posts += 1
            await progress()
        }
        return posts
    }

    // MARK: - HealthKit helpers

    /// Runs one HealthKit read; a failure limited to that type (e.g. permission never asked) skips it
    /// instead of failing the whole sync. A locked device or a cancellation still aborts.
    private func tolerant<T>(_ fallback: T, _ body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await progress()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let hkError = error as? HKError, hkError.code == .errorDatabaseInaccessible { throw error }
            return fallback
        }
    }

    /// Runs one HealthKit query with a hard timeout: whichever comes first (the answer or the timeout)
    /// resumes the caller exactly once; on timeout the query is stopped.
    private func execute<T>(_ make: (ResumeOnce<T>) -> HKQuery) async throws -> T {
        let store = self.store
        let timeout = queryTimeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            let query = make(once)
            store.execute(query)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.resume(.failure(SyncError.timeout)) { store.stop(query) }
            }
        }
    }

    private func anchoredQuery(type: HKSampleType, predicate: NSPredicate?, anchor: HKQueryAnchor?) async throws -> AnchoredResult {
        try await execute { (once: ResumeOnce<AnchoredResult>) in
            HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                  limit: HKObjectQueryNoLimit) { _, samples, deleted, newAnchor, error in
                if let error = error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(AnchoredResult(samples: samples ?? [], deleted: deleted ?? [], anchor: newAnchor)))
                }
            }
        }
    }

    /// Daily activity totals come from Apple sources only (Apple Watch and iPhone, bundle ids "com.apple.health.*").
    /// HealthKit's statistics de-duplicate Watch vs iPhone, but they ADD samples from any other app that writes the
    /// same type, and third-party apps have written implausible energy values (hundreds of thousands of kcal).
    static let appleOnlyKeys: Set<String> = ["active_energy_burned", "basal_energy_burned", "step_count",
                                             "distance_walking_running", "apple_exercise_time", "flights_climbed"]

    private func appleSources(for type: HKSampleType) async throws -> Set<HKSource> {
        try await execute { (once: ResumeOnce<Set<HKSource>>) in
            HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
                if let error = error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success((sources ?? []).filter { $0.bundleIdentifier.hasPrefix("com.apple.health") }))
                }
            }
        }
    }

    private func dailyStatistics(_ spec: QuantitySpec, from start: Date, to end: Date) async throws -> [Date: [Agg: Double]] {
        var predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        if Self.appleOnlyKeys.contains(spec.key) {
            let sources = try await appleSources(for: spec.type)
            if sources.isEmpty { return [:] }
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, HKQuery.predicateForObjects(from: sources)])
        }
        let finalPredicate = predicate
        let aggs = spec.effectiveAggs
        return try await execute { (once: ResumeOnce<[Date: [Agg: Double]]>) in
            let query = HKStatisticsCollectionQuery(quantityType: spec.type,
                                                    quantitySamplePredicate: finalPredicate,
                                                    options: spec.statisticsOptions,
                                                    anchorDate: start,
                                                    intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error = error {
                    once.resume(.failure(error))
                    return
                }
                var values: [Date: [Agg: Double]] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    var row: [Agg: Double] = [:]
                    for agg in aggs {
                        if let v = spec.value(agg, from: statistics) { row[agg] = v }
                    }
                    if !row.isEmpty { values[statistics.startDate] = row }
                }
                once.resume(.success(values))
            }
            return query
        }
    }

    private func samples(_ type: HKSampleType, from start: Date, to end: Date) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return try await execute { (once: ResumeOnce<[HKSample]>) in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                          sortDescriptors: nil) { _, results, error in
                if let error = error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(results ?? []))
                }
            }
        }
    }

    private struct HeartRange {
        var avg: Double?
        var min: Double?
        var max: Double?
    }

    private func heartRange(from start: Date, to end: Date) async throws -> HeartRange {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return try await execute { (once: ResumeOnce<HeartRange>) in
            HKStatisticsQuery(quantityType: MetricCatalog.heartRate, quantitySamplePredicate: predicate,
                              options: [.discreteAverage, .discreteMin, .discreteMax]) { _, statistics, error in
                if let error = error {
                    // HKStatisticsQuery reports "no samples" as an error.
                    if let hkError = error as? HKError, hkError.code == .errorNoData {
                        once.resume(.success(HeartRange()))
                    } else {
                        once.resume(.failure(error))
                    }
                    return
                }
                let bpm = Units.bpm
                once.resume(.success(HeartRange(avg: statistics?.averageQuantity()?.doubleValue(for: bpm),
                                                min: statistics?.minimumQuantity()?.doubleValue(for: bpm),
                                                max: statistics?.maximumQuantity()?.doubleValue(for: bpm))))
            }
        }
    }

    // MARK: - Anchors & dates

    private func loadAnchor(_ key: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchors(_ anchors: [String: HKQueryAnchor]) {
        for (key, anchor) in anchors {
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func dayString(_ day: Date) -> String {
        dayFormatter.string(from: day)
    }

    private func round(_ v: Double, _ decimals: Int) -> Double {
        let p = pow(10.0, Double(decimals))
        return (v * p).rounded() / p
    }

    private func days(from start: Date, through end: Date) -> [Date] {
        var result: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day <= end {
            result.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

/// Resumes a continuation exactly once (HealthKit answer vs. timeout race).
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        if done {
            lock.unlock()
            return false
        }
        done = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
