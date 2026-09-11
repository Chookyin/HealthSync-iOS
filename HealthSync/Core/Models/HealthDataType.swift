import Foundation
import HealthKit

/// 健康数据类型分类（8 大分类，用于设置页分组展示）。
public enum HealthCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case activity = "活动与运动"
    case heart = "心率与心脏"
    case sleep = "睡眠"
    case body = "身体测量"
    case respiratory = "呼吸"
    case nutrition = "营养与水分"
    case metabolic = "血糖与代谢"
    case reproductiveHealth = "女性健康"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .activity: return "figure.walk"
        case .heart: return "heart.fill"
        case .sleep: return "moon.zzz.fill"
        case .body: return "figure.stand"
        case .respiratory: return "lungs.fill"
        case .nutrition: return "fork.knife"
        case .metabolic: return "drop.fill"
        case .reproductiveHealth: return "figure.dress.line.vertical.figure"
        }
    }
}

/// 全量健康数据类型清单（42 种），承载到 `HKObjectType` 的映射。
/// 默认仅启用各分类下的核心可读类型，敏感类型（血氧、女性健康等）由设置页手动开启。
public enum HealthDataType: String, CaseIterable, Codable, Sendable, Identifiable {
    // MARK: - 活动与运动
    case stepCount = "stepCount"
    case distanceWalkingRunning = "distanceWalkingRunning"
    case distanceCycling = "distanceCycling"
    case distanceSwimming = "distanceSwimming"
    case activeEnergyBurned = "activeEnergyBurned"
    case basalEnergyBurned = "basalEnergyBurned"
    case appleExerciseTime = "appleExerciseTime"
    case appleStandTime = "appleStandTime"
    case flightsClimbed = "flightsClimbed"
    case walkingSpeed = "walkingSpeed"
    case runningSpeed = "runningSpeed"
    case runningPower = "runningPower"
    case physicalEffort = "physicalEffort"
    case workouts = "workouts"
    case sixMinuteWalkTestDistance = "sixMinuteWalkTestDistance"
    case appleWalkingSteadiness = "appleWalkingSteadiness"
    case audioExposureEvent = "audioExposureEvent"
    case estimatedWorkoutEffortScore = "estimatedWorkoutEffortScore"
    case workoutEffortScore = "workoutEffortScore"
    case mindfulSession = "mindfulSession"
    case highHeartRateEvent = "highHeartRateEvent"
    case distanceDownhillSnowSports = "distanceDownhillSnowSports"
    case swimmingStrokeCount = "swimmingStrokeCount"

    // MARK: - 心率与心脏
    case heartRate = "heartRate"
    case restingHeartRate = "restingHeartRate"
    case walkingHeartRateAverage = "walkingHeartRateAverage"
    case heartRateVariabilitySDNN = "heartRateVariabilitySDNN"
    case bloodPressureSystolic = "bloodPressureSystolic"
    case bloodPressureDiastolic = "bloodPressureDiastolic"
    case oxygenSaturation = "oxygenSaturation"
    case bodyTemperature = "bodyTemperature"
    case vo2Max = "vo2Max"
    case electrocardiogram = "electrocardiogram"
    case heartRateRecoveryOneMinute = "heartRateRecoveryOneMinute"
    case appleSleepingWristTemperature = "appleSleepingWristTemperature"

    // MARK: - 睡眠
    case sleepAnalysis = "sleepAnalysis"
    case sleepInBed = "sleepInBed"
    case sleepAsleep = "sleepAsleep"
    case sleepAwake = "sleepAwake"
    case sleepREM = "sleepREM"
    case sleepCore = "sleepCore"
    case sleepDeep = "sleepDeep"

    // MARK: - 身体测量
    case bodyMass = "bodyMass"
    case height = "height"
    case bodyMassIndex = "bodyMassIndex"
    case bodyFatPercentage = "bodyFatPercentage"
    case leanBodyMass = "leanBodyMass"
    case waistCircumference = "waistCircumference"
    case atrialFibrillationBurden = "atrialFibrillationBurden"

