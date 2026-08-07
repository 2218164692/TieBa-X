import Foundation

/// Runs the daily check-in across the account's followed forums.
///
/// The requests are issued one at a time on purpose: a burst of writes from a
/// third-party client is exactly what the service rate-limits, and a check-in
/// that silently drops half the forums is worse than one that takes a few
/// seconds longer.
@MainActor
final class ForumSignCoordinator: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastSummary: ForumSignRunSummary?
    @Published private(set) var lastError: String?

    private let api: any TiebaAPIService
    private let settings: ForumSignSettingsStore
    private let requestSpacing: Duration
    private var runTask: Task<ForumSignRunSummary, Never>?

    init(
        api: any TiebaAPIService,
        settings: ForumSignSettingsStore,
        requestSpacing: Duration = .milliseconds(350)
    ) {
        self.api = api
        self.settings = settings
        self.requestSpacing = requestSpacing
    }

    /// Signs every followed forum. Concurrent invocations join the run already
    /// in flight instead of doubling the write traffic.
    @discardableResult
    func signAllFollowedForums(account: Account) async -> ForumSignRunSummary {
        if let runTask {
            return await runTask.value
        }
        isRunning = true
        lastError = nil
        let task = Task { @MainActor [api, settings, requestSpacing] in
            var summary = ForumSignRunSummary.empty
            do {
                let forums = try await api.followedForums(account: account)
                try Task.checkCancellation()
                for (index, forum) in forums.enumerated() {
                    if index > 0 {
                        try? await Task.sleep(for: requestSpacing)
                    }
                    do {
                        try Task.checkCancellation()
                        let result = try await api.signForum(account: account, forum: forum)
                        if result.wasAlreadySigned {
                            summary.alreadySignedCount += 1
                        } else {
                            summary.signedCount += 1
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        summary.failedForumNames.append(forum.displayName)
                    }
                }
                // Only a run that reached every forum counts as today's run;
                // otherwise tomorrow's automatic attempt would be skipped after
                // a partial failure.
                if summary.failedForumNames.isEmpty, summary.isEmpty == false {
                    settings.markRunCompleted(accountID: account.id)
                }
            } catch is CancellationError {
                // Leaving the screen cancels the run; nothing to report.
            } catch {
                self.lastError = ReaderErrorMessage.message(for: error)
            }
            return summary
        }
        runTask = task
        let summary = await task.value
        runTask = nil
        isRunning = false
        lastSummary = summary
        return summary
    }

    /// The automatic path: at most one completed run per local day per account.
    func signAutomaticallyIfNeeded(account: Account?) async {
        guard let account,
              settings.automaticSignEnabled,
              settings.hasRunToday(accountID: account.id) == false else { return }
        await signAllFollowedForums(account: account)
    }

    func clearLastSummary() {
        lastSummary = nil
        lastError = nil
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }
}
