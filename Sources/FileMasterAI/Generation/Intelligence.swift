import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device LLM availability (Apple Foundation Models). Used by the UI to decide
/// whether to offer written answers and to explain when it can't. All actual
/// generation is gated behind `@available(macOS 26, *)` elsewhere; this is the
/// single place that answers "is the model usable right now?".
public enum Intelligence {
    public static var isAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Why the model can't be used, for the UI. Nil when available.
    public static var unavailabilityReason: String? {
        guard #available(macOS 26, *) else {
            return "Written answers need macOS 26 with Apple Intelligence. Ask still finds and cites passages."
        }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence. Ask still finds and cites passages."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to get written answers."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading."
        case .unavailable:
            return "The on-device model is unavailable. Ask still finds and cites passages."
        }
        #else
        return "Built without FoundationModels."
        #endif
    }
}
