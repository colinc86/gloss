import Foundation

public enum RefinementError: Error, LocalizedError, Equatable, Sendable {
    case invalidChoices
    case questionClosed
    case invalidSelection
    case inactive
    case staleGeneration
    case pendingAnswers
    case invalidSummary
    public var errorDescription: String? {
        switch self {
        case .invalidChoices: "Choices must contain 2–12 distinct, nonblank options of at most 200 characters; multiple selection requires choices."
        case .questionClosed: "That question was answered or its note is no longer open."
        case .invalidSelection: "The selected options do not belong to that question."
        case .inactive: "This document is not actively refining."
        case .staleGeneration: "That refinement_id is stale or belongs to another document."
        case .pendingAnswers: "Questions or unsent answers remain in the current iteration; wait for the user's sent answers and act on them first."
        case .invalidSummary: "Provide a nonblank completion summary of at most 500 characters."
        }
    }
}

public struct QuestionChoices: Codable, Hashable, Sendable {
    public let options: [String]
    public let multi: Bool
    private enum CodingKeys: String, CodingKey { case options, multi }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode([String].self, forKey: .options), multi: values.decode(Bool.self, forKey: .multi))
    }
    public init(_ options: [String], multi: Bool = false) throws {
        let cleaned = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (2...12).contains(cleaned.count), cleaned.allSatisfy({ !$0.isEmpty && $0.count <= 200 }), Set(cleaned).count == cleaned.count else { throw RefinementError.invalidChoices }
        self.options = cleaned
        self.multi = multi
    }
}

public enum RefinementStatus: String, Codable, Sendable { case starting, active, completed, ended }
public struct Refinement: Sendable, Equatable {
    public let documentID: DocumentID
    public let generation: String
    public let status: RefinementStatus
    public let round: Int
    public let requestNoteID: NoteID?
    public let targetJSON: String
    public let startedAt: Date
    public let completedAt: Date?
    public let summary: String?
    public let error: String?
    public let awaitingNextRound: Bool
    public let hasAnswers: Bool
    public let dismissed: Bool
    public var emitsDirective: Bool { status == .starting || status == .active }
    public static let request = "Read this document and ask me about ambiguous or open-ended content. Apply my answers, make the changes, and keep refining until you have no more questions."
}
