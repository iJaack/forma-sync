import HealthKit

/// Daily aggregation sent for a quantity type. Raw values are the `agg` field of "forma-sync/2".
enum Agg: String {
    case sum, avg, min, max, last
}

/// One HealthKit quantity type sent to Forma as a daily series.
/// `key` is the server-side type name (snake_case of the HealthKit identifier); the server stores any key,
/// so adding a row here needs no server change.
struct QuantitySpec {
    let key: String
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let unitLabel: String
    let scale: Double
    let decimals: Int
    let aggs: [Agg]
    let observe: Bool

    init(_ key: String, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit, _ unitLabel: String,
         scale: Double = 1, decimals: Int = 1, aggs: [Agg] = [.avg], observe: Bool = false) {
        self.key = key
        self.identifier = identifier
        self.unit = unit
        self.unitLabel = unitLabel
        self.scale = scale
        self.decimals = decimals
        self.aggs = aggs
        self.observe = observe
    }

    var type: HKQuantityType { HKQuantityType(identifier) }

    /// Cumulative types (energy, steps, distance, …) only support a sum; discrete types never do.
    /// Picking the options from the type's aggregation style avoids HealthKit's
    /// "incompatible statistics options" exception.
    var isCumulative: Bool { type.aggregationStyle == .cumulative }

    var effectiveAggs: [Agg] {
        if isCumulative { return [.sum] }
        let discrete = aggs.filter { $0 != .sum }
        return discrete.isEmpty ? [.avg] : discrete
    }

    var statisticsOptions: HKStatisticsOptions {
        var options: HKStatisticsOptions = []
        for agg in effectiveAggs {
            switch agg {
            case .sum: options.insert(.cumulativeSum)
            case .avg: options.insert(.discreteAverage)
            case .min: options.insert(.discreteMin)
            case .max: options.insert(.discreteMax)
            case .last: options.insert(.mostRecent)
            }
        }
        return options
    }

    /// Guard against a wrong unit (doubleValue(for:) raises an Objective-C exception on mismatch).
    var unitIsCompatible: Bool { type.is(compatibleWith: unit) }

    func value(_ agg: Agg, from statistics: HKStatistics) -> Double? {
        let quantity: HKQuantity?
        switch agg {
        case .sum: quantity = statistics.sumQuantity()
        case .avg: quantity = statistics.averageQuantity()
        case .min: quantity = statistics.minimumQuantity()
        case .max: quantity = statistics.maximumQuantity()
        case .last: quantity = statistics.mostRecentQuantity()
        }
        guard let q = quantity, q.is(compatibleWith: unit) else { return nil }
        let v = q.doubleValue(for: unit) * scale
        guard v.isFinite else { return nil }
        let p = pow(10.0, Double(decimals))
        return (v * p).rounded() / p
    }
}

enum Units {
    static let bpm = HKUnit.count().unitDivided(by: .minute())
    static let ms = HKUnit.secondUnit(with: .milli)
    static let km = HKUnit.meterUnit(with: .kilo)
    static let cm = HKUnit.meterUnit(with: .centi)
    static let kg = HKUnit.gramUnit(with: .kilo)
    static let ml = HKUnit.literUnit(with: .milli)
    static let mg = HKUnit.gramUnit(with: .milli)
    static let mps = HKUnit.meter().unitDivided(by: .second())
    /// ml/(kg·min)
    static let vo2 = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
    /// kcal/(kg·h) — Apple "physical effort" (METs)
    static let met = HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
}

