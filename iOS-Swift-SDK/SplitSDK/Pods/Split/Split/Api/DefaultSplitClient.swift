//
//  LocalSplitClient.swift
//  Pods
//
//  Created by Brian Sztamfater on 20/9/17.
//  Modified by Natalia Stele on 11/10/17.

//
//

import Foundation

public final class DefaultSplitClient: NSObject, SplitClient, InternalSplitClient {
    
    internal var splitFetcher: SplitFetcher?
    internal var mySegmentsFetcher: MySegmentsFetcher?
    
    private let keyQueue = DispatchQueue(label: "com.splitio.com.key", attributes: .concurrent)
    private var key: Key
    internal var initialized: Bool = false
    internal var config: SplitClientConfig?
    internal var dispatchGroup: DispatchGroup?
    let splitImpressionManager: ImpressionManager
    public var shouldSendBucketingKey: Bool = false
    
    private var eventsManager: SplitEventsManager
    private var trackEventsManager: TrackManager
    private var metricsManager: MetricsManager
    
    private let keyValidator: KeyValidator
    private let splitValidator: SplitValidator
    private let eventValidator: EventValidator
    private let validationLogger: ValidationMessageLogger
    
    init(config: SplitClientConfig, key: Key, splitCache: SplitCache, fileStorage: FileStorageProtocol) {
        self.config = config
        self.keyValidator = DefaultKeyValidator()
        self.eventValidator = DefaultEventValidator()
        self.splitValidator = DefaultSplitValidator()
        self.validationLogger = DefaultValidationMessageLogger()
        
        let mySegmentsCache = MySegmentsCache(matchingKey: key.matchingKey, fileStorage: fileStorage)
        eventsManager = DefaultSplitEventsManager(config: config)
        eventsManager.start()
        
        let refreshableSplitFetcher = RefreshableSplitFetcher(splitChangeFetcher: HttpSplitChangeFetcher(restClient: RestClient(), splitCache: splitCache), splitCache: splitCache, interval: self.config!.featuresRefreshRate, eventsManager: eventsManager)
        
        let refreshableMySegmentsFetcher = RefreshableMySegmentsFetcher(matchingKey: key.matchingKey, mySegmentsChangeFetcher: HttpMySegmentsFetcher(restClient: RestClient(), mySegmentsCache: mySegmentsCache), mySegmentsCache: mySegmentsCache, interval: self.config!.segmentsRefreshRate, eventsManager: eventsManager)
        
        
        var trackConfig = TrackManagerConfig()
        trackConfig.pushRate = config.eventsPushRate
        trackConfig.firstPushWindow = config.eventsFirstPushWindow
        trackConfig.eventsPerPush = config.eventsPerPush
        trackConfig.queueSize = config.eventsQueueSize
        trackEventsManager = TrackManager(config: trackConfig, fileStorage: fileStorage)
        
        var impressionsConfig = ImpressionManagerConfig()
        impressionsConfig.pushRate = config.impressionRefreshRate
        impressionsConfig.impressionsPerPush = config.impressionsChunkSize
        splitImpressionManager = ImpressionManager(config: impressionsConfig, fileStorage: fileStorage)
        
        metricsManager = MetricsManager.shared
        
        self.initialized = false
        if let bucketingKey = key.bucketingKey, !bucketingKey.isEmpty() {
            self.key = Key(matchingKey: key.matchingKey , bucketingKey: bucketingKey)
            self.shouldSendBucketingKey = true
        } else {
            self.key = Key(matchingKey: key.matchingKey, bucketingKey: key.matchingKey)
        }
        super.init()
        self.dispatchGroup = nil
        refreshableSplitFetcher.start()
        refreshableMySegmentsFetcher.start()
        self.splitFetcher = refreshableSplitFetcher
        self.mySegmentsFetcher = refreshableMySegmentsFetcher
        
        eventsManager.getExecutorResources().setClient(client: self)
        
        trackEventsManager.start()
        splitImpressionManager.start()
        
        Logger.i("iOS Split SDK initialized!")
    }
}

// MARK: Events
extension DefaultSplitClient {
    public func on(event: SplitEvent, execute action: @escaping SplitAction){
        if eventsManager.eventAlreadyTriggered(event: event) {
            Logger.w("A handler was added for \(event.toString()) on the SDK, which has already fired and won’t be emitted again. The callback won’t be executed.")
            return
        }
        let task = SplitEventActionTask(action: action)
        eventsManager.register(event: event, task: task)
    }
}

// MARK: Treatment / Evaluation
extension DefaultSplitClient {
    
    public func getTreatmentWithConfig(_ split: String) -> SplitResult {
        return getTreatmentWithConfig(split, attributes: nil)
    }
    
    public func getTreatmentWithConfig(_ split: String, attributes: [String : Any]?) -> SplitResult {
        let timeMetricStart = Date().unixTimestampInMicroseconds()
        let result = getTreatmentWithConfigNoMetrics(splitName: split, shouldValidate: true, attributes: attributes, validationTag: ValidationTag.getTreatmentWithConfig)
        metricsManager.time(microseconds: Date().unixTimestampInMicroseconds() - timeMetricStart, for: Metrics.time.getTreatmentWithConfig)
        return result
    }
    
    public func getTreatment(_ split: String) -> String {
        return getTreatment(split, attributes: nil)
    }
    
    public func getTreatment(_ split: String, attributes: [String : Any]?) -> String {
        let timeMetricStart = Date().unixTimestampInMicroseconds()
        let result = getTreatmentWithConfigNoMetrics(splitName: split, shouldValidate: true, attributes: attributes, validationTag: ValidationTag.getTreatment).treatment
        metricsManager.time(microseconds: Date().unixTimestampInMicroseconds() - timeMetricStart, for: Metrics.time.getTreatment)
        return result
    }
    
