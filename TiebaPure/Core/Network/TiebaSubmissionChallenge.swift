import Foundation

struct TiebaWebSubmissionChallengePayload: Decodable {
    struct Fields: Decodable {
        struct Extra: Decodable {
            let textImage: String?
            let slideImage: String?
            let endpoint: String?
            let successImage: String?
            let slideEndpoint: String?

            private enum CodingKeys: String, CodingKey {
                case textImage = "textimg"
                case slideImage = "slideimg"
                case endpoint
                case successImage = "successimg"
                case slideEndpoint = "slideendpoint"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                textImage = container.challengeString(forKey: .textImage)
                slideImage = container.challengeString(forKey: .slideImage)
                endpoint = container.challengeString(forKey: .endpoint)
                successImage = container.challengeString(forKey: .successImage)
                slideEndpoint = container.challengeString(forKey: .slideEndpoint)
            }
        }

        struct AntiState: Decodable {
            let canPost: String?
            let canPostAgain: String?
            let forbidFlag: String?
            let forbidInformation: String?
            let blockState: String?
            let hideState: String?
            let verificationState: String?
            let daysToFree: Int?
            let hasChance: Bool?

            private enum CodingKeys: String, CodingKey {
                case canPost = "ifpost"
                case canPostAgain = "ifposta"
                case forbidFlag = "forbid_flag"
                case forbidInformation = "forbid_info"
                case blockState = "block_stat"
                case hideState = "hide_stat"
                case verificationState = "vcode_stat"
                case daysToFree = "days_tofree"
                case hasChance = "has_chance"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                canPost = container.challengeString(forKey: .canPost)
                canPostAgain = container.challengeString(forKey: .canPostAgain)
                forbidFlag = container.challengeString(forKey: .forbidFlag)
                forbidInformation = container.challengeString(forKey: .forbidInformation)
                blockState = container.challengeString(forKey: .blockState)
                hideState = container.challengeString(forKey: .hideState)
                verificationState = container.challengeString(forKey: .verificationState)
                daysToFree = container.challengeInt(forKey: .daysToFree)
                hasChance = container.challengeBool(forKey: .hasChance)
            }
        }

        let needVerification: String?
        let verificationMD5: String?
        let previousVerificationType: String?
        let verificationType: String?
        let passToken: String?
        let blockContent: String?
        let blockCancel: String?
        let blockConfirm: String?
        let pictureURL: String?
        let extra: Extra?
        let antiState: AntiState?
        let extensionMessage: String?
        let toastMessage: String?

        private enum CodingKeys: String, CodingKey {
            case needVerification = "need_vcode"
            case verificationMD5 = "vcode_md5"
            case previousVerificationType = "vcode_prev_type"
            case verificationType = "vcode_type"
            case passToken = "pass_token"
            case blockContent = "block_content"
            case blockCancel = "block_cancel"
            case blockConfirm = "block_confirm"
            case pictureURL = "vcode_pic_url"
            case extra = "vcode_extra"
            case antiState = "anti_stat"
            case extensionMessage = "ext_msg"
            case toast
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            needVerification = container.challengeString(forKey: .needVerification)
            verificationMD5 = container.challengeString(forKey: .verificationMD5)
            previousVerificationType = container.challengeString(forKey: .previousVerificationType)
            verificationType = container.challengeString(forKey: .verificationType)
            passToken = container.challengeString(forKey: .passToken)
            blockContent = container.challengeString(forKey: .blockContent)
            blockCancel = container.challengeString(forKey: .blockCancel)
            blockConfirm = container.challengeString(forKey: .blockConfirm)
            pictureURL = container.challengeString(forKey: .pictureURL)
            extra = try? container.decodeIfPresent(Extra.self, forKey: .extra)
            antiState = try? container.decodeIfPresent(AntiState.self, forKey: .antiState)
            extensionMessage = container.challengeString(forKey: .extensionMessage)
            toastMessage = Self.decodeToast(from: container)
        }

        private static func decodeToast(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> String? {
            if let value = container.challengeString(forKey: .toast) {
                return value
            }
            guard let toast = try? container.nestedContainer(
                keyedBy: DynamicCodingKey.self,
                forKey: .toast
            ) else {
                return nil
            }
            for key in ["content", "text", "message", "msg"] {
                guard let codingKey = DynamicCodingKey(stringValue: key) else { continue }
                if let value = toast.challengeString(forKey: codingKey) {
                    return value
                }
            }
            return nil
        }
    }