enum MetricCatalog {
    /// Everything read from Health. All identifiers exist on iOS 17 (the deployment target).
    /// Server keys used by the dashboard: see README-it.md ("Metriche").
    static let quantities: [QuantitySpec] = [
        // Energy
        QuantitySpec("active_energy_burned", .activeEnergyBurned, .kilocalorie(), "kcal", decimals: 0, observe: true),
        QuantitySpec("basal_energy_burned", .basalEnergyBurned, .kilocalorie(), "kcal", decimals: 0, observe: true),
        // Activity
        QuantitySpec("step_count", .stepCount, .count(), "count", decimals: 0, observe: true),
        QuantitySpec("distance_walking_running", .distanceWalkingRunning, Units.km, "km", decimals: 2, observe: true),
        QuantitySpec("distance_cycling", .distanceCycling, Units.km, "km", decimals: 2),
        QuantitySpec("distance_swimming", .distanceSwimming, .meter(), "m", decimals: 0),
        QuantitySpec("swimming_stroke_count", .swimmingStrokeCount, .count(), "count", decimals: 0),
        QuantitySpec("flights_climbed", .flightsClimbed, .count(), "count", decimals: 0),
        QuantitySpec("apple_exercise_time", .appleExerciseTime, .minute(), "min", decimals: 0, observe: true),
        QuantitySpec("apple_stand_time", .appleStandTime, .minute(), "min", decimals: 0),
        QuantitySpec("apple_move_time", .appleMoveTime, .minute(), "min", decimals: 0),
        QuantitySpec("time_in_daylight", .timeInDaylight, .minute(), "min", decimals: 0),
        QuantitySpec("physical_effort", .physicalEffort, Units.met, "kcal/hr·kg", decimals: 2, aggs: [.avg, .max]),
        // Heart
        QuantitySpec("heart_rate", .heartRate, Units.bpm, "bpm", decimals: 0, aggs: [.min, .avg, .max]),
        QuantitySpec("resting_heart_rate", .restingHeartRate, Units.bpm, "bpm", decimals: 1, observe: true),
        QuantitySpec("walking_heart_rate_average", .walkingHeartRateAverage, Units.bpm, "bpm", decimals: 1),
        QuantitySpec("heart_rate_variability_sdnn", .heartRateVariabilitySDNN, Units.ms, "ms", decimals: 1, observe: true),
        QuantitySpec("vo2_max", .vo2Max, Units.vo2, "ml/kg/min", decimals: 2, observe: true),
        QuantitySpec("heart_rate_recovery_one_minute", .heartRateRecoveryOneMinute, Units.bpm, "bpm", decimals: 1),
        // Respiratory / temperature
        QuantitySpec("respiratory_rate", .respiratoryRate, Units.bpm, "count/min", decimals: 2, observe: true),
        QuantitySpec("oxygen_saturation", .oxygenSaturation, .percent(), "%", scale: 100, decimals: 2, aggs: [.avg, .min], observe: true),
        QuantitySpec("body_temperature", .bodyTemperature, .degreeCelsius(), "degC", decimals: 2),
        QuantitySpec("apple_sleeping_wrist_temperature", .appleSleepingWristTemperature, .degreeCelsius(), "degC", decimals: 2, observe: true),
        // Body
        QuantitySpec("body_mass", .bodyMass, Units.kg, "kg", decimals: 2, aggs: [.last], observe: true),
        QuantitySpec("body_fat_percentage", .bodyFatPercentage, .percent(), "%", scale: 100, decimals: 2, aggs: [.last], observe: true),
        QuantitySpec("lean_body_mass", .leanBodyMass, Units.kg, "kg", decimals: 2, aggs: [.last]),
        QuantitySpec("body_mass_index", .bodyMassIndex, .count(), "count", decimals: 2, aggs: [.last]),
        QuantitySpec("height", .height, Units.cm, "cm", decimals: 1, aggs: [.last]),
        // Mobility
        QuantitySpec("walking_speed", .walkingSpeed, Units.mps, "m/s", decimals: 3),
        QuantitySpec("walking_step_length", .walkingStepLength, Units.cm, "cm", decimals: 1),
        QuantitySpec("walking_asymmetry_percentage", .walkingAsymmetryPercentage, .percent(), "%", scale: 100, decimals: 2),
        QuantitySpec("walking_double_support_percentage", .walkingDoubleSupportPercentage, .percent(), "%", scale: 100, decimals: 2),
        QuantitySpec("apple_walking_steadiness", .appleWalkingSteadiness, .percent(), "%", scale: 100, decimals: 1, aggs: [.last]),
        QuantitySpec("stair_ascent_speed", .stairAscentSpeed, Units.mps, "m/s", decimals: 3),
        QuantitySpec("stair_descent_speed", .stairDescentSpeed, Units.mps, "m/s", decimals: 3),
        QuantitySpec("six_minute_walk_test_distance", .sixMinuteWalkTestDistance, .meter(), "m", decimals: 0, aggs: [.last]),
        // Running / cycling
        QuantitySpec("running_speed", .runningSpeed, Units.mps, "m/s", decimals: 3, aggs: [.avg, .max]),
        QuantitySpec("running_power", .runningPower, .watt(), "W", decimals: 0, aggs: [.avg, .max]),
        QuantitySpec("running_stride_length", .runningStrideLength, .meter(), "m", decimals: 3),
        QuantitySpec("running_vertical_oscillation", .runningVerticalOscillation, Units.cm, "cm", decimals: 2),
        QuantitySpec("running_ground_contact_time", .runningGroundContactTime, Units.ms, "ms", decimals: 0),
        QuantitySpec("cycling_speed", .cyclingSpeed, Units.mps, "m/s", decimals: 3, aggs: [.avg, .max]),
        QuantitySpec("cycling_power", .cyclingPower, .watt(), "W", decimals: 0, aggs: [.avg, .max]),
        QuantitySpec("cycling_cadence", .cyclingCadence, Units.bpm, "count/min", decimals: 0),
        // Audio exposure (dBA)
        QuantitySpec("environmental_audio_exposure", .environmentalAudioExposure, .decibelAWeightedSoundPressureLevel(), "dBASPL", decimals: 1, aggs: [.avg, .max]),
        QuantitySpec("headphone_audio_exposure", .headphoneAudioExposure, .decibelAWeightedSoundPressureLevel(), "dBASPL", decimals: 1, aggs: [.avg, .max]),
        // Nutrition (only if some app writes it)
        QuantitySpec("dietary_energy_consumed", .dietaryEnergyConsumed, .kilocalorie(), "kcal", decimals: 0, observe: true),
        QuantitySpec("dietary_protein", .dietaryProtein, .gram(), "g", decimals: 1),
        QuantitySpec("dietary_carbohydrates", .dietaryCarbohydrates, .gram(), "g", decimals: 1),
        QuantitySpec("dietary_fat_total", .dietaryFatTotal, .gram(), "g", decimals: 1),
        QuantitySpec("dietary_fiber", .dietaryFiber, .gram(), "g", decimals: 1),
        QuantitySpec("dietary_sugar", .dietarySugar, .gram(), "g", decimals: 1),
        QuantitySpec("dietary_water", .dietaryWater, Units.ml, "ml", decimals: 0),
        QuantitySpec("dietary_caffeine", .dietaryCaffeine, Units.mg, "mg", decimals: 0),
    ]