    public func getTreatments(splits: [String], attributes:[String:Any]?) ->  [String:String] {
        let timeMetricStart = Date().unixTimestampInMicroseconds()
        let result = getTreatmentsWithConfigNoMetrics(splits: splits, attributes: attributes, validationTag: ValidationTag.getTreatments).mapValues { $0.treatment }
        metricsManager.time(microseconds: Date().unixTimestampInMicroseconds() - timeMetricStart, for: Metrics.time.getTreatments)
        return result
    }
    
    public func getTreatmentsWithConfig(splits: [String], attributes:[String:Any]?) ->  [String:SplitResult] {
        let timeMetricStart = Date().unixTimestampInMicroseconds()
        let result = getTreatmentsWithConfigNoMetrics(splits: splits, attributes: attributes, validationTag: ValidationTag.getTreatmentsWithConfig)
        metricsManager.time(microseconds: Date().unixTimestampInMicroseconds() - timeMetricStart, for: Metrics.time.getTreatmentsWithConfig)
        return result
    }
    
    private func getTreatmentsWithConfigNoMetrics(splits: [String], attributes:[String:Any]?, validationTag: String) ->  [String:SplitResult] {
        var results = [String:SplitResult]()

        if splits.count > 0 {
            let splitsNoDuplicated = Set(splits.filter { !$0.isEmpty() }.map { $0 })
            for splitName in splitsNoDuplicated {
                results[splitName] = getTreatmentWithConfigNoMetrics(splitName: splitName, shouldValidate: false, attributes: attributes, validationTag: validationTag)
            }
        } else {
            Logger.d("\(validationTag): split_names is an empty array or has null values")
        }
        return results
    }
    
    private func getTreatmentWithConfigNoMetrics(splitName: String, shouldValidate: Bool = true, attributes:[String:Any]? = nil, validationTag: String) -> SplitResult {
        
        if shouldValidate {
            if !eventsManager.eventAlreadyTriggered(event: SplitEvent.sdkReady) {
                Logger.w("No listeners for SDK Readiness detected. Incorrect control treatments could be logged if you call getTreatment while the SDK is not yet ready")
            }
            
            if let errorInfo = keyValidator.validate(matchingKey: key.matchingKey, bucketingKey: key.bucketingKey) {
                validationLogger.log(errorInfo: errorInfo, tag: validationTag)
                return SplitResult(treatment: SplitConstants.CONTROL)
            }
        }
        
        if let errorInfo = splitValidator.validate(name: splitName) {
            validationLogger.log(errorInfo: errorInfo, tag: validationTag)
            if errorInfo.isError {
                return SplitResult(treatment: SplitConstants.CONTROL)
            }
        }
        
        let trimmedSplitName = splitName.trimmingCharacters(in: .whitespacesAndNewlines)
        let evaluator: Evaluator = Evaluator.shared
        evaluator.splitClient = self
        
        do {
            let result = try Evaluator.shared.evalTreatment(key: self.key.matchingKey, bucketingKey: self.key.bucketingKey, split: trimmedSplitName, attributes: attributes)
            if let splitVersion = result.splitVersion {
                logImpression(label: result.label, changeNumber: splitVersion, treatment: result.treatment, splitName: trimmedSplitName, attributes: attributes)
            } else {
                logImpression(label: result.label, treatment: result.treatment, splitName: trimmedSplitName, attributes: attributes)
            }
            return SplitResult(treatment: result.treatment, config: result.configuration)
        }
        catch {
            logImpression(label: ImpressionsConstants.EXCEPTION, treatment: SplitConstants.CONTROL, splitName: trimmedSplitName, attributes: attributes)
            return SplitResult(treatment: SplitConstants.CONTROL)
        }
    }
    
    func logImpression(label: String, changeNumber: Int64? = nil, treatment: String, splitName: String, attributes:[String:Any]? = nil) {
        let impression: Impression = Impression()
        impression.keyName = self.key.matchingKey
        
        impression.bucketingKey = (self.shouldSendBucketingKey) ? self.key.bucketingKey : nil
        impression.label = label
        impression.changeNumber = changeNumber
        impression.treatment = treatment
        impression.time = Date().unixTimestampInMiliseconds()
        splitImpressionManager.appendImpression(impression: impression, splitName: splitName)
        
        if let externalImpressionHandler = config?.impressionListener {
            impression.attributes = attributes
            externalImpressionHandler(impression)
        }
    }
}

// MARK: Track Events
extension DefaultSplitClient {
    
    public func track(trafficType: String, eventType: String) -> Bool {
        return track(eventType: eventType, trafficType: trafficType)
    }
    
    public func track(trafficType: String, eventType: String, value: Double) -> Bool {
        return track(eventType: eventType, trafficType: trafficType, value: value)
    }
    
    public func track(eventType: String) -> Bool {
        return track(eventType: eventType, trafficType: nil)
    }
    
    public func track(eventType: String, value: Double) -> Bool {
        return track(eventType: eventType, trafficType: nil, value: value)
    }
    
    private func track(eventType: String, trafficType: String? = nil, value: Double? = nil) -> Bool {
        
        if let errorInfo = eventValidator.validate(key: self.key.matchingKey, trafficTypeName: trafficType, eventTypeId: trafficType, value: value) {
            validationLogger.log(errorInfo: errorInfo, tag: "track")
            if errorInfo.isError {
                return false
            }
        }
        
        let event = EventDTO(trafficType: trafficType!.lowercased(), eventType: eventType)
        event.key = self.key.matchingKey
        event.value = value
        event.timestamp = Date().unixTimestampInMiliseconds()
        trackEventsManager.appendEvent(event: event)
        
        return true
    }
}