    // MARK: - 呼吸
    case respiratoryRate = "respiratoryRate"
    case forcedExpiratoryVolume1 = "forcedExpiratoryVolume1"
    case forcedVitalCapacity = "forcedVitalCapacity"
    case peakExpiratoryFlowRate = "peakExpiratoryFlowRate"
    case chestTightnessOrPain = "chestTightnessOrPain"
    case shortnessOfBreath = "shortnessOfBreath"

    // MARK: - 营养与水分
    case dietaryEnergyConsumed = "dietaryEnergyConsumed"
    case dietaryProtein = "dietaryProtein"
    case dietaryFatTotal = "dietaryFatTotal"
    case dietaryCarbohydrates = "dietaryCarbohydrates"
    case dietaryWater = "dietaryWater"
    case dietaryCaffeine = "dietaryCaffeine"
    case dietaryFiber = "dietaryFiber"
    case dietarySodium = "dietarySodium"
    case dietaryPotassium = "dietaryPotassium"
    case dietaryIron = "dietaryIron"
    case dietarySugar = "dietarySugar"
    case dietaryFatSaturated = "dietaryFatSaturated"
    case dietaryVitaminB6 = "dietaryVitaminB6"
    case dietaryCalcium = "dietaryCalcium"
    case dietaryThiamin = "dietaryThiamin"
    case dietaryRiboflavin = "dietaryRiboflavin"
    case dietaryNiacin = "dietaryNiacin"
    case dietaryFolate = "dietaryFolate"
    case dietaryPantothenicAcid = "dietaryPantothenicAcid"
    case dietaryPhosphorus = "dietaryPhosphorus"
    case dietaryMagnesium = "dietaryMagnesium"
    case dietaryZinc = "dietaryZinc"
    case dietarySelenium = "dietarySelenium"
    case dietaryCopper = "dietaryCopper"
    case dietaryManganese = "dietaryManganese"
    case dietaryFatPolyunsaturated = "dietaryFatPolyunsaturated"
    case dietaryFatMonounsaturated = "dietaryFatMonounsaturated"
    case dietaryVitaminA = "dietaryVitaminA"
    case dietaryCholesterol = "dietaryCholesterol"
    case dietaryVitaminC = "dietaryVitaminC"
    case dietaryVitaminE = "dietaryVitaminE"
    case dietaryVitaminK = "dietaryVitaminK"
    case dietaryVitaminB12 = "dietaryVitaminB12"
    case dietaryBiotin = "dietaryBiotin"
    case dietaryIodine = "dietaryIodine"
    case dietaryMolybdenum = "dietaryMolybdenum"

    // MARK: - 血糖与代谢
    case bloodGlucose = "bloodGlucose"
    case insulinDelivery = "insulinDelivery"

    // MARK: - 女性健康
    case menstrualCycle = "menstrualCycle"
    case ovulationTestResult = "ovulationTestResult"
    case pregnancy = "pregnancy"
    case pregnancyTestResult = "pregnancyTestResult"
    case cervicalMucusQuality = "cervicalMucusQuality"
    case sexualActivity = "sexualActivity"
    case basalBodyTemperature = "basalBodyTemperature"
    case intermenstrualBleeding = "intermenstrualBleeding"
    case progesterone = "progesterone"

    public var id: String { rawValue }