    static let heartRate = HKQuantityType(.heartRate)
    static let activeEnergy = HKQuantityType(.activeEnergyBurned)
    static let sleep = HKCategoryType(.sleepAnalysis)
    static let standHour = HKCategoryType(.appleStandHour)
    static let mindful = HKCategoryType(.mindfulSession)
    static let workout = HKObjectType.workoutType()
    static let workoutDistances: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming,
                                                              .distanceDownhillSnowSports, .distanceWheelchair]

    /// iOS 18+: Apple "effort" ratings attached to workouts (1–10).
    static var effortTypes: [HKQuantityType] {
        if #available(iOS 18.0, *) {
            return [HKQuantityType(.workoutEffortScore), HKQuantityType(.estimatedWorkoutEffortScore)]
        }
        return []
    }

    /// Read-only permissions. Nothing is ever written to Health. No routes (GPS), no clinical records.
    static var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        for spec in quantities { set.insert(spec.type) }
        for id in workoutDistances { set.insert(HKQuantityType(id)) }
        set.insert(sleep)
        set.insert(standHour)
        set.insert(mindful)
        set.insert(workout)
        for type in effortTypes { set.insert(type) }
        return set
    }

    /// Types watched with HKObserverQuery + background delivery (heart rate is too chatty to observe).
    static var observedTypes: [HKSampleType] {
        var types: [HKSampleType] = quantities.filter { $0.observe }.map { $0.type }
        types.append(workout)
        types.append(sleep)
        types.append(mindful)
        return types
    }

    /// Bump when readTypes grows, so the app asks again for the new types.
    static let authorizationVersion = 2
}
