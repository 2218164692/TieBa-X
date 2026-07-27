import Foundation

enum ForumThreadCategory: String, CaseIterable, Identifiable, Sendable {
    case hot
    case latest
    case featured

    var id: Self { self }

    var title: String {
        switch self {
        case .hot:
            return "热门"
        case .latest:
            return "最新"
        case .featured:
            return "精华"
        }
    }

    var sortType: Int {
        switch self {
        case .hot:
            return 0
        case .latest:
            return 1
        case .featured:
            return -1
        }
    }

    var goodClassifyID: Int? {
        self == .featured ? 0 : nil
    }

    var accessibilityIdentifier: String {
        "forum-category-\(rawValue)"
    }

    var accessibilityHint: String {
        switch self {
        case .hot:
            return "按最近回复时间排序"
        case .latest:
            return "按发帖时间排序"
        case .featured:
            return "仅显示精华帖"
        }
    }

    func metadata(for thread: ThreadSummary) -> ForumThreadMetadataPresentation {
        switch self {
        case .hot:
            return ForumThreadMetadataPresentation(
                date: thread.lastReplyAt ?? thread.createdAt,
                actionSuffix: "回复",
                systemImage: "bubble.left.and.text.bubble.right"
            )
        case .latest:
            return ForumThreadMetadataPresentation(
                date: thread.createdAt ?? thread.lastReplyAt,
                actionSuffix: "发布",
                systemImage: "clock"
            )
        case .featured:
            return ForumThreadMetadataPresentation(
                date: thread.lastReplyAt ?? thread.createdAt,
                actionSuffix: "回复",
                systemImage: "bubble.left.and.text.bubble.right"
            )
        }
    }
}

struct ForumThreadMetadataPresentation: Equatable, Sendable {
    let date: Date?
    let actionSuffix: String
    let systemImage: String
}
