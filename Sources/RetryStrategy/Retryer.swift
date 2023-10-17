import Foundation
import OSLog

protocol Retryer {
    func execute<Result>(block: (RetryInformation) async throws -> Result) async throws -> Result
}

struct RetryInformation {
    let attempt: Int
    let maxAttempts: Int
}

struct StandardRetryer: Retryer {
    let tokenBucket: RetryTokenBucket
    let delayProvider: DelayProvider
    let retryStrategy: RetryStrategy
    let errorInfoProvider: ErrorInfoProvider
    let sleeper: Sleeper
    let partition: String
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "StandardRetryer")

    init(tokenBucket: RetryTokenBucket,
         delayProvider: DelayProvider,
         retryStrategy: RetryStrategy,
         errorInfoProvider: ErrorInfoProvider = StandardErrorInfoProvider(),
         sleeper: Sleeper,
         partition: String) {
        self.tokenBucket = tokenBucket
        self.delayProvider = delayProvider
        self.retryStrategy = retryStrategy
        self.partition = partition
        self.errorInfoProvider = errorInfoProvider
        self.sleeper = sleeper
    }

    func execute<Result>(block: (RetryInformation) async throws -> Result) async throws -> Result {
        var retryToken = try await retryStrategy.acquireInitialToken(partition: partition)
        let initialDelay = try await delayProvider.backoff(attempt: retryToken.attempt)
        logger.info("Sleeping for \(initialDelay) seconds; attempt \(retryToken.attempt)")
        try await sleeper.sleep(seconds: initialDelay)

        while true {
            do {
                logger.info("Executing block; attempt \(retryToken.attempt)")
                let result = try await block(.init(attempt: retryToken.attempt, maxAttempts: retryStrategy.maxAttempts))
                retryStrategy.recordSuccess(token: retryToken)
                logger.info("Block executed successfully; attempt \(retryToken.attempt)")
                return result
            } catch let httpError as HTTPError {
                logger.error("Block failed with error \(httpError.error) and response \(httpError.response)")
                guard let retryErrorInfo = errorInfoProvider.errorInfo(response: httpError.response, error: httpError) else {
                    throw httpError
                }

                do {
                    retryToken = try await retryStrategy.refreshRetryToken(token: retryToken, errorInfo: retryErrorInfo)
                    logger.info("Retrying block; attempt \(retryToken.attempt)")
                } catch {
                    logger.error("Failed to refresh retry token; error \(error)")
                    throw httpError
                }
                let retryDelay = try await delayProvider.backoff(attempt: retryToken.attempt)
                let delay = max(retryDelay, retryErrorInfo.retryAfterHint ?? 0)
                logger.info("Sleeping for \(delay) seconds; attempt \(retryToken.attempt)")
                try await sleeper.sleep(seconds: retryDelay)
            }
        }
    }
}

struct HTTPError: Error {
    let response: HTTPURLResponse?
    let error: Error?
}
