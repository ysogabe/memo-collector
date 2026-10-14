import CCCore
import Foundation

/// Evaluation-only descriptions. The product question stays unchanged until labeled evaluation supports adoption.
public struct IntentQuestionCandidate: Codable, Sendable {
    public let name: String
    public let instructions: String
    public let descriptions: [Intent: String]

    public init(name: String, instructions: String, descriptions: [Intent: String]) {
        self.name = name; self.instructions = instructions; self.descriptions = descriptions
    }

    public func validatedQuestion() throws -> D1Question {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(descriptions.keys) == Set(Intent.allCases),
              descriptions.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CandidateError.invalidDescriptions
        }
        return .choice(instructions: instructions, options: D1Questions.intentLabels.map {
            D1Option(label: $0.rawValue, description: descriptions[$0]!)
        })
    }

    public static var product: Self {
        guard case let .choice(instructions, options) = D1Questions.intent else { preconditionFailure() }
        return Self(name: "product", instructions: instructions,
                    descriptions: Dictionary(uniqueKeysWithValues: options.map { (Intent(rawValue: $0.label)!, $0.description!) }))
    }
    public enum CandidateError: Error { case invalidDescriptions }
}
