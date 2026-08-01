import Foundation

enum ContentSubmissionCoordinatorError: Error, Equatable, LocalizedError {
    case operationInProgress
    case sessionTransition

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "同一位置已有内容正在发送，请等待发送完成。"
        case .sessionTransition:
            return "账号状态正在切换，请稍后重试。"
        }
    }
}

@MainActor
final class ContentSubmissionCoordinator {
    struct OperationKey: Hashable, Sendable {
        let accountID: String
        let targetKey: String
    }

    private struct Operation {
        let id: UUID
        let request: ContentSubmissionRequest
        let task: Task<ContentSubmissionReceipt, Error>
    }

    private let api: any TiebaAPIService
    private var operations: [OperationKey: Operation] = [:]
    private var globalInvalidationCount = 0
    private var accountInvalidationCounts: [String: Int] = [:]

    init(api: any TiebaAPIService) {
        self.api = api
    }

    static func operationKey(
        account: Account,
        target: ContentSubmissionTarget
    ) -> OperationKey {
        OperationKey(accountID: account.id, targetKey: target.draftKey)
    }

    func isSubmitting(account: Account, target: ContentSubmissionTarget) -> Bool {
        operations[Self.operationKey(account: account, target: target)] != nil
    }

    func isInvalidating(accountID: String) -> Bool {
        canSubmit(accountID: accountID) == false
    }

    func submit(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        guard canSubmit(accountID: account.id) else {
            throw ContentSubmissionCoordinatorError.sessionTransition
        }
        let key = Self.operationKey(account: account, target: request.target)
        if let existing = operations[key] {
            guard existing.request == request else {
                throw ContentSubmissionCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        let operationID = UUID()
        let api = api
        let task = Task {
            try await api.submitContent(account: account, request: request)
        }
        operations[key] = Operation(id: operationID, request: request, task: task)

        do {
            let receipt = try await task.value
            finishOperation(id: operationID, for: key)
            return receipt
        } catch {
            finishOperation(id: operationID, for: key)
            throw error
        }
    }

    /// Closes the matching submission entry point before draining active writes.
    /// The barrier remains active until the matching `endInvalidation` call.
    func beginInvalidation(accountID: String? = nil) async {
        if let accountID {
            accountInvalidationCounts[accountID, default: 0] += 1
        } else {
            globalInvalidationCount += 1
        }
        await drainOperations(accountID: accountID)
    }

    func endInvalidation(accountID: String? = nil) {
        if let accountID {
            guard let count = accountInvalidationCounts[accountID] else { return }
            if count > 1 {
                accountInvalidationCounts[accountID] = count - 1
            } else {
                accountInvalidationCounts[accountID] = nil
            }
        } else {
            globalInvalidationCount = max(0, globalInvalidationCount - 1)
        }
    }

    func cancelAll(accountID: String? = nil) async {
        await beginInvalidation(accountID: accountID)
        endInvalidation(accountID: accountID)
    }

    private func finishOperation(id: UUID, for key: OperationKey) {
        guard operations[key]?.id == id else { return }
        operations[key] = nil
    }

    private func canSubmit(accountID: String) -> Bool {
        globalInvalidationCount == 0 && accountInvalidationCounts[accountID] == nil
    }

    private func drainOperations(accountID: String?) async {
        while true {
            let matching = operations.filter { key, _ in
                accountID == nil || key.accountID == accountID
            }
            guard matching.isEmpty == false else { return }

            matching.values.forEach { $0.task.cancel() }
            for operation in matching.values {
                _ = await operation.task.result
            }
            for (key, operation) in matching {
                finishOperation(id: operation.id, for: key)
            }
        }
    }
}
