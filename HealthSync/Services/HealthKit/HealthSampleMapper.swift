import Foundation
import HealthKit
import CryptoKit

/// 将 HK 样本映射为统一 DTO（纯函数，便于测试）。
public enum HealthSampleMapper {
    /// 睡眠阶段名称映射。
    private static func sleepStageDescription(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        default: return "unknown"
        }
    }

    /// 生成跨启动稳定的 SHA-256 去重指纹。
    public static func fingerprint(id: UUID,
                                   type: String,
                                   start: Date,
                                   end: Date,
                                   source: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let raw = [
            id.uuidString.lowercased(),
            type,
            formatter.string(from: start),
            formatter.string(from: end),
            source.lowercased()
        ].joined(separator: "|")
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 将单个样本映射为 DTO。
    public static func map(_ sample: HKSample,
                           ecgVoltageMeasurements: [HealthSampleDTO.ECGVoltage]? = nil) -> HealthSampleDTO {
        let typeIdentifier: String
        let category: String
        let value: Double?
        let unit: String?
        var valueDescription: String?
        var metadata: [String: String]?

        switch sample {
        case let quantity as HKQuantitySample:
            typeIdentifier = quantity.quantityType.identifier
            let baseUnit = preferredUnit(for: quantity.quantityType)
            // 单位兼容守卫：避免 doubleValue(for:) 抛 NSException 闪退。
            if quantity.quantity.is(compatibleWith: baseUnit) {
                value = quantity.quantity.doubleValue(for: baseUnit)
                unit = baseUnit.unitString
            } else {
                value = nil
                unit = nil
            }
            category = typeCategory(identifier: quantity.quantityType.identifier)

        case let categorySample as HKCategorySample:
            typeIdentifier = categorySample.categoryType.identifier
            value = Double(categorySample.value)
            unit = nil
            category = typeCategory(identifier: categorySample.categoryType.identifier)
            if categorySample.categoryType == HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                valueDescription = sleepStageDescription(categorySample.value)
            } else {
                valueDescription = String(categorySample.value)
            }

        case let electrocardiogram as HKElectrocardiogram:
            typeIdentifier = HKObjectType.electrocardiogramType().identifier
            value = Double(electrocardiogram.numberOfVoltageMeasurements)
            unit = "count"
            category = "heart"
            valueDescription = electrocardiogram.classification.name
            var ecgMetadata = [
                "classification": electrocardiogram.classification.name,
                "numberOfVoltageMeasurements": String(electrocardiogram.numberOfVoltageMeasurements),
                "symptomsStatus": electrocardiogram.symptomsStatus.name
            ]
            if let heartRate = electrocardiogram.averageHeartRate,
               heartRate.is(compatibleWith: .count().unitDivided(by: .minute())) {
                ecgMetadata["averageHeartRate_bpm"] = String(
                    heartRate.doubleValue(for: .count().unitDivided(by: .minute()))
                )
            }
            if let frequency = electrocardiogram.samplingFrequency,
               frequency.is(compatibleWith: .hertz()) {
                ecgMetadata["samplingFrequency_hz"] = String(
                    frequency.doubleValue(for: .hertz())
                )
            }
            metadata = ecgMetadata

        case let workout as HKWorkout:
            typeIdentifier = "workout"
            value = workout.duration
            unit = "s"
            category = "activity"
            valueDescription = workout.workoutActivityType.name
            let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
            let activeEnergy = activeEnergyType.flatMap { workout.statistics(for: $0)?.sumQuantity() }
            metadata = [
                "activityType": String(workout.workoutActivityType.rawValue),
                "totalEnergyBurned_kcal": activeEnergy.map { String($0.doubleValue(for: .kilocalorie())) } ?? "",
            ]

        default:
            typeIdentifier = "unknown"
            category = "unknown"
            value = nil
            unit = nil
        }

        let sourceName = sample.sourceRevision.source.name
        let sourceBundle = sample.sourceRevision.source.bundleIdentifier
        let deviceName = sample.device?.name
        let start = sample.startDate
        let end = sample.endDate

        let fp = fingerprint(id: sample.uuid,
                             type: typeIdentifier,
                             start: start,
                             end: end,
                             source: sourceBundle)

        return HealthSampleDTO(
            id: sample.uuid.uuidString,
            type: typeIdentifier,
            category: category,
            startDate: start,
            endDate: end,
            value: value,
            unit: unit,
            valueDescription: valueDescription,
            sourceName: sourceName,
            sourceBundleID: sourceBundle,
            deviceName: deviceName,
            metadata: metadata,
            ecgVoltageMeasurements: ecgVoltageMeasurements,
            fingerprint: fp
        )
    }

    /// 类型所属分类。
    private static func typeCategory(identifier: String) -> String {
        categoryByIdentifier[identifier] ?? "unknown"
    }

    private static let categoryByIdentifier: [String: String] = {
        var result: [String: String] = [:]
        for type in HealthDataType.allCases {
            guard let identifier = type.objectType?.identifier else { continue }
            result[identifier] = type.category.dtoCategory
        }
        return result
    }()

    /// 选择首选显示单位。
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
}

private extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .traditionalStrengthTraining: return "strength"
        case .functionalStrengthTraining: return "functionalStrength"
        case .highIntensityIntervalTraining: return "hiit"
        case .stairClimbing: return "stairClimbing"
        case .other: return "other"
        default: return String(describing: self)
        }
    }
}

private extension HKElectrocardiogram.Classification {
    var name: String {
        switch self {
        case .notSet: return "notSet"
        case .sinusRhythm: return "sinusRhythm"
        case .atrialFibrillation: return "atrialFibrillation"
        case .inconclusiveLowHeartRate: return "inconclusiveLowHeartRate"
        case .inconclusiveHighHeartRate: return "inconclusiveHighHeartRate"
        case .inconclusivePoorReading: return "inconclusivePoorReading"
        case .inconclusiveOther: return "inconclusiveOther"
        case .unrecognized: return "unrecognized"
        @unknown default: return "unknown"
        }
    }
}

private extension HKElectrocardiogram.SymptomsStatus {
    var name: String {
        switch self {
        case .notSet: return "notSet"
        case .none: return "none"
        case .present: return "present"
        @unknown default: return "unknown"
        }
    }
}

private extension HealthCategory {
    var dtoCategory: String {
        switch self {
        case .activity: return "activity"
        case .heart: return "heart"
        case .sleep: return "sleep"
        case .body: return "body"
        case .respiratory: return "respiratory"
        case .nutrition: return "nutrition"
        case .metabolic: return "metabolic"
        case .reproductiveHealth: return "reproductive"
        }
    }
}
