import Foundation

enum ContentSubmissionCoordinatorError: Error, Equatable, LocalizedError {
    case operationInProgress
    case sessionTransition
    case newThreadsDisabled
    case repliesDisabled

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "同一位置已有内容正在发送，请等待发送完成。"
        case .sessionTransition:
            return "账号状态正在切换，请稍后重试。"
        case .newThreadsDisabled:
            return "请先在设置中开启“允许发帖”。"
        case .repliesDisabled:
            return "请先在设置中开启“允许回帖”。"
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

    enum AccountWriteTarget: Hashable, Sendable {
        case profile
        case deleteThread(Int64)
    }

    private struct AccountWriteKey: Hashable, Sendable {
        let accountID: String
        let target: AccountWriteTarget
    }

    private struct AccountWrite {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let api: any TiebaAPIService
    private let allowsSubmission: @MainActor (ContentSubmissionKind) -> Bool
    private var operations: [OperationKey: Operation] = [:]
    private var accountWrites: [AccountWriteKey: AccountWrite] = [:]
    private var globalInvalidationCount = 0
    private var accountInvalidationCounts: [String: Int] = [:]

    init(
        api: any TiebaAPIService,
        allowsSubmission: @escaping @MainActor (ContentSubmissionKind) -> Bool = { _ in true }
    ) {
        self.api = api
        self.allowsSubmission = allowsSubmission
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
        guard allowsSubmission(request.target.kind) else {
            switch request.target.kind {
            case .newThread:
                throw ContentSubmissionCoordinatorError.newThreadsDisabled
            case .threadReply, .postReply, .subpostReply:
                throw ContentSubmissionCoordinatorError.repliesDisabled
            }
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

    /// Registers non-composer account mutations with the same session barrier
    /// used by logout and account replacement. The stored task survives a view
    /// dismissal, but session invalidation cancels and drains it before account
    /// artifacts are cleared.
    func performAccountWrite(
        account: Account,
        target: AccountWriteTarget,
        coalescesConcurrentCalls: Bool = false,
        operation: @escaping () async throws -> Void
    ) async throws {
        guard canSubmit(accountID: account.id) else {
            throw ContentSubmissionCoordinatorError.sessionTransition
        }

        let key = AccountWriteKey(accountID: account.id, target: target)
        if let existing = accountWrites[key] {
            guard coalescesConcurrentCalls else {
                throw ContentSubmissionCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        let id = UUID()
        let task = Task {
            try await operation()
        }
        accountWrites[key] = AccountWrite(id: id, task: task)

        do {
            try await task.value
            finishAccountWrite(id: id, for: key)
        } catch {
            finishAccountWrite(id: id, for: key)
            throw error
        }
    }

    /// Closes the matching submission entry point synchronously. Callers that
    /// coordinate multiple write domains must establish every barrier before
    /// awaiting any drain operation.
    func establishInvalidationBarrier(accountID: String? = nil) {
        if let accountID {
            accountInvalidationCounts[accountID, default: 0] += 1
        } else {
            globalInvalidationCount += 1
        }
    }

    /// Cancels and drains writes covered by an already-established barrier.
    func drainInvalidatedOperations(accountID: String? = nil) async {
        await drainOperations(accountID: accountID)
    }

    /// Closes the matching submission entry point before draining active writes.
    /// The barrier remains active until the matching `endInvalidation` call.
    func beginInvalidation(accountID: String? = nil) async {
        establishInvalidationBarrier(accountID: accountID)
        await drainInvalidatedOperations(accountID: accountID)
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

    private func finishAccountWrite(id: UUID, for key: AccountWriteKey) {
        guard accountWrites[key]?.id == id else { return }
        accountWrites[key] = nil
    }

    private func canSubmit(accountID: String) -> Bool {
        globalInvalidationCount == 0 && accountInvalidationCounts[accountID] == nil
    }

    private func drainOperations(accountID: String?) async {
        while true {
            let matching = operations.filter { key, _ in
                accountID == nil || key.accountID == accountID
            }
            let matchingAccountWrites = accountWrites.filter { key, _ in
                accountID == nil || key.accountID == accountID
            }
            guard matching.isEmpty == false || matchingAccountWrites.isEmpty == false else {
                return
            }

            matching.values.forEach { $0.task.cancel() }
            matchingAccountWrites.values.forEach { $0.task.cancel() }
            for operation in matching.values {
                _ = await operation.task.result
            }
            for write in matchingAccountWrites.values {
                _ = await write.task.result
            }
            for (key, operation) in matching {
                finishOperation(id: operation.id, for: key)
            }
            for (key, write) in matchingAccountWrites {
                finishAccountWrite(id: write.id, for: key)
            }
        }
    }
}
