import Foundation

enum ForumMapper {
    static func fromFollowedForum(_ dto: FollowedForumsDTO.ForumDTO) -> Forum {
        Forum(
            id: dto.id,
            name: dto.name,
            displayName: ForumNamePolicy.displayName(for: dto.name),
            avatarURL: TiebaURL.avatar(dto.avatar),
            memberCount: 0,
            threadCount: 0
        )
    }

    static func fromProto(_ proto: Tieba_SimpleForum) -> Forum {
        Forum(
            id: proto.id,
            name: proto.name,
            displayName: ForumNamePolicy.displayName(for: proto.name),
            avatarURL: TiebaURL.avatar(proto.avatar),
            memberCount: Int(proto.memberNum),
            threadCount: Int(proto.postNum)
        )
    }

    static func fromFrsPage(_ proto: Tieba_FrsPage_ForumInfo) -> Forum {
        Forum(
            id: proto.id,
            name: proto.name,
            displayName: ForumNamePolicy.displayName(for: proto.name),
            avatarURL: TiebaURL.avatar(proto.avatar),
            memberCount: Int(proto.memberNum),
            threadCount: Int(proto.threadNum)
        )
    }
}
