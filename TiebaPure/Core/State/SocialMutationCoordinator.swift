import Foundation

enum SocialMutationCoordinatorError: Error, Equatable, CustomStringConvertible {
    case operationInProgress

    var description: String {
        "操作正在处理中，请稍候。"
    }
}

@MainActor
final class SocialMutationCoordinator {
    private struct UserOperation {
        var targetState: Bool
        var task: Task<Void, Error>
    }

    private struct ForumOperation {
        var targetState: Bool
        var task: Task<ForumMembership, Error>
    }

    private struct LikeOperation {
        var targetState: Bool
        var task: Task<Void, Error>
    }

    private let api: any TiebaAPIService
    private let state: SocialRelationshipState
    private var userOperations: [String: UserOperation] = [:]
    private var forumOperations: [String: ForumOperation] = [:]
    private var likeOperations: [String: LikeOperation] = [:]

    init(api: any TiebaAPIService, state: SocialRelationshipState) {
        self.api = api
        self.state = state
    }

    func setUserFollowed(account: Account, user: UserSummary, followed: Bool) async throws {
        let key = "\(account.id)|\(SocialRelationshipState.userOperationKey(user))"
        if let existing = userOperations[key] {
            guard existing.targetState == followed else {
                throw SocialMutationCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        state.beginUserMutation(accountID: account.id, user: user)
        let api = api
        let state = state
        let task = Task {
            do {
                try await api.setUserFollowed(account: account, user: user, followed: followed)
                state.recordUserFollow(accountID: account.id, user: user, isFollowed: followed)
            } catch {
                let originalError = error
                if let profile = try? await api.userProfile(account: account, user: user) {
                    state.recordUserFollow(
                        accountID: account.id,
                        user: profile.user,
                        isFollowed: profile.isFollowed
                    )
                }
                throw originalError
            }
        }
        userOperations[key] = UserOperation(targetState: followed, task: task)
        do {
            try await task.value
            userOperations[key] = nil
            state.endUserMutation(accountID: account.id, user: user)
        } catch {
            userOperations[key] = nil
            state.endUserMutation(accountID: account.id, user: user)
            throw error
        }
    }

    func setForumFollowed(account: Account, forum: Forum, followed: Bool) async throws -> ForumMembership {
        let key = "\(account.id)|\(SocialRelationshipState.forumOperationKey(forum))"
        if let existing = forumOperations[key] {
            guard existing.targetState == followed else {
                throw SocialMutationCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        state.beginForumMutation(accountID: account.id, forum: forum)
        let api = api
        let state = state
        let task = Task {
            do {
                let membership = try await api.setForumFollowed(
                    account: account,
                    forum: forum,
                    followed: followed
                )
                var resolvedForum = forum
                resolvedForum.id = membership.forumID
                state.recordForumFollow(
                    accountID: account.id,
                    forum: resolvedForum,
                    isFollowed: membership.isFollowed
                )
                return membership
            } catch {
                let originalError = error
                if let membership = try? await api.forumMembership(account: account, forum: forum) {
                    var resolvedForum = forum
                    resolvedForum.id = membership.forumID
                    state.recordForumFollow(
                        accountID: account.id,
                        forum: resolvedForum,
                        isFollowed: membership.isFollowed
                    )
                }
                throw originalError
            }
        }
        forumOperations[key] = ForumOperation(targetState: followed, task: task)
        do {
            let membership = try await task.value
            forumOperations[key] = nil
            state.endForumMutation(accountID: account.id, forum: forum)
            return membership
        } catch {
            forumOperations[key] = nil
            state.endForumMutation(accountID: account.id, forum: forum)
            throw error
        }
    }

    func setPostLiked(
        account: Account,
        threadID: Int64,
        postID: UInt64,
        objectType: TiebaLikeObjectType,
        liked: Bool
    ) async throws {
        let key = "\(account.id)|\(threadID)|\(postID)|\(objectType.rawValue)"
        if let existing = likeOperations[key] {
            guard existing.targetState == liked else {
                throw SocialMutationCoordinatorError.operationInProgress
            }
            return try await existing.task.value
        }

        let api = api
        let task = Task {
            try await api.setPostLiked(
                account: account,
                threadID: threadID,
                postID: postID,
                objectType: objectType,
                liked: liked
            )
        }
        likeOperations[key] = LikeOperation(targetState: liked, task: task)
        do {
            try await task.value
            likeOperations[key] = nil
        } catch {
            likeOperations[key] = nil
            throw error
        }
    }
}
