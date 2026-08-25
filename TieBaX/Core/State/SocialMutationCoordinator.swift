import Foundation

enum SocialMutationCoordinatorError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case operationInProgress
    case sessionTransition
    case likesDisabled

    var description: String {
        errorDescription ?? "操作失败。"
    }

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "操作正在处理中，请稍候。"
        case .sessionTransition:
            return "账号状态正在切换，请稍后重试。"
        case .likesDisabled:
            return "请先在设置中开启“允许点赞”。"
        }
    }
}

@MainActor
final class SocialMutationCoordinator {
    private struct OperationKey: Hashable {
        let session: AccountSessionIdentity
        let target: String
    }

    private struct UserOperation {
        let id: UUID
        let accountID: String
        let user: UserSummary
        let targetState: Bool
        let task: Task<Void, Error>
    }

    private struct ForumOperation {
        let id: UUID
        let accountID: String
        let forum: Forum
        let targetState: Bool
        let task: Task<ForumMembership, Error>
    }

    private struct LikeOperation {
        let id: UUID
        let targetState: Bool
        let task: Task<Void, Error>
    }

    private let api: any TieBaXAPIService
    private let state: SocialRelationshipState
    private let allowsLikes: @MainActor () -> Bool
    private var userOperations: [OperationKey: UserOperation] = [:]
    private var forumOperations: [OperationKey: ForumOperation] = [:]
    private var likeOperations: [OperationKey: LikeOperation] = [:]
    private var globalInvalidationCount = 0
    private var sessionInvalidationCounts: [AccountSessionIdentity: Int] = [:]

