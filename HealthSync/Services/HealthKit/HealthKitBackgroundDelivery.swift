import Foundation
import HealthKit

/// 维护 HealthKit 后台投递订阅。一次更新会合并处理多个样本类型，
/// 并通过 completionHandler 告知系统本轮后台工作已经结束。
@MainActor
final class HealthKitBackgroundDelivery {
    typealias UpdateHandler = @Sendable (Set<HealthDataType>?) async -> Void

    private let store: HKHealthStore
    private var observer: HKObserverQuery?
    private var observedTypeByIdentifier: [String: [HealthDataType]] = [:]
    private var observedIdentifiers: Set<String> = []
    private var observedHealthTypes: Set<HealthDataType> = []

    init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    func start(types: Set<HealthDataType>, onUpdate: @escaping UpdateHandler) async throws {
        let sampleTypes = Set(
            types.compactMap { $0.objectType as? HKSampleType }
        )
        let targetIdentifiers = Set(sampleTypes.map(\.identifier))
        guard BackgroundDeliveryPolicy.needsReconfiguration(
            targetIdentifiers: targetIdentifiers,
            observedIdentifiers: observedIdentifiers,
            targetTypes: types,
            observedTypes: observedHealthTypes
        ) else {
            return
        }

        await stop()

        var enabledTypes: [HKSampleType] = []
        var failures: [String] = []
        for type in sampleTypes.sorted(by: { $0.identifier < $1.identifier }) {
            do {
                try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
                enabledTypes.append(type)
            } catch {
                failures.append("\(type.identifier): \(error.localizedDescription)")
            }
        }
        guard !enabledTypes.isEmpty else {
            throw HealthKitBackgroundDeliveryError.noEnabledTypes(failures)
        }

        var typeByIdentifier: [String: [HealthDataType]] = [:]
        for (identifier, matchingTypes) in Dictionary(
            grouping: types,
            by: { $0.objectType?.identifier ?? "" }
        ) where !identifier.isEmpty {
            typeByIdentifier[identifier] = matchingTypes
        }

        let descriptors = enabledTypes.map {
            HKQueryDescriptor(sampleType: $0, predicate: nil)
        }
        let observedTypesForUpdate = typeByIdentifier
        let query = HKObserverQuery(queryDescriptors: descriptors) {
            _, sampleTypesAdded, completion, error in
            guard error == nil else {
                completion()
                return
            }

            let changedTypes = sampleTypesAdded.map { addedTypes in
                Set(addedTypes.flatMap { type in
                    observedTypesForUpdate[type.identifier] ?? []
                })
            }
            let completionBox = BackgroundObserverCompletion(completion)
            Task {
                let requestedTypes = changedTypes.flatMap { $0.isEmpty ? nil : $0 }
                await onUpdate(requestedTypes)
                completionBox.call()
            }
        }

        observedTypeByIdentifier = typeByIdentifier
        observedIdentifiers = Set(enabledTypes.map(\.identifier))
        observedHealthTypes = types
        observer = query
        store.execute(query)

        if !failures.isEmpty {
            Logger.error("部分健康数据无法启用后台投递：\(failures.joined(separator: "；"))")
        }
    }

    func stop() async {
        if let observer {
            store.stop(observer)
            self.observer = nil
        }
        observedTypeByIdentifier = [:]
        observedIdentifiers = []
        observedHealthTypes = []
        try? await store.disableAllBackgroundDelivery()
    }
}

enum BackgroundDeliveryPolicy {
    static func needsReconfiguration(
        targetIdentifiers: Set<String>,
        observedIdentifiers: Set<String>,
        targetTypes: Set<HealthDataType>,
        observedTypes: Set<HealthDataType>
    ) -> Bool {
        targetIdentifiers != observedIdentifiers || targetTypes != observedTypes
    }
}

private final class BackgroundObserverCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    func call() {
        lock.lock()
        let completion = completion
        self.completion = nil
        lock.unlock()
        completion?()
    }
}

private enum HealthKitBackgroundDeliveryError: LocalizedError {
    case noEnabledTypes([String])

    var errorDescription: String? {
        switch self {
        case .noEnabledTypes(let failures):
            return "无法启用 HealthKit 后台投递：\(failures.joined(separator: "；"))"
        }
    }
}