    let fields: [Fields]

    private enum CodingKeys: String, CodingKey {
        case info
        case anti
    }

    init(from decoder: Decoder) throws {
        let direct = try Fields(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let info = try? container.decodeIfPresent(Fields.self, forKey: .info)
        let anti = try? container.decodeIfPresent(Fields.self, forKey: .anti)
        fields = [direct] + [info, anti].compactMap { $0 }
    }

    static func challenge(
        from payloads: [TiebaWebSubmissionChallengePayload],
        messages: [String]
    ) -> ContentSubmissionChallenge? {
        let fields = payloads.flatMap(\.fields)
        let normalizedMessages = messages.compactMap {
            ContentSubmissionChallenge.sanitizedDisplayText($0)
        }
        let messageRequiresVerification = normalizedMessages.contains {
            $0.requiresSubmissionVerificationChallenge
        }
        let fieldsRequireVerification = fields.contains { field in
            field.needVerification.requiresSubmissionVerificationFlag
                || SubmissionSecret(field.verificationMD5) != nil
                || SubmissionSecret(field.passToken) != nil
                || field.pictureURL.challengeNonempty
                || field.antiState?.verificationState.requiresSubmissionVerificationFlag == true
                || field.blockContent.challengeNonempty
        }
        guard messageRequiresVerification || fieldsRequireVerification else { return nil }

        var hasConflict = false
        let verificationMD5 = uniqueSecret(
            fields.map(\.verificationMD5),
            hasConflict: &hasConflict
        )
        let passToken = uniqueSecret(fields.map(\.passToken), hasConflict: &hasConflict)
        let verificationType = uniqueDisplayText(
            fields.map(\.verificationType),
            hasConflict: &hasConflict
        )
        let previousVerificationType = uniqueDisplayText(
            fields.map(\.previousVerificationType),
            hasConflict: &hasConflict
        )
        let pictureURL = uniqueChallengeURL(
            fields.map(\.pictureURL),
            hasConflict: &hasConflict
        )

        let blockContent = uniqueDisplayText(fields.map(\.blockContent), hasConflict: &hasConflict)
        let blockCancel = uniqueDisplayText(fields.map(\.blockCancel), hasConflict: &hasConflict)
        let blockConfirm = uniqueDisplayText(fields.map(\.blockConfirm), hasConflict: &hasConflict)
        let blockPrompt: ContentSubmissionBlockPrompt? = [
            blockContent,
            blockCancel,
            blockConfirm
        ].contains(where: { $0 != nil })
            ? ContentSubmissionBlockPrompt(
                content: blockContent,
                cancelTitle: blockCancel,
                confirmTitle: blockConfirm
            )
            : nil

        let extras = fields.compactMap(\.extra)
        let extra = makeExtra(extras, hasConflict: &hasConflict)
        let antiState = makeAntiState(fields.compactMap(\.antiState), hasConflict: &hasConflict)
        let extensionMessage = uniqueDisplayText(
            fields.map(\.extensionMessage),
            hasConflict: &hasConflict
        )
        let toastMessage = uniqueDisplayText(fields.map(\.toastMessage), hasConflict: &hasConflict)
        let displayMessage = normalizedMessages.first
            ?? blockContent
            ?? toastMessage
            ?? extensionMessage
            ?? "贴吧要求完成安全验证，当前版本暂时无法继续。"

        return ContentSubmissionChallenge(
            message: displayMessage,
            verificationMD5: verificationMD5,
            verificationType: verificationType,
            previousVerificationType: previousVerificationType,
            pictureURL: pictureURL,
            passToken: passToken,
            blockPrompt: blockPrompt,
            extra: extra,
            antiState: antiState,
            extensionMessage: extensionMessage,
            toastMessage: toastMessage,
            hasConflictingPayload: hasConflict
        )
    }

    private static func makeExtra(
        _ extras: [Fields.Extra],
        hasConflict: inout Bool
    ) -> ContentSubmissionChallengeExtra? {
        let value = ContentSubmissionChallengeExtra(
            textImageURL: uniqueChallengeURL(extras.map(\.textImage), hasConflict: &hasConflict),
            slideImageURL: uniqueChallengeURL(extras.map(\.slideImage), hasConflict: &hasConflict),
            endpointURL: uniqueChallengeURL(extras.map(\.endpoint), hasConflict: &hasConflict),
            successImageURL: uniqueChallengeURL(extras.map(\.successImage), hasConflict: &hasConflict),
            slideEndpointURL: uniqueChallengeURL(extras.map(\.slideEndpoint), hasConflict: &hasConflict)
        )
        return [
            value.textImageURL,
            value.slideImageURL,
            value.endpointURL,
            value.successImageURL,
            value.slideEndpointURL
        ].contains(where: { $0 != nil }) ? value : nil
    }

    private static func makeAntiState(
        _ states: [Fields.AntiState],
        hasConflict: inout Bool
    ) -> ContentSubmissionAntiState? {
        guard states.isEmpty == false else { return nil }
        return ContentSubmissionAntiState(
            canPost: uniqueDisplayText(states.map(\.canPost), hasConflict: &hasConflict),
            canPostAgain: uniqueDisplayText(states.map(\.canPostAgain), hasConflict: &hasConflict),
            forbidFlag: uniqueDisplayText(states.map(\.forbidFlag), hasConflict: &hasConflict),
            forbidInformation: uniqueDisplayText(
                states.map(\.forbidInformation),
                hasConflict: &hasConflict
            ),
            blockState: uniqueDisplayText(states.map(\.blockState), hasConflict: &hasConflict),
            hideState: uniqueDisplayText(states.map(\.hideState), hasConflict: &hasConflict),
            verificationState: uniqueDisplayText(
                states.map(\.verificationState),
                hasConflict: &hasConflict
            ),
            daysToFree: uniqueValue(states.map(\.daysToFree), hasConflict: &hasConflict),
            hasChance: uniqueValue(states.map(\.hasChance), hasConflict: &hasConflict)
        )
    }
}

private func uniqueSecret(
    _ values: [String?],
    hasConflict: inout Bool
) -> SubmissionSecret? {
    let values = Set(values.compactMap(SubmissionSecret.init))
    guard values.count <= 1 else {
        hasConflict = true
        return nil
    }
    return values.first
}

private func uniqueDisplayText(
    _ values: [String?],
    hasConflict: inout Bool
) -> String? {
    let values = Set(values.compactMap {
        ContentSubmissionChallenge.sanitizedDisplayText($0)
    })
    guard values.count <= 1 else {
        hasConflict = true
        return nil
    }
    return values.first
}

private func uniqueChallengeURL(
    _ values: [String?],
    hasConflict: inout Bool
) -> URL? {
    let normalizedValues = Set(values.compactMap { value -> String? in
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    })
    guard normalizedValues.count <= 1 else {
        hasConflict = true
        return nil
    }
    return validatedBaiduChallengeURL(normalizedValues.first)
}

private func uniqueValue<Value: Hashable>(
    _ values: [Value?],
    hasConflict: inout Bool
) -> Value? {
    let values = Set(values.compactMap { $0 })
    guard values.count <= 1 else {
        hasConflict = true
        return nil
    }
    return values.first
}

func validatedBaiduChallengeURL(_ value: String?) -> URL? {
    guard let value,
          let components = URLComponents(string: value),
          components.scheme?.lowercased() == "https",
          components.user == nil,
          components.password == nil,
          let url = TiebaURL.webpage(value),
          let host = url.host?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
        return nil
    }
    return ["baidu.com", "bdimg.com", "bdstatic.com"].contains { suffix in
        host == suffix || host.hasSuffix(".\(suffix)")
    } ? url : nil
}

private extension Optional where Wrapped == String {
    var challengeNonempty: Bool {
        self?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var requiresSubmissionVerificationFlag: Bool {
        guard let raw = self?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.isEmpty == false else {
            return false
        }
        return ["0", "false", "no", "off", "none"].contains(raw) == false
    }
}

private extension String {
    var requiresSubmissionVerificationChallenge: Bool {
        let value = lowercased()
        return value.contains("验证码")
            || value.contains("安全验证")
            || value.contains("captcha")
            || value.contains("verify")
    }
}

private extension KeyedDecodingContainer {
    func challengeString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }
        return nil
    }

    func challengeInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func challengeBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value == 0 ? false : value == 1 ? true : nil
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "0", "false": return false
            case "1", "true": return true
            default: return nil
            }
        }
        return nil
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