    init(
        api: any TieBaXAPIService,
        state: SocialRelationshipState,
        allowsLikes: @escaping @MainActor () -> Bool = { true }
    ) {
        self.api = api
        self.state = state
        self.allowsLikes = allowsLikes
    }

    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws {
        let session = account.sessionIdentity
        guard canMutate(session: session) else {
            throw SocialMutationCoordinatorError.sessionTransition
        }
        let key = OperationKey(
            session: session,
            target: "user|\(SocialRelationshipState.userOperationKey(user))"
        )
        if let existing = userOperations[key] {
            guard existing.targetState == followed else {
                throw SocialMutationCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        state.beginUserMutation(accountID: account.id, user: user)
        let operationID = UUID()
        let api = api
        let task = Task { @MainActor [weak self] in
            do {
                try await api.setUserFollowed(account: account, user: user, followed: followed)
                guard let self else { throw CancellationError() }
                try self.commitUserMutation(
                    id: operationID,
                    key: key,
                    user: user,
                    followed: followed
                )
            } catch {
                let originalError = error
                guard let self else { throw CancellationError() }
                guard Task.isCancelled == false,
                      originalError is CancellationError == false else {
                    self.finishUserOperation(id: operationID, for: key)
                    throw CancellationError()
                }
                let profile = try? await api.userProfile(account: account, user: user)
                guard Task.isCancelled == false else {
                    self.finishUserOperation(id: operationID, for: key)
                    throw CancellationError()
                }
                try self.commitUserReconciliation(
                    id: operationID,
                    key: key,
                    profile: profile
                )
                throw originalError
            }
        }
        userOperations[key] = UserOperation(
            id: operationID,
            accountID: account.id,
            user: user,
            targetState: followed,
            task: task
        )
        try await task.value
    }

    func setForumFollowed(account: Account, forum: Forum, followed: Bool) async throws -> ForumMembership {
        let session = account.sessionIdentity
        guard canMutate(session: session) else {
            throw SocialMutationCoordinatorError.sessionTransition
        }
        let key = OperationKey(
            session: session,
            target: "forum|\(SocialRelationshipState.forumOperationKey(forum))"
        )
        if let existing = forumOperations[key] {
            guard existing.targetState == followed else {
                throw SocialMutationCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        state.beginForumMutation(accountID: account.id, forum: forum)
        let operationID = UUID()
        let api = api
        let task = Task { @MainActor [weak self] in
            do {
                let membership = try await api.setForumFollowed(
                    account: account,
                    forum: forum,
                    followed: followed
                )
                guard let self else { throw CancellationError() }
                try self.commitForumMutation(
                    id: operationID,
                    key: key,
                    forum: forum,
                    membership: membership
                )
                return membership
            } catch {
                let originalError = error
                guard let self else { throw CancellationError() }
                guard Task.isCancelled == false,
                      originalError is CancellationError == false else {
                    self.finishForumOperation(id: operationID, for: key)
                    throw CancellationError()
                }
                let membership = try? await api.forumMembership(account: account, forum: forum)
                guard Task.isCancelled == false else {
                    self.finishForumOperation(id: operationID, for: key)
                    throw CancellationError()
                }
                try self.commitForumReconciliation(
                    id: operationID,
                    key: key,
                    forum: forum,
                    membership: membership
                )
                throw originalError
            }
        }
        forumOperations[key] = ForumOperation(
            id: operationID,
            accountID: account.id,
            forum: forum,
            targetState: followed,
            task: task
        )
        return try await task.value
    }

    func setPostLiked(
        account: Account,
        threadID: Int64,
        postID: UInt64,
        objectType: TiebaLikeObjectType,
        liked: Bool
    ) async throws {
        let session = account.sessionIdentity
        guard canMutate(session: session) else {
            throw SocialMutationCoordinatorError.sessionTransition
        }
        guard allowsLikes() else {
            throw SocialMutationCoordinatorError.likesDisabled
        }
        let key = OperationKey(
            session: session,
            target: "like|\(threadID)|\(postID)|\(objectType.rawValue)"
        )
        if let existing = likeOperations[key] {
            guard existing.targetState == liked else {
                throw SocialMutationCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        let operationID = UUID()
        let api = api
        let task = Task { @MainActor [weak self] in
            do {
                try await api.setPostLiked(
                    account: account,
                    threadID: threadID,
                    postID: postID,
                    objectType: objectType,
                    liked: liked
                )
                guard let self else { throw CancellationError() }
                try self.commitLikeMutation(id: operationID, key: key)
            } catch {
                guard let self else { throw CancellationError() }
                let shouldCancel = Task.isCancelled || error is CancellationError
                self.finishLikeOperation(id: operationID, for: key)
                if shouldCancel {
                    throw CancellationError()
                }
                throw error
            }
        }
        likeOperations[key] = LikeOperation(
            id: operationID,
            targetState: liked,
            task: task
        )
        try await task.value
    }

    func isInvalidating(session: AccountSessionIdentity) -> Bool {
        canMutate(session: session) == false
    }

    /// Closes the selected session (or every session) synchronously. Callers
    /// that coordinate multiple write domains must establish every barrier
    /// before awaiting any drain operation.
    func establishInvalidationBarrier(session: AccountSessionIdentity? = nil) {
        if let session {
            sessionInvalidationCounts[session, default: 0] += 1
        } else {
            globalInvalidationCount += 1
        }
    }

    /// Cancels and drains mutations covered by an already-established barrier.
    func drainInvalidatedOperations(session: AccountSessionIdentity? = nil) async {
        await drainOperations(session: session)
    }

    /// Closes the selected session (or every session) before cancelling and
    /// draining its stored social mutations. The barrier remains active until
    /// the matching `endInvalidation` call.
    func beginInvalidation(session: AccountSessionIdentity? = nil) async {
        establishInvalidationBarrier(session: session)
        await drainInvalidatedOperations(session: session)
    }

    func endInvalidation(session: AccountSessionIdentity? = nil) {
        if let session {
            guard let count = sessionInvalidationCounts[session] else { return }
            if count > 1 {
                sessionInvalidationCounts[session] = count - 1
            } else {
                sessionInvalidationCounts[session] = nil
            }
        } else {
            globalInvalidationCount = max(0, globalInvalidationCount - 1)
        }
    }

    private func canMutate(session: AccountSessionIdentity) -> Bool {
        globalInvalidationCount == 0 && sessionInvalidationCounts[session] == nil
    }

    private func commitUserMutation(
        id: UUID,
        key: OperationKey,
        user: UserSummary,
        followed: Bool
    ) throws {
        guard canMutate(session: key.session), userOperations[key]?.id == id else {
            finishUserOperation(id: id, for: key)
            throw CancellationError()
        }
        state.recordUserFollow(accountID: key.session.accountID, user: user, isFollowed: followed)
        finishUserOperation(id: id, for: key)
    }

    private func commitUserReconciliation(
        id: UUID,
        key: OperationKey,
        profile: UserProfile?
    ) throws {
        guard canMutate(session: key.session), userOperations[key]?.id == id else {
            finishUserOperation(id: id, for: key)
            throw CancellationError()
        }
        if let profile {
            state.recordUserFollow(
                accountID: key.session.accountID,
                user: profile.user,
                isFollowed: profile.isFollowed
            )
        }
        finishUserOperation(id: id, for: key)
    }

    private func commitForumMutation(
        id: UUID,
        key: OperationKey,
        forum: Forum,
        membership: ForumMembership
    ) throws {
        guard canMutate(session: key.session), forumOperations[key]?.id == id else {
            finishForumOperation(id: id, for: key)
            throw CancellationError()
        }
        recordForumMembership(key: key, forum: forum, membership: membership)
        finishForumOperation(id: id, for: key)
    }

    private func commitForumReconciliation(
        id: UUID,
        key: OperationKey,
        forum: Forum,
        membership: ForumMembership?
    ) throws {
        guard canMutate(session: key.session), forumOperations[key]?.id == id else {
            finishForumOperation(id: id, for: key)
            throw CancellationError()
        }
        if let membership {
            recordForumMembership(key: key, forum: forum, membership: membership)
        }
        finishForumOperation(id: id, for: key)
    }

    private func recordForumMembership(
        key: OperationKey,
        forum: Forum,
        membership: ForumMembership
    ) {
        var resolvedForum = forum
        resolvedForum.id = membership.forumID
        state.recordForumFollow(
            accountID: key.session.accountID,
            forum: resolvedForum,
            isFollowed: membership.isFollowed
        )
    }

    private func commitLikeMutation(id: UUID, key: OperationKey) throws {
        guard canMutate(session: key.session), likeOperations[key]?.id == id else {
            finishLikeOperation(id: id, for: key)
            throw CancellationError()
        }
        finishLikeOperation(id: id, for: key)
    }

    private func finishUserOperation(id: UUID, for key: OperationKey) {
        guard let operation = userOperations[key], operation.id == id else { return }
        userOperations[key] = nil
        state.endUserMutation(accountID: operation.accountID, user: operation.user)
    }

    private func finishForumOperation(id: UUID, for key: OperationKey) {
        guard let operation = forumOperations[key], operation.id == id else { return }
        forumOperations[key] = nil
        state.endForumMutation(accountID: operation.accountID, forum: operation.forum)
    }

    private func finishLikeOperation(id: UUID, for key: OperationKey) {
        guard likeOperations[key]?.id == id else { return }
        likeOperations[key] = nil
    }

    private func drainOperations(session: AccountSessionIdentity?) async {
        while true {
            let users = userOperations.filter { key, _ in
                session == nil || key.session == session
            }
            let forums = forumOperations.filter { key, _ in
                session == nil || key.session == session
            }
            let likes = likeOperations.filter { key, _ in
                session == nil || key.session == session
            }
            guard users.isEmpty == false || forums.isEmpty == false || likes.isEmpty == false else {
                return
            }

            users.values.forEach { $0.task.cancel() }
            forums.values.forEach { $0.task.cancel() }
            likes.values.forEach { $0.task.cancel() }
            for operation in users.values {
                _ = await operation.task.result
            }
            for operation in forums.values {
                _ = await operation.task.result
            }
            for operation in likes.values {
                _ = await operation.task.result
            }
            for (key, operation) in users {
                finishUserOperation(id: operation.id, for: key)
            }
            for (key, operation) in forums {
                finishForumOperation(id: operation.id, for: key)
            }
            for (key, operation) in likes {
                finishLikeOperation(id: operation.id, for: key)
            }
        }
    }
}
