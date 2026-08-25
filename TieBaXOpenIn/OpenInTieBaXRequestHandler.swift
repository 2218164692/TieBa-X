import Foundation
import UniformTypeIdentifiers

final class OpenInTieBaXRequestHandler: NSObject, NSExtensionRequestHandling {
    private var extensionContext: NSExtensionContext?

    func beginRequest(with context: NSExtensionContext) {
        extensionContext = context

        guard let provider = context.inputItems
            .compactMap({ $0 as? NSExtensionItem })
            .flatMap({ $0.attachments ?? [] })
            .first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier)
            }) else {
            finish(errorMessage: "没有找到可打开的贴吧网页链接。")
            return
        }

        provider.loadItem(
            forTypeIdentifier: UTType.propertyList.identifier,
            options: nil
        ) { [weak self] item, _ in
            let result = SafariActionPayload.result(from: item)
            OperationQueue.main.addOperation {
                guard let self else { return }
                self.finish(result: result)
            }
        }
    }

    private func finish(errorMessage: String) {
        finish(result: [SafariActionPayload.errorMessageKey: errorMessage])
    }

    private func finish(result: [String: String]) {
        let finalizeArguments: [String: Any] = [
            NSExtensionJavaScriptFinalizeArgumentKey: result
        ]
        let provider = NSItemProvider(
            item: finalizeArguments as NSDictionary,
            typeIdentifier: UTType.propertyList.identifier
        )
        let output = NSExtensionItem()
        output.attachments = [provider]
        extensionContext?.completeRequest(returningItems: [output], completionHandler: nil)
        extensionContext = nil
    }
}
