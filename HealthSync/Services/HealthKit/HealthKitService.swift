import Foundation
import HealthKit

/// HealthKit 服务（授权 + 全量/增量查询 + 分批翻页）。
/// 以 actor 隔离保证健康数据只被顺序消费；HKHealthStore 非 Sendable，故仅在内部访问。
public actor HealthKitService {
    private let store: HKHealthStore
    private let config: SyncConfig

    public init(store: HKHealthStore = HKHealthStore(), config: SyncConfig = .default) {
        self.store = store
        self.config = config
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
            let sex = try await store.biologicalSex()
            return sex.biologicalSex
        } catch {
            return .notSet
        }
    }

    // MARK: - 授权辅助

    /// 为指定类型请求只读授权。
    /// 只把「可授权读取」的标准类型交给 `requestAuthorization`；特殊类型（如
    /// `HKWorkoutType` / `HKElectrocardiogramType`）在 iOS 27 上混入 read 集合会抛错，
    /// 导致整个授权请求失败，故过滤掉。已授权的类型请求后返回 true 不抛错。
    @MainActor
    public func requestReadAuthorization(for types: Set<HealthDataType>) async throws {
        let authorizable = types.filter(\.isRequestableReadType)
        let readTypes = Set(authorizable.compactMap { $0.objectType })
        // 全部被过滤时无需（也无法）发起授权请求。
        guard !readTypes.isEmpty else { return }
        try await requestAuthorization(toShare: [], read: readTypes)

        // workout 读授权单独请求：HKWorkoutType 混入批量 read 集合在 iOS 27 会抛错，
        // 单独一次请求既不拖垮批量授权，又能拿到训练记录读权限。
        if types.contains(.workouts) {
            try? await requestAuthorization(toShare: [], read: [HKObjectType.workoutType()])
        }
    }

    /// 批量查询指定类型的授权状态。
    /// 只对「可授权读取」的标准类型（`isRequestableReadType == true`）查询授权状态，
    /// 跳过特殊类型（如 `workouts` 的 `HKWorkoutType`、`electrocardiogram` 的
    /// `HKElectrocardiogramType`），它们不是普通 `HKObjectType`，对它们调用
    /// `authorizationStatus(for:)` 会 crash / 异常，从而拖垮整批授权判断。
    public func authStatus(for types: [HealthDataType]) -> [HealthDataType: HealthAuthStatus] {
        var result: [HealthDataType: HealthAuthStatus] = [:]
        for type in types where type.isRequestableReadType {
            guard let objType = type.objectType else { continue }
            let status = store.authorizationStatus(for: objType)
            switch status {
            case .notDetermined: result[type] = .notDetermined
            case .sharingAuthorized: result[type] = .authorized
            case .sharingDenied: result[type] = .denied
            @unknown default: result[type] = .restricted
            }
        }
        return result
    }

    // MARK: - 查询

    /// 全量/增量查询：按启用类型返回样本映射后的 DTO 数组。
    /// - Parameters:
    ///   - types: 启用的数据类型。
    ///   - startDate: 查询起点（增量用游标，全量用回溯起点）。
    ///   - endDate: 查询终点（通常为 now）。
    ///   - progress: 类型维度的进度回调（0...1）。
    public func fetchAll(types: Set<HealthDataType>,
                         startDate: Date,
                         endDate: Date,
                         progress: ((Double) -> Void)? = nil) async throws -> [HealthSampleDTO] {
        let sortedTypes = types.sorted { $0.rawValue < $1.rawValue }
        var allDTOs: [HealthSampleDTO] = []
        var completed = 0
        let predicate = HKQuery.predicateForSamples(withStart: startDate,
                                                    end: endDate,
                                                    options: [.strictStartDate, .strictEndDate])

        for type in sortedTypes {
            guard let objType = type.objectType else { continue }
            guard let hkSampleType = objType as? HKSampleType else { continue }

            do {
                let samples = try await queryAll(sampleType: hkSampleType, predicate: predicate)
                for sample in samples {
                    allDTOs.append(HealthSampleMapper.map(sample))
                }
            } catch let err as NSError {
                // iOS 隐私设计：对「未授权读取」的类型，HealthKit 查询会抛
                // errorAuthorizationNotDetermined / errorAuthorizationDenied（NSError）。
                // 这类类型跳过（不终止整批），只上传已授权的数据。
                if err.domain == HKErrorDomain
                    && (err.code == HKError.errorAuthorizationNotDetermined.rawValue
                        || err.code == HKError.errorAuthorizationDenied.rawValue) {
                    continue
                }
                throw err
            }

            completed += 1
            if let progress {
                progress(Double(completed) / Double(sortedTypes.count))
            }
        }

        return allDTOs
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
        let candidates = types.filter(\.isRequestableReadType)
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

    private func predicate(start: Date, end: Date) -> NSPredicate {
        HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
    }

    /// 分批翻页查询全部样本（limit 分批，时间边界推进避免内存峰值）。
    private func queryAll(sampleType: HKSampleType,
                          predicate: NSPredicate) async throws -> [HKSample] {
        var all: [HKSample] = []
        var cursorStart: Date? = nil
        var lastUUID: UUID? = nil

        while true {
            let start = cursorStart
            let result = try await queryPage(sampleType: sampleType,
                                             predicate: predicate,
                                             start: start,
                                             lastUUID: lastUUID)

            if result.isEmpty { break }
            all.append(contentsOf: result)

            guard result.count == config.batchSize else { break }
            let lastSample = result.last!
            cursorStart = lastSample.startDate
            lastUUID = lastSample.uuid
        }
        return all
    }

    /// 查询单页样本（同步转 async）。
    private func queryPage(sampleType: HKSampleType,
                           predicate: NSPredicate,
                           start: Date?,
                           lastUUID: UUID?) async throws -> [HKSample] {
        let pagePredicate: NSPredicate
        if let start {
            var predicates = [predicate]
            // 时间边界推进：取 startDate 严格晚于游标时间
            predicates.append(HKQuery.predicateForSamples(withStart: start, end: nil))
            pagePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        } else {
            pagePredicate = predicate
        }

        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(sampleType: sampleType,
                                      predicate: pagePredicate,
                                      limit: config.batchSize,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: samples ?? [])
            }
            store.execute(query)
        }
    }
}
