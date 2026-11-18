import HealthKit

// The list of types read from Health lives in MetricCatalog.swift.

extension HKWorkoutActivityType {
    var italianName: String {
        switch self {
        case .running: return "Corsa"
        case .walking: return "Camminata"
        case .cycling: return "Ciclismo"
        case .swimming: return "Nuoto"
        case .hiking: return "Escursione"
        case .traditionalStrengthTraining: return "Forza"
        case .functionalStrengthTraining: return "Forza funzionale"
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining: return "Core"
        case .crossTraining: return "Cross training"
        case .mixedCardio: return "Cardio misto"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .flexibility: return "Mobilità"
        case .cooldown: return "Defaticamento"
        case .rowing: return "Vogatore"
        case .elliptical: return "Ellittica"
        case .stairClimbing: return "Scale"
        case .soccer: return "Calcio"
        case .tennis: return "Tennis"
        case .basketball: return "Basket"
        case .socialDance, .cardioDance: return "Danza"
        case .boxing, .kickboxing: return "Boxe"
        case .martialArts: return "Arti marziali"
        case .climbing: return "Arrampicata"
        case .downhillSkiing, .crossCountrySkiing: return "Sci"
        case .snowboarding: return "Snowboard"
        case .pickleball: return "Pickleball"
        case .tableTennis: return "Ping pong"
        case .badminton: return "Badminton"
        case .squash: return "Squash"
        case .golf: return "Golf"
        case .paddleSports: return "Pagaia"
        case .surfingSports: return "Surf"
        case .waterFitness: return "Acquagym"
        case .mindAndBody: return "Mente e corpo"
        case .stairs, .stepTraining: return "Scale"
        case .handCycling: return "Handbike"
        case .swimBikeRun: return "Triathlon"
        case .transition: return "Transizione"
        default: return "Altro"
        }
    }
}
