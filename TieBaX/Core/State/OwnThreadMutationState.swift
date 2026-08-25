import Combine
import Foundation

enum OwnThreadMutationOutcome: Equatable, Sendable {
    case deleted
    case needsRefresh
}

struct OwnThreadMutationEvent: Equatable, Sendable {
    let accountID: String
    let threadID: Int64
    let outcome: OwnThreadMutationOutcome
}

@MainActor
final class OwnThreadMutationState {
    let didChange = PassthroughSubject<OwnThreadMutationEvent, Never>()
    private var unconfirmedDeletionKeys = Set<DeletionKey>()

    func hasUnconfirmedDeletion(accountID: String, threadID: Int64) -> Bool {
        unconfirmedDeletionKeys.contains(DeletionKey(
            accountID: accountID,
            threadID: threadID
        ))
    }

    func publish(
        accountID: String,
        threadID: Int64,
        outcome: OwnThreadMutationOutcome
    ) {
        let key = DeletionKey(accountID: accountID, threadID: threadID)
        switch outcome {
        case .deleted:
            unconfirmedDeletionKeys.remove(key)
        case .needsRefresh:
            unconfirmedDeletionKeys.insert(key)
        }
        didChange.send(OwnThreadMutationEvent(
            accountID: accountID,
            threadID: threadID,
            outcome: outcome
        ))
    }
}

private struct DeletionKey: Hashable {
    let accountID: String
    let threadID: Int64
}