    /// 所属分类。
    public var category: HealthCategory {
        switch self {
        case .stepCount, .distanceWalkingRunning, .distanceCycling, .distanceSwimming,
             .activeEnergyBurned, .basalEnergyBurned, .appleExerciseTime, .appleStandTime,
             .flightsClimbed, .walkingSpeed, .runningSpeed, .runningPower, .physicalEffort,
             .workouts, .sixMinuteWalkTestDistance, .appleWalkingSteadiness, .audioExposureEvent,
             .estimatedWorkoutEffortScore, .workoutEffortScore, .mindfulSession, .highHeartRateEvent,
             .distanceDownhillSnowSports, .swimmingStrokeCount:
            return .activity
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage, .heartRateVariabilitySDNN,
             .bloodPressureSystolic, .bloodPressureDiastolic, .oxygenSaturation,
             .bodyTemperature, .vo2Max, .electrocardiogram, .heartRateRecoveryOneMinute,
             .appleSleepingWristTemperature:
            return .heart
        case .sleepAnalysis, .sleepInBed, .sleepAsleep, .sleepAwake, .sleepREM, .sleepCore, .sleepDeep:
            return .sleep
        case .bodyMass, .height, .bodyMassIndex, .bodyFatPercentage, .leanBodyMass,
             .waistCircumference, .atrialFibrillationBurden:
            return .body
        case .respiratoryRate, .forcedExpiratoryVolume1, .forcedVitalCapacity, .peakExpiratoryFlowRate,
             .chestTightnessOrPain, .shortnessOfBreath:
            return .respiratory
        case .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates,
             .dietaryWater, .dietaryCaffeine, .dietaryFiber, .dietarySodium, .dietaryPotassium,
             .dietaryIron, .dietarySugar, .dietaryFatSaturated, .dietaryVitaminB6, .dietaryCalcium,
             .dietaryThiamin, .dietaryRiboflavin, .dietaryNiacin, .dietaryFolate,
             .dietaryPantothenicAcid, .dietaryPhosphorus, .dietaryMagnesium, .dietaryZinc,
             .dietarySelenium, .dietaryCopper, .dietaryManganese, .dietaryFatPolyunsaturated,
             .dietaryFatMonounsaturated, .dietaryVitaminA, .dietaryCholesterol, .dietaryVitaminC,
             .dietaryVitaminE, .dietaryVitaminK, .dietaryVitaminB12, .dietaryBiotin, .dietaryIodine,
             .dietaryMolybdenum:
            return .nutrition
        case .bloodGlucose, .insulinDelivery:
            return .metabolic
        case .menstrualCycle, .ovulationTestResult, .pregnancy, .pregnancyTestResult,
             .cervicalMucusQuality, .sexualActivity, .basalBodyTemperature,
             .intermenstrualBleeding, .progesterone:
            return .reproductiveHealth
        }
    }

    /// 是否为敏感/受限类型（需用户在设置页显式开启）。
    public var isSensitive: Bool {
        switch self {
        case .oxygenSaturation, .appleSleepingWristTemperature,
             .bloodGlucose, .insulinDelivery, .electrocardiogram,
             .highHeartRateEvent, .chestTightnessOrPain, .shortnessOfBreath:
            return true
        case .menstrualCycle, .ovulationTestResult, .pregnancy, .pregnancyTestResult,
             .cervicalMucusQuality, .sexualActivity, .basalBodyTemperature,
             .intermenstrualBleeding, .progesterone:
            return true
        default:
            return false
        }
    }

