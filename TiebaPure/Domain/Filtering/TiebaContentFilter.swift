import Foundation

enum TiebaContentFilter {
    static func shouldKeep(thread: Tieba_ThreadInfo) -> Bool {
        if thread.hasAlaInfo { return false }
        if thread.hasTwzhiboInfo { return false }
        if thread.isDeleted != 0 { return false }
        return true
    }

    static func shouldKeep(post: Tieba_Post) -> Bool {
        if post.hasAdvertisement { return false }
        if post.isFold != 0 { return false }
        if post.content.contains(where: shouldKeep(content:)) { return true }
        // A floor whose content is entirely voice still owns its floor number
        // and 楼中楼; dropping it would break floor continuity and take
        // reachable text subposts with it. Ad-only floors and floors with no
        // content and no subposts stay dropped — they have nothing to show.
        return post.content.contains { $0.voiceMd5.isEmpty == false }
            || post.subPostNumber > 0
            || post.subPostList.subPostList.isEmpty == false
    }

    static func shouldKeep(content: Tieba_PbContent) -> Bool {
        if content.type == 10 { return false }
        if content.voiceMd5.isEmpty == false { return false }
        return true
    }
}
