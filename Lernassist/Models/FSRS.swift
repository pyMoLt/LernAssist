import Foundation

/// FSRS-5 (Free Spaced Repetition Scheduler), der Standard-Algorithmus von Anki und RemNote.
/// Modelliert pro Karte Stabilität (Tage bis zur 90-%-Erinnerung) und Schwierigkeit (1–10) und
/// plant die nächste Wiederholung so, dass die gewünschte Behaltensrate erreicht wird – mit
/// weniger Wiederholungen als SM-2 bei gleichem Behalten.
/// Formeln und Standardgewichte: https://github.com/open-spaced-repetition/fsrs4anki (FSRS-5).
nonisolated struct FSRS: Sendable {
    /// Standardgewichte FSRS-5 (aus Millionen Anki-Wiederholungen optimiert).
    static let defaultWeights: [Double] = [
        0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
        1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621
    ]
    static let decay = -0.5
    static let factor = 19.0 / 81.0
    static let maximumIntervalDays = 3650.0

    var weights: [Double] = FSRS.defaultWeights
    /// Ziel-Behaltensrate (0,80–0,97). 0,9 = Standard.
    var desiredRetention: Double = 0.9

    private var w: [Double] { weights }

    /// Wahrscheinlichkeit, sich nach `elapsedDays` zu erinnern.
    func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1 + Self.factor * max(0, elapsedDays) / max(stability, 0.01), Self.decay)
    }

    /// Intervall (Tage), nach dem die Erinnerung auf die Ziel-Behaltensrate fällt.
    func interval(stability: Double) -> Double {
        let raw = stability / Self.factor * (pow(desiredRetention, 1 / Self.decay) - 1)
        return min(Self.maximumIntervalDays, max(1, raw.rounded()))
    }

    func initialStability(_ grade: Int) -> Double { max(0.1, w[grade - 1]) }

    func initialDifficulty(_ grade: Int) -> Double {
        clampDifficulty(w[4] - exp(w[5] * Double(grade - 1)) + 1)
    }

    func nextDifficulty(_ d: Double, grade: Int) -> Double {
        let delta = -w[6] * Double(grade - 3)
        let damped = d + delta * (10 - d) / 9
        // Rückführung zum Mittelwert, damit Schwierigkeit nicht dauerhaft am Rand klebt.
        return clampDifficulty(w[7] * initialDifficulty(4) + (1 - w[7]) * damped)
    }

    func stabilityAfterSuccess(s: Double, d: Double, r: Double, grade: Int) -> Double {
        let hardPenalty = grade == 2 ? w[15] : 1
        let easyBonus = grade == 4 ? w[16] : 1
        return s * (exp(w[8]) * (11 - d) * pow(s, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hardPenalty * easyBonus + 1)
    }

    func stabilityAfterForgetting(s: Double, d: Double, r: Double) -> Double {
        let forget = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp(w[14] * (1 - r))
        return max(0.1, min(forget, s))
    }

    /// Wiederholung am selben Tag (Lern-/Wiederlernschritt).
    func shortTermStability(s: Double, grade: Int) -> Double {
        max(0.1, s * exp(w[17] * (Double(grade) - 3 + w[18])))
    }

    private func clampDifficulty(_ d: Double) -> Double { min(10, max(1, d)) }
}

extension FlashcardRating {
    /// FSRS-Note: 1 = Nochmal, 2 = Schwer, 3 = Gut, 4 = Einfach.
    var grade: Int {
        switch self {
        case .again: return 1
        case .hard:  return 2
        case .good:  return 3
        case .easy:  return 4
        }
    }
}