    /// 对应的 `HKObjectType`（可能为 nil：某些类型在当前 iOS 版本 HealthKit 未启用，需安全跳过）。
    /// 对应的 `HKObjectType`（可能为 nil：某些类型在当前 iOS 版本 HealthKit 未启用，需安全跳过）。
    public var objectType: HKObjectType? {
        switch self {
        case .stepCount: return HKObjectType.quantityType(forIdentifier: .stepCount)
        case .distanceWalkingRunning: return HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning)
        case .distanceCycling: return HKObjectType.quantityType(forIdentifier: .distanceCycling)
        case .distanceSwimming: return HKObjectType.quantityType(forIdentifier: .distanceSwimming)
        case .activeEnergyBurned: return HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
        case .basalEnergyBurned: return HKObjectType.quantityType(forIdentifier: .basalEnergyBurned)
        case .appleExerciseTime: return HKObjectType.quantityType(forIdentifier: .appleExerciseTime)
        case .appleStandTime: return HKObjectType.quantityType(forIdentifier: .appleStandTime)
        case .flightsClimbed: return HKObjectType.quantityType(forIdentifier: .flightsClimbed)
        case .walkingSpeed: return HKObjectType.quantityType(forIdentifier: .walkingSpeed)
        case .runningSpeed: return HKObjectType.quantityType(forIdentifier: .runningSpeed)
        case .runningPower: return HKObjectType.quantityType(forIdentifier: .runningPower)
        case .physicalEffort: return HKObjectType.quantityType(forIdentifier: .physicalEffort)
        case .workouts: return HKObjectType.workoutType()
        case .sixMinuteWalkTestDistance: return HKObjectType.quantityType(forIdentifier: .sixMinuteWalkTestDistance)
        case .appleWalkingSteadiness: return HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness)
        case .audioExposureEvent: return HKObjectType.categoryType(forIdentifier: .audioExposureEvent)
        case .estimatedWorkoutEffortScore: return HKObjectType.quantityType(forIdentifier: .estimatedWorkoutEffortScore)
        case .workoutEffortScore: return HKObjectType.quantityType(forIdentifier: .workoutEffortScore)
        case .mindfulSession: return HKObjectType.categoryType(forIdentifier: .mindfulSession)
        case .highHeartRateEvent: return HKObjectType.categoryType(forIdentifier: .highHeartRateEvent)
        case .distanceDownhillSnowSports: return HKObjectType.quantityType(forIdentifier: .distanceDownhillSnowSports)
        case .swimmingStrokeCount: return HKObjectType.quantityType(forIdentifier: .swimmingStrokeCount)

