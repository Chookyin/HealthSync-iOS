import Foundation
import HealthKit

/// HealthKit 服务（授权 + 全量/增量查询 + 分批翻页）。
/// 以 actor 隔离保证健康数据只被顺序消费；HKHealthStore 非 Sendable，故仅在内部访问。
public actor HealthKitService {
    private let store: HKHealthStore

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    // MARK: - 授权（必须在主线程，否则 HealthKit 授权回调不返回）

    @MainActor
    public func requestAuthorization(toShare sharing: Set<HKSampleType>,
                                     read reading: Set<HKObjectType>) async throws {
        try await store.requestAuthorization(toShare: sharing, read: reading)
    }

    public func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type)
    }

    public func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// 读取用户的生物学性别（特征类型，仅读本地，不触发授权弹窗）。
    public func readBiologicalSex() async -> HKBiologicalSex {
        do {
            let sex = try store.biologicalSex()
            return sex.biologicalSex
        } catch {
            return .notSet
        }
    }

    // MARK: - 授权辅助

    /// 为指定类型请求只读授权，包括 workout 和 ECG 等特殊 HKSampleType。
    @MainActor
    public func requestReadAuthorization(for types: Set<HealthDataType>) async throws {
        let readTypes = Set(types.compactMap { $0.objectType })
        guard !readTypes.isEmpty else {
            throw HealthAuthorizationError.noReadableTypes
        }
        try await requestAuthorization(toShare: [], read: readTypes)
    }

    // MARK: - 查询

    /// 逐页查询并立即交给调用方上传，避免把全部历史样本放入内存。
    /// 同一 `HKObjectType` 只查询一次，睡眠阶段会在客户端按用户选择过滤。
    public func fetchPages(types: Set<HealthDataType>,
                           startDate: Date,
                           endDate: Date,
                           pageSize: Int,
                           progress: (@Sendable (HealthDataType, Double) -> Void)? = nil,
                           handler: @escaping @MainActor @Sendable ([HealthSampleDTO]) async throws -> Void) async throws -> Int {
        let groups = Self.queryGroups(for: types)
        guard !groups.isEmpty else { return 0 }

        let limit = max(1, pageSize)
        let completedTypes = groups.count
        var completed = 0
        var totalSamples = 0
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                    end: endDate,
                                                    options: [.strictStartDate, .strictEndDate])

        for group in groups {
            try Task.checkCancellation()
            progress?(group.displayType, Double(completed) / Double(completedTypes))
            var anchor: HKQueryAnchor?
            do {
                while true {
                    try Task.checkCancellation()
                    let page = try await queryPage(
                        sampleType: group.sampleType,
                        predicate: predicate,
                        anchor: anchor,
                        limit: limit
                    )
                    if page.totalCount == 0 { break }

                    let filtered = Self.filteredSamples(
                        page.samples,
                        requestedTypes: group.requestedTypes
                    )
                    if !filtered.isEmpty {
                        let dtos = try await mapSamples(filtered)
                        totalSamples += dtos.count
                        try await handler(dtos)
                    }

                    guard page.totalCount == limit else { break }
                    guard let nextAnchor = page.anchor else {
                        throw HealthQueryPagingError.missingAnchor
                    }
                    anchor = nextAnchor
                }
            } catch let err as NSError {
                // iOS 隐私设计：对「未授权读取」的类型，HealthKit 查询会抛
                // errorAuthorizationNotDetermined / errorAuthorizationDenied（NSError）。
                // 这类类型跳过（不终止整批），只上传已授权的数据。
                if err.domain == HKErrorDomain
                    && (err.code == HKError.errorAuthorizationNotDetermined.rawValue
                        || err.code == HKError.errorAuthorizationDenied.rawValue) {
                    completed += 1
                    progress?(group.displayType, Double(completed) / Double(completedTypes))
                    continue
                }
                throw err
            }

            completed += 1
            progress?(group.displayType, Double(completed) / Double(completedTypes))
        }

        return totalSamples
    }

    // MARK: - 数据完整性标注

    /// 查询指定类型在 HealthKit 中是否至少存在一条样本，返回最近一条样本的开始时间及其可读值。
    /// 用 `HKSampleQuery` 按 startDate 倒序取 1 条，取其 startDate 作为「最近一次数据时间」，
    /// 并把样本值格式化为带单位的中文可读字符串（如 "72 bpm"、"12,345 步"、"7.5 小时"）。
    public func hasSamples(for type: HealthDataType) async -> (hasData: Bool, latestDate: Date?, latestValue: String?) {
        guard let objType = type.objectType else { return (false, nil, nil) }
        guard let sampleType = objType as? HKSampleType else { return (false, nil, nil) }

        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Date?, String?), Never>) in
            let query = HKSampleQuery(sampleType: sampleType,
                                      predicate: nil,
                                      limit: 1,
                                      sortDescriptors: sort) { _, samples, _ in
                if let latest = samples?.first {
                    continuation.resume(returning: (true, latest.startDate, Self.displayValue(for: type, sample: latest)))
                } else {
                    continuation.resume(returning: (false, nil, nil))
                }
            }
            store.execute(query)
        }
    }

    /// 批量检测哪些类型存在样本数据（仅对可只读授权的标准类型查询）。
    /// 并行发起查询，避免逐个串行过慢；返回「存在数据」的类型集合与各类型最近一次信息。
    public func typesWithSamples(for types: [HealthDataType],
                                 concurrency: Int = 4) async -> [HealthDataType: (hasData: Bool, latestDate: Date?, latestValue: String?)] {
        let candidates = types
        var result: [HealthDataType: (hasData: Bool, latestDate: Date?, latestValue: String?)] = [:]
        let limit = max(1, concurrency)

        await withTaskGroup(of: (HealthDataType, (Bool, Date?, String?))?.self) { group in
            var iterator = candidates.makeIterator()
            var inFlight = 0

            func addNext() {
                while inFlight < limit, let next = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        let info = await self.hasSamples(for: next)
                        return (next, info)
                    }
                }
            }

            addNext()
            for await item in group {
                inFlight -= 1
                if let item {
                    result[item.0] = item.1
                }
                addNext()
            }
        }
        return result
    }

    /// 把最近一条样本格式化为带单位的可读字符串（设置页展示用）。
    private static func displayValue(for type: HealthDataType, sample: HKSample) -> String {
        switch sample {
        case let quantity as HKQuantitySample:
            return formattedQuantity(quantity, for: type)
        case let category as HKCategorySample:
            return formattedCategory(category, for: type)
        case let workout as HKWorkout:
            // 锻炼显示时长（分钟）。
            return "\(Int((workout.duration / 60).rounded())) 分钟"
        default:
            return ""
        }
    }

    /// 数量型样本：按类型选择单位并格式化为中文可读字符串。
    /// 安全守卫：`doubleValue(for:)` 在单位维度不兼容时会抛 NSException 闪退，
    /// 因此每个分支先 `is(compatibleWith:)` 校验，不兼容则退化为样本自带单位显示。
    private static func formattedQuantity(_ quantity: HKQuantitySample, for type: HealthDataType) -> String {
        let q = quantity.quantity
        let qType = quantity.quantityType

        func value(_ unit: HKUnit) -> Double? {
            q.is(compatibleWith: unit) ? q.doubleValue(for: unit) : nil
        }
        // 兜底：样本自带单位（无法直接取 unit，改用 HKQuantity 的 description）
        func raw() -> String {
            q.description
        }

        switch type {
        case .stepCount:
            return value(.count()).map { number($0) + " 步" } ?? raw()
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateRecoveryOneMinute:
            return value(.count().unitDivided(by: .minute())).map { number($0) + " bpm" } ?? raw()
        case .bodyMass, .leanBodyMass:
            return value(.gramUnit(with: .kilo)).map { String(format: "%.1f kg", $0) } ?? raw()
        case .bodyMassIndex:
            return value(.count()).map { String(format: "%.1f", $0) } ?? raw()
        case .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .height, .waistCircumference:
            return value(.meter()).map { String(format: "%.2f m", $0) } ?? raw()
        case .activeEnergyBurned, .basalEnergyBurned, .dietaryEnergyConsumed:
            return value(.kilocalorie()).map { String(format: "%.0f kcal", $0) } ?? raw()
        case .appleExerciseTime, .appleStandTime:
            return value(.minute()).map { String(format: "%.0f 分钟", $0) } ?? raw()
        case .flightsClimbed, .swimmingStrokeCount:
            return value(.count()).map { number($0) + " 次" } ?? raw()
        case .walkingSpeed, .runningSpeed:
            return value(.meter().unitDivided(by: .second())).map { String(format: "%.2f m/s", $0) } ?? raw()
        case .runningPower:
            return value(.watt()).map { String(format: "%.0f W", $0) } ?? raw()
        case .heartRateVariabilitySDNN:
            return value(.secondUnit(with: .milli)).map { String(format: "%.0f ms", $0) } ?? raw()
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return value(.millimeterOfMercury()).map { String(format: "%.0f mmHg", $0) } ?? raw()
        case .oxygenSaturation, .bodyFatPercentage:
            return value(.percent()).map { String(format: "%.0f%%", $0 * 100) } ?? raw()
        case .bodyTemperature, .appleSleepingWristTemperature:
            return value(.degreeCelsius()).map { String(format: "%.1f °C", $0) } ?? raw()
        case .vo2Max:
            let unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
            return value(unit).map { String(format: "%.1f", $0) } ?? raw()
        case .respiratoryRate:
            return value(.count().unitDivided(by: .minute())).map { String(format: "%.0f 次/分", $0) } ?? raw()
        case .forcedExpiratoryVolume1, .forcedVitalCapacity:
            return value(HKUnit.liter()).map { String(format: "%.2f L", $0) } ?? raw()
        case .peakExpiratoryFlowRate:
            return value(HKUnit.liter().unitDivided(by: .minute())).map { String(format: "%.0f L/min", $0) } ?? raw()
        case .dietaryWater:
            return value(.literUnit(with: .milli)).map { String(format: "%.0f mL", $0) } ?? raw()
        case .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates, .dietaryFiber,
             .dietarySodium, .dietaryPotassium, .dietaryCaffeine:
            return value(.gram()).map { String(format: "%.0f g", $0) } ?? raw()
        case .bloodGlucose:
            return value(HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)).map { String(format: "%.1f mmol/L", $0) } ?? raw()
        case .insulinDelivery:
            return value(.internationalUnit()).map { String(format: "%.0f U", $0) } ?? raw()
        case .sixMinuteWalkTestDistance:
            return value(.meter()).map { String(format: "%.0f m", $0) } ?? raw()
        case .appleWalkingSteadiness:
            return value(.percent()).map { String(format: "%.1f%%", $0 * 100) } ?? raw()
        case .distanceDownhillSnowSports:
            return value(.meter()).map { String(format: "%.2f m", $0) } ?? raw()
        case .physicalEffort, .estimatedWorkoutEffortScore, .workoutEffortScore,
             .atrialFibrillationBurden:
            // 量表型数值（0-10 分制）或未知维度：优先 count，不兼容则用样本自带单位。
            return value(.count()).map { String(format: "%.1f", $0) } ?? raw()
        default:
            // 兜底：优先使用该类型的 preferredUnit，不兼容则用样本自带单位。
            let unit = preferredUnit(for: qType)
            if q.is(compatibleWith: unit) {
                return String(format: "%.2f %@", q.doubleValue(for: unit), unit.unitString)
            }
            return raw()
        }
    }

    /// 分类型样本：睡眠按小时展示，其余展示阶段/值。
    private static func formattedCategory(_ category: HKCategorySample, for type: HealthDataType) -> String {
        if category.categoryType == HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            // 睡眠时长（秒转小时）。
            let seconds = category.endDate.timeIntervalSince(category.startDate)
            return String(format: "%.1f 小时", seconds / 3600)
        }
        // 音频暴露/症状/高心率等分类样本展示原值。
        return "\(category.value)"
    }

    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    private static func preferredUnit(for quantityType: HKQuantityType) -> HKUnit {
        switch quantityType.identifier {
        case HKQuantityTypeIdentifier.stepCount.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
             HKQuantityTypeIdentifier.distanceCycling.rawValue,
             HKQuantityTypeIdentifier.distanceSwimming.rawValue,
             HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
             HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
            return .kilocalorie()
        case HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
             HKQuantityTypeIdentifier.appleStandTime.rawValue:
            return .minute()
        case HKQuantityTypeIdentifier.flightsClimbed.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.walkingSpeed.rawValue,
             HKQuantityTypeIdentifier.runningSpeed.rawValue:
            return .meter().unitDivided(by: .second())
        case HKQuantityTypeIdentifier.runningPower.rawValue:
            return .watt()
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue,
             HKQuantityTypeIdentifier.walkingHeartRateAverage.rawValue,
             HKQuantityTypeIdentifier.heartRateRecoveryOneMinute.rawValue:
            return .count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue,
             HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue:
            return .millimeterOfMercury()
        case HKQuantityTypeIdentifier.oxygenSaturation.rawValue,
             HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
            return .percent()
        case HKQuantityTypeIdentifier.bodyTemperature.rawValue,
             HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue:
            return .degreeCelsius()
        case HKQuantityTypeIdentifier.vo2Max.rawValue:
            return HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case HKQuantityTypeIdentifier.bodyMass.rawValue,
             HKQuantityTypeIdentifier.leanBodyMass.rawValue:
            return .gramUnit(with: .kilo)
        case HKQuantityTypeIdentifier.height.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
            return .count()
        case HKQuantityTypeIdentifier.waistCircumference.rawValue:
            return .meter()
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return .count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.forcedExpiratoryVolume1.rawValue,
             HKQuantityTypeIdentifier.forcedVitalCapacity.rawValue:
            return HKUnit.liter()
        case HKQuantityTypeIdentifier.peakExpiratoryFlowRate.rawValue:
            return HKUnit.liter().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.dietaryProtein.rawValue,
             HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
             HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
             HKQuantityTypeIdentifier.dietaryFiber.rawValue,
             HKQuantityTypeIdentifier.dietarySodium.rawValue,
             HKQuantityTypeIdentifier.dietaryPotassium.rawValue,
             HKQuantityTypeIdentifier.dietaryCaffeine.rawValue:
            return .gram()
        case HKQuantityTypeIdentifier.dietaryWater.rawValue:
            return .literUnit(with: .milli)
        case HKQuantityTypeIdentifier.bloodGlucose.rawValue:
            return HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose)
        case HKQuantityTypeIdentifier.insulinDelivery.rawValue:
            return .internationalUnit()
        default:
            return .count()
        }
    }

    // MARK: - 私有

    private struct AnchorPage {
        var samples: [HKSample]
        var totalCount: Int
        var anchor: HKQueryAnchor?
    }

    private struct QueryGroup {
        var displayType: HealthDataType
        var requestedTypes: Set<HealthDataType>
        var sampleType: HKSampleType
    }

    private static func queryGroups(for types: Set<HealthDataType>) -> [QueryGroup] {
        var grouped: [String: (displayType: HealthDataType,
                                requestedTypes: Set<HealthDataType>,
                                sampleType: HKSampleType)] = [:]
        for type in types.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let objectType = type.objectType,
                  let sampleType = objectType as? HKSampleType else {
                continue
            }
            let identifier = objectType.identifier
            if var existing = grouped[identifier] {
                existing.requestedTypes.insert(type)
                if type == .sleepAnalysis {
                    existing.displayType = .sleepAnalysis
                }
                grouped[identifier] = existing
            } else {
                grouped[identifier] = (type, [type], sampleType)
            }
        }
        return grouped.values
            .map {
                QueryGroup(displayType: $0.displayType,
                           requestedTypes: $0.requestedTypes,
                           sampleType: $0.sampleType)
            }
            .sorted { $0.displayType.rawValue < $1.displayType.rawValue }
    }

    private static func filteredSamples(_ samples: [HKSample],
                                        requestedTypes: Set<HealthDataType>) -> [HKSample] {
        if requestedTypes.contains(.sleepAnalysis) {
            return samples
        }
        let allowedStages = Set(requestedTypes.compactMap(\.sleepStageValue))
        guard !allowedStages.isEmpty else { return samples }
        return samples.filter { sample in
            guard let category = sample as? HKCategorySample,
                  category.categoryType.identifier
                    == HKObjectType.categoryType(forIdentifier: .sleepAnalysis)?.identifier else {
                return true
            }
            return allowedStages.contains(category.value)
        }
    }

    private func mapSamples(_ samples: [HKSample]) async throws -> [HealthSampleDTO] {
        var result: [HealthSampleDTO] = []
        result.reserveCapacity(samples.count)
        for sample in samples {
            if let electrocardiogram = sample as? HKElectrocardiogram {
                let voltages = try await voltageMeasurements(for: electrocardiogram)
                result.append(HealthSampleMapper.map(
                    electrocardiogram,
                    ecgVoltageMeasurements: voltages
                ))
            } else {
                result.append(HealthSampleMapper.map(sample))
            }
        }
        return result
    }

    private func voltageMeasurements(
        for electrocardiogram: HKElectrocardiogram
    ) async throws -> [HealthSampleDTO.ECGVoltage] {
        var result: [HealthSampleDTO.ECGVoltage] = []
        result.reserveCapacity(electrocardiogram.numberOfVoltageMeasurements)
        let descriptor = HKElectrocardiogramQueryDescriptor(electrocardiogram)
        for try await measurement in descriptor.results(for: store) {
            try Task.checkCancellation()
            let unit = HKUnit.voltUnit(with: .micro)
            guard let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI),
                  quantity.is(compatibleWith: unit) else {
                continue
            }
            result.append(HealthSampleDTO.ECGVoltage(
                timeSinceSampleStart: measurement.timeSinceSampleStart,
                voltageMicrovolts: quantity.doubleValue(for: unit),
                lead: "appleWatchSimilarToLeadI"
            ))
        }
        return result
    }

    /// 查询单页样本。page anchor 只在当前同步任务内使用。
    private func queryPage(sampleType: HKSampleType,
                           predicate: NSPredicate,
                           anchor: HKQueryAnchor?,
                           limit: Int) async throws -> AnchorPage {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: sampleType,
                                              predicate: predicate,
                                              anchor: anchor,
                                              limit: limit) { _, samples, deletedObjects, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let added = samples ?? []
                let deletedCount = deletedObjects?.count ?? 0
                continuation.resume(returning: AnchorPage(samples: added,
                                                         totalCount: added.count + deletedCount,
                                                         anchor: newAnchor))
            }
            store.execute(query)
        }
    }
}

private enum HealthQueryPagingError: LocalizedError {
    case missingAnchor

    var errorDescription: String? {
        "HealthKit 分页失败：查询未返回下一页游标"
    }
}

private enum HealthAuthorizationError: LocalizedError {
    case noReadableTypes

    var errorDescription: String? {
        "当前 iOS 版本没有可请求的健康数据类型"
    }
}
