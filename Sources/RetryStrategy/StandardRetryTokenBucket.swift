import Foundation
import OSLog

class SystemTimeSource: TimeSource {
    func now() -> TimeInterval {
        return Date().timeIntervalSince1970
    }
}

protocol RetryTokenBucket {
    func acquireToken() async throws -> RetryToken
    func acquireToken(retryToken: RetryToken, retryError: RetryErrorType) async throws -> RetryToken
    func returnToken(retryToken: RetryToken)
}

class StandardRetryTokenBucket: RetryTokenBucket {
    struct Configuration {
        let initialRetryCost: Int
        let initialRetrySuccessIncrement: Int
        let maxCapacity: Int
        let retryCost: Int
        let timeoutRetryCost: Int
        var refillUnitsPerSecond: Int  {
            willSet {
                if newValue == 0 {
                    useCircuitBreaker = true
                }
            }
        }
        var useCircuitBreaker: Bool

        init(
            initialRetryCost: Int = 0,
            initialRetrySuccessIncrement: Int = 1,
            maxCapacity: Int = 500,
            retryCost: Int = 5,
            timeoutRetryCost: Int = 10,
            refillUnitsPerSecond: Int = 10,
            useCircuitBreaker: Bool = true
        ) {
            self.initialRetryCost = initialRetryCost
            self.initialRetrySuccessIncrement = initialRetrySuccessIncrement
            self.maxCapacity = maxCapacity
            self.retryCost = retryCost
            self.timeoutRetryCost = timeoutRetryCost
            self.refillUnitsPerSecond = refillUnitsPerSecond
            self.useCircuitBreaker = useCircuitBreaker
        }
    }

    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "StandardRetryTokenBucket")
    let configuration: Configuration
    let timeSource: TimeSource
    let sleeper: Sleeper
    var lastTimeMark: TimeInterval = 0.0
    var capacity: Int = 0

    init(configuration: Configuration, timeSource: TimeSource, sleeper: Sleeper) {
        self.configuration = configuration
        self.timeSource = timeSource
        self.lastTimeMark = timeSource.now()
        self.sleeper = sleeper
        self.capacity = configuration.maxCapacity
    }

    func acquireToken() async throws -> RetryToken {
        logger.info("Acquiring initial token")
        try await checkoutCapacity(size: configuration.initialRetryCost)
        return RetryToken(
            attempt: 0,
            size: configuration.initialRetrySuccessIncrement
        )
    }

    func acquireToken(retryToken: RetryToken, retryError: RetryErrorType) async throws -> RetryToken {
        logger.info("Acquiring token with retry error \(retryError) and retry count \(retryToken.attempt)")
        let size = switch retryError {
        case .transient, .throttling:
            configuration.timeoutRetryCost
        default:
            configuration.retryCost
        }

        try await checkoutCapacity(size: size)

        return RetryToken(
            attempt: retryToken.attempt + 1,
            size: size
        )
    }

    func returnToken(retryToken: RetryToken) {
        returnCapacity(size: retryToken.size ?? 0)
    }

    func returnCapacity(size: Int) {
        refillCapacity()

        capacity = min(configuration.maxCapacity, capacity + size)
        lastTimeMark = timeSource.now()
    }

    func checkoutCapacity(size: Int) async throws {
        logger.info("Checking out capacity of size \(size)")
        refillCapacity()

        if size <= capacity {
            logger.info("Capacity available, checking out \(size) units")
            capacity -= size
        } else {
            if configuration.useCircuitBreaker {
                logger.error("Retry capacity exceeded")
                throw RetryStrategyError.retryCapacityExceeded
            }

            let extraRequiredCapacity = size - capacity
            let delayDuration = ceil(Double(extraRequiredCapacity/configuration.refillUnitsPerSecond))
            capacity = 0
            logger.info("Capacity unavailable, delay for \(delayDuration) seconds")
            try await sleeper.sleep(seconds: delayDuration)
        }

        lastTimeMark = timeSource.now()
    }

    func refillCapacity() {
        let refillSeconds = timeSource.now() - lastTimeMark
        let refillSize = Int(floor(Double(configuration.refillUnitsPerSecond) * refillSeconds))
        logger.info("Refilling capacity by \(refillSize) units")
        capacity = min(configuration.maxCapacity, capacity + refillSize)
    }
}

protocol TimeSource {
    func now() -> TimeInterval
}

protocol Sleeper {
    func sleep(seconds: TimeInterval) async throws
}