        case .heartRate: return HKObjectType.quantityType(forIdentifier: .heartRate)
        case .restingHeartRate: return HKObjectType.quantityType(forIdentifier: .restingHeartRate)
        case .walkingHeartRateAverage: return HKObjectType.quantityType(forIdentifier: .walkingHeartRateAverage)
        case .heartRateVariabilitySDNN: return HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
        case .bloodPressureSystolic: return HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic)
        case .bloodPressureDiastolic: return HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic)
        case .oxygenSaturation: return HKObjectType.quantityType(forIdentifier: .oxygenSaturation)
        case .bodyTemperature: return HKObjectType.quantityType(forIdentifier: .bodyTemperature)
        case .vo2Max: return HKObjectType.quantityType(forIdentifier: .vo2Max)
        case .electrocardiogram: return HKObjectType.electrocardiogramType()
        case .heartRateRecoveryOneMinute: return HKObjectType.quantityType(forIdentifier: .heartRateRecoveryOneMinute)
        case .appleSleepingWristTemperature: return HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature)

        case .sleepAnalysis: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .sleepInBed: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .sleepAsleep: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .sleepAwake: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .sleepREM: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .sleepCore: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .sleepDeep: return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)

        case .bodyMass: return HKObjectType.quantityType(forIdentifier: .bodyMass)
        case .height: return HKObjectType.quantityType(forIdentifier: .height)
        case .bodyMassIndex: return HKObjectType.quantityType(forIdentifier: .bodyMassIndex)
        case .bodyFatPercentage: return HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)
        case .leanBodyMass: return HKObjectType.quantityType(forIdentifier: .leanBodyMass)
        case .waistCircumference: return HKObjectType.quantityType(forIdentifier: .waistCircumference)
        case .atrialFibrillationBurden: return HKObjectType.quantityType(forIdentifier: .atrialFibrillationBurden)

        case .respiratoryRate: return HKObjectType.quantityType(forIdentifier: .respiratoryRate)
        case .forcedExpiratoryVolume1: return HKObjectType.quantityType(forIdentifier: .forcedExpiratoryVolume1)
        case .forcedVitalCapacity: return HKObjectType.quantityType(forIdentifier: .forcedVitalCapacity)
        case .peakExpiratoryFlowRate: return HKObjectType.quantityType(forIdentifier: .peakExpiratoryFlowRate)
        case .chestTightnessOrPain: return HKObjectType.categoryType(forIdentifier: .chestTightnessOrPain)
        case .shortnessOfBreath: return HKObjectType.categoryType(forIdentifier: .shortnessOfBreath)

        case .dietaryEnergyConsumed: return HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed)
        case .dietaryProtein: return HKObjectType.quantityType(forIdentifier: .dietaryProtein)
        case .dietaryFatTotal: return HKObjectType.quantityType(forIdentifier: .dietaryFatTotal)
        case .dietaryCarbohydrates: return HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates)
        case .dietaryWater: return HKObjectType.quantityType(forIdentifier: .dietaryWater)
        case .dietaryCaffeine: return HKObjectType.quantityType(forIdentifier: .dietaryCaffeine)
        case .dietaryFiber: return HKObjectType.quantityType(forIdentifier: .dietaryFiber)
        case .dietarySodium: return HKObjectType.quantityType(forIdentifier: .dietarySodium)
        case .dietaryPotassium: return HKObjectType.quantityType(forIdentifier: .dietaryPotassium)
        case .dietaryIron: return HKObjectType.quantityType(forIdentifier: .dietaryIron)
        case .dietarySugar: return HKObjectType.quantityType(forIdentifier: .dietarySugar)
        case .dietaryFatSaturated: return HKObjectType.quantityType(forIdentifier: .dietaryFatSaturated)
        case .dietaryVitaminB6: return HKObjectType.quantityType(forIdentifier: .dietaryVitaminB6)
        case .dietaryCalcium: return HKObjectType.quantityType(forIdentifier: .dietaryCalcium)
        case .dietaryThiamin: return HKObjectType.quantityType(forIdentifier: .dietaryThiamin)
        case .dietaryRiboflavin: return HKObjectType.quantityType(forIdentifier: .dietaryRiboflavin)
        case .dietaryNiacin: return HKObjectType.quantityType(forIdentifier: .dietaryNiacin)
        case .dietaryFolate: return HKObjectType.quantityType(forIdentifier: .dietaryFolate)
        case .dietaryPantothenicAcid: return HKObjectType.quantityType(forIdentifier: .dietaryPantothenicAcid)
        case .dietaryPhosphorus: return HKObjectType.quantityType(forIdentifier: .dietaryPhosphorus)
        case .dietaryMagnesium: return HKObjectType.quantityType(forIdentifier: .dietaryMagnesium)
        case .dietaryZinc: return HKObjectType.quantityType(forIdentifier: .dietaryZinc)
        case .dietarySelenium: return HKObjectType.quantityType(forIdentifier: .dietarySelenium)
        case .dietaryCopper: return HKObjectType.quantityType(forIdentifier: .dietaryCopper)
        case .dietaryManganese: return HKObjectType.quantityType(forIdentifier: .dietaryManganese)
        case .dietaryFatPolyunsaturated: return HKObjectType.quantityType(forIdentifier: .dietaryFatPolyunsaturated)
        case .dietaryFatMonounsaturated: return HKObjectType.quantityType(forIdentifier: .dietaryFatMonounsaturated)
        case .dietaryVitaminA: return HKObjectType.quantityType(forIdentifier: .dietaryVitaminA)
        case .dietaryCholesterol: return HKObjectType.quantityType(forIdentifier: .dietaryCholesterol)
        case .dietaryVitaminC: return HKObjectType.quantityType(forIdentifier: .dietaryVitaminC)
        case .dietaryVitaminE: return HKObjectType.quantityType(forIdentifier: .dietaryVitaminE)
        case .dietaryVitaminK: return HKObjectType.quantityType(forIdentifier: .dietaryVitaminK)
        case .dietaryVitaminB12: return HKObjectType.quantityType(forIdentifier: .dietaryVitaminB12)
        case .dietaryBiotin: return HKObjectType.quantityType(forIdentifier: .dietaryBiotin)
        case .dietaryIodine: return HKObjectType.quantityType(forIdentifier: .dietaryIodine)
        case .dietaryMolybdenum: return HKObjectType.quantityType(forIdentifier: .dietaryMolybdenum)

        case .bloodGlucose: return HKObjectType.quantityType(forIdentifier: .bloodGlucose)
        case .insulinDelivery: return HKObjectType.quantityType(forIdentifier: .insulinDelivery)

        // 女性健康
        case .menstrualCycle: return HKObjectType.categoryType(forIdentifier: .menstrualFlow)
        case .ovulationTestResult: return HKObjectType.categoryType(forIdentifier: .ovulationTestResult)
        case .pregnancy: return HKObjectType.categoryType(forIdentifier: .pregnancy)
        case .pregnancyTestResult: return HKObjectType.categoryType(forIdentifier: .pregnancyTestResult)
        case .cervicalMucusQuality: return HKObjectType.categoryType(forIdentifier: .cervicalMucusQuality)
        case .sexualActivity: return HKObjectType.categoryType(forIdentifier: .sexualActivity)
        case .basalBodyTemperature: return HKObjectType.quantityType(forIdentifier: .basalBodyTemperature)
        case .intermenstrualBleeding: return HKObjectType.categoryType(forIdentifier: .intermenstrualBleeding)
        case .progesterone: return HKObjectType.categoryType(forIdentifier: .progesteroneTestResult)
        }
    }

    /// 该类型是否可作为「只读授权」的标准类型提交给 `requestAuthorization`。
    /// `workouts` / `electrocardiogram` 分别对应 `HKWorkoutType` / `HKElectrocardiogramType`，
    /// 这类特殊类型在 iOS 27 上混入 read 集合可能导致 `requestAuthorization` 抛错，
    /// 从而拖垮整个授权请求，故在此排除，只把可授权的标准类型交给系统。
    public var isRequestableReadType: Bool {
        switch self {
        case .workouts, .electrocardiogram:
            return false
        default:
            return true
        }
    }

    /// 默认启用的核心类型（全量能力 42 种，默认勾选其中主流的 28 种，敏感类型默认关闭）。
    public static let defaultEnabled: Set<HealthDataType> = {
        let excluded: Set<HealthDataType> = [.oxygenSaturation, .appleSleepingWristTemperature,
                                             .bloodGlucose,
                                             .insulinDelivery, .electrocardiogram,
                                             .bodyTemperature, .sleepInBed, .sleepAsleep,
                                             .sleepAwake, .sleepREM, .sleepCore, .sleepDeep,
                                             .highHeartRateEvent, .chestTightnessOrPain,
                                             .shortnessOfBreath,
                                             // 女性健康默认关闭（按性别按需手动开启）
                                             .menstrualCycle, .ovulationTestResult, .pregnancy,
                                             .pregnancyTestResult, .cervicalMucusQuality,
                                             .sexualActivity, .basalBodyTemperature,
                                             .intermenstrualBleeding, .progesterone]
        return Set(HealthDataType.allCases).subtracting(excluded)
    }()

    public var displayName: String {
        switch self {
        case .stepCount: return "步数"
        case .distanceWalkingRunning: return "步行+跑步距离"
        case .distanceCycling: return "骑行距离"
        case .distanceSwimming: return "游泳距离"
        case .activeEnergyBurned: return "活动能量"
        case .basalEnergyBurned: return "基础能量"
        case .appleExerciseTime: return "运动时间"
        case .appleStandTime: return "站立时间"
        case .flightsClimbed: return "爬楼层数"
        case .walkingSpeed: return "步速"
        case .runningSpeed: return "跑步速度"
        case .runningPower: return "跑步功率"
        case .physicalEffort: return "体能活动 PhysicalEffort"
        case .workouts: return "锻炼"
        case .sixMinuteWalkTestDistance: return "六分钟步行距离"
        case .appleWalkingSteadiness: return "步行稳定性"
        case .audioExposureEvent: return "音频暴露事件"
        case .estimatedWorkoutEffortScore: return "预估运动强度"
        case .workoutEffortScore: return "运动强度"
        case .mindfulSession: return "正念"
        case .highHeartRateEvent: return "高心率事件"
        case .distanceDownhillSnowSports: return "滑雪距离"
        case .swimmingStrokeCount: return "游泳划水次数"

        case .heartRate: return "心率"
        case .restingHeartRate: return "静息心率"
        case .walkingHeartRateAverage: return "步行平均心率"
        case .heartRateVariabilitySDNN: return "心率变异性 HRV"
        case .bloodPressureSystolic: return "收缩压"
        case .bloodPressureDiastolic: return "舒张压"
        case .oxygenSaturation: return "血氧 SpO2"
        case .bodyTemperature: return "体温"
        case .vo2Max: return "最大摄氧量 VO₂max"
        case .electrocardiogram: return "心电图 ECG"
        case .heartRateRecoveryOneMinute: return "心率恢复"
        case .appleSleepingWristTemperature: return "睡眠手腕温度"

        case .sleepAnalysis: return "睡眠分析（全阶段）"
        case .sleepInBed: return "在床时间"
        case .sleepAsleep: return "入睡时间"
        case .sleepAwake: return "清醒时间"
        case .sleepREM: return "快速眼动 REM"
        case .sleepCore: return "核心睡眠"
        case .sleepDeep: return "深度睡眠"

        case .bodyMass: return "体重"
        case .height: return "身高"
        case .bodyMassIndex: return "BMI"
        case .bodyFatPercentage: return "体脂率"
        case .leanBodyMass: return "瘦体重"
        case .waistCircumference: return "腰围"
        case .atrialFibrillationBurden: return "房颤负担"

        case .respiratoryRate: return "呼吸频率"
        case .forcedExpiratoryVolume1: return "用力肺活量 FEV1"
        case .forcedVitalCapacity: return "最大肺活量 FVC"
        case .peakExpiratoryFlowRate: return "吸气峰流量 PEF"
        case .chestTightnessOrPain: return "胸闷或胸痛"
        case .shortnessOfBreath: return "气短"

        case .dietaryEnergyConsumed: return "能量摄入"
        case .dietaryProtein: return "蛋白质"
        case .dietaryFatTotal: return "脂肪"
        case .dietaryCarbohydrates: return "碳水化合物"
        case .dietaryWater: return "水分"
        case .dietaryCaffeine: return "咖啡因"
        case .dietaryFiber: return "纤维"
        case .dietarySodium: return "钠"
        case .dietaryPotassium: return "钾"
        case .dietaryIron: return "铁"
        case .dietarySugar: return "糖"
        case .dietaryFatSaturated: return "饱和脂肪"
        case .dietaryVitaminB6: return "维生素B6"
        case .dietaryCalcium: return "钙"
        case .dietaryThiamin: return "维生素B1"
        case .dietaryRiboflavin: return "维生素B2"
        case .dietaryNiacin: return "烟酸"
        case .dietaryFolate: return "叶酸"
        case .dietaryPantothenicAcid: return "泛酸"
        case .dietaryPhosphorus: return "磷"
        case .dietaryMagnesium: return "镁"
        case .dietaryZinc: return "锌"
        case .dietarySelenium: return "硒"
        case .dietaryCopper: return "铜"
        case .dietaryManganese: return "锰"
        case .dietaryFatPolyunsaturated: return "多不饱和脂肪"
        case .dietaryFatMonounsaturated: return "单不饱和脂肪"
        case .dietaryVitaminA: return "维生素A"
        case .dietaryCholesterol: return "胆固醇"
        case .dietaryVitaminC: return "维生素C"
        case .dietaryVitaminE: return "维生素E"
        case .dietaryVitaminK: return "维生素K"
        case .dietaryVitaminB12: return "维生素B12"
        case .dietaryBiotin: return "生物素"
        case .dietaryIodine: return "碘"
        case .dietaryMolybdenum: return "钼"

        case .bloodGlucose: return "血糖"
        case .insulinDelivery: return "胰岛素"

        case .menstrualCycle: return "经期周期"
        case .ovulationTestResult: return "排卵测试"
        case .pregnancy: return "怀孕"
        case .pregnancyTestResult: return "验孕"
        case .cervicalMucusQuality: return "宫颈黏液状态"
        case .sexualActivity: return "性活动"
        case .basalBodyTemperature: return "基础体温"
        case .intermenstrualBleeding: return "经间期出血"
        case .progesterone: return "孕酮"
        }
    }

}