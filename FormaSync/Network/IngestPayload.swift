import Foundation

/// Body of POST /api/ingest/health in the "forma-sync/2" format (generic, any HealthKit type).
/// The server still accepts "forma-sync/1" from older builds.
struct IngestPayload: Encodable {
    var format: String = "forma-sync/2"
    var app: String
    var tz: String
    var quantities: [QuantityDTO] = []
    var events: [EventDTO] = []
    var workouts: [WorkoutDTO] = []
    var deleted_workouts: [String] = []
    var deleted_events: [String] = []

    var itemCount: Int { quantities.count + events.count + workouts.count * 4 + deleted_workouts.count + deleted_events.count }
    var isEmpty: Bool { quantities.isEmpty && events.isEmpty && workouts.isEmpty && deleted_workouts.isEmpty && deleted_events.isEmpty }
}

/// One daily value (`date`, local calendar day) or one interval value (`start`/`end`).
struct QuantityDTO: Encodable {
    var type: String
    var unit: String
    var date: String?
    var start: String?
    var end: String?
    var value: Double
    var agg: String
}

/// A category sample (sleep stage, mindful session, …). `id` is the HealthKit UUID.
struct EventDTO: Encodable {
    var id: String
    var type: String
    var value: String
    var start: String
    var end: String
    var day: String
    var extra: [String: String]?
}

struct WorkoutDTO: Encodable {
    var id: String
    var type: String
    var activity: String
    var day: String
    var start: String
    var end: String
    var duration_min: Double
    var distance_km: Double?
    var kcal: Double?
    var avg_hr: Double?
    var max_hr: Double?
    var min_hr: Double?
    var elevation_m: Double?
    var effort: Double?
    var effort_estimated: Double?
    var swim_strokes: Double?
    var indoor: Bool?
    var extra: [String: Double]?
    /// App that wrote the workout into Health (Apple Watch = "com.apple.health.<device>"); lets the server keep the
    /// Watch copy when WHOOP or another app wrote the same session too.
    var source_bundle: String?
    var source_name: String?
}

struct IngestResponse: Decodable {
    var ok: Bool
    var samples: Int?
    var quantities: Int?
    var events: Int?
    var workouts: Int?
    var deleted: Int?
}

extension IngestPayload {
    /// Splits a large payload into POSTs of at most `limit` items (Workers Free plan: keep each request small).
    func chunked(limit: Int = 250) -> [IngestPayload] {
        if itemCount <= limit { return [self] }
        var out: [IngestPayload] = []
        var current = IngestPayload(app: app, tz: tz)
        func flushIfNeeded(adding cost: Int) {
            if current.itemCount + cost > limit && !current.isEmpty {
                out.append(current)
                current = IngestPayload(app: app, tz: tz)
            }
        }
        // Data first, deletions last: if the run is interrupted, the useful part has already arrived.
        for q in quantities { flushIfNeeded(adding: 1); current.quantities.append(q) }
        for e in events { flushIfNeeded(adding: 1); current.events.append(e) }
        for w in workouts { flushIfNeeded(adding: 4); current.workouts.append(w) }
        for id in deleted_workouts { flushIfNeeded(adding: 1); current.deleted_workouts.append(id) }
        for id in deleted_events { flushIfNeeded(adding: 1); current.deleted_events.append(id) }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
