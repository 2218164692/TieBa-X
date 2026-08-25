import Foundation
import OSLog

enum PersistenceAvailability: Equatable, Sendable {
    case available
    case unavailable

    var canPersist: Bool {
        self == .available
    }
}

enum PersistenceFaultPoint: Equatable {
    case legacyMigration
    case repair
    case clearAll
}

struct PersistenceFaultInjector {
    static let none = PersistenceFaultInjector { _ in }

    private let handler: (PersistenceFaultPoint) throws -> Void

    init(_ handler: @escaping (PersistenceFaultPoint) throws -> Void) {
        self.handler = handler
    }

    func check(_ point: PersistenceFaultPoint) throws {
        try handler(point)
    }
}

struct PersistenceLoadResult<Value> {
    let value: Value
    let repairError: Error?
}

enum PersistenceDiagnostics {
    private static let logger = Logger(
        subsystem: "com.tiebax",
        category: "Persistence"
    )

    static func report(_ error: Error, operation: String) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
}

enum LegacyStorageMigration {
    enum DecodeError: Error {
        case invalidTopLevelArray
    }

    static func persistThenRemoveLegacyValue(
        defaults: UserDefaults,
        key: String,
        destinationIsDurable: Bool,
        persist: () throws -> Void
    ) throws {
        try persist()
        guard destinationIsDurable else { return }
        defaults.removeObject(forKey: key)
    }
}

struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

enum PersistedArrayDecoder {
    static func decode<Element: Decodable>(_ type: Element.Type, from data: Data) -> [Element]? {
        guard let boxes = try? JSONDecoder().decode(
            [FailableDecodable<Element>].self,
            from: data
        ) else {
            return nil
        }
        return boxes.compactMap(\.value)
    }
}
