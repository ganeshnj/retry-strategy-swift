import Foundation
import OSLog

/// High-level protocol which executes a block of code, and retries it if it fails.
protocol Retryer {
    /// Executes a block of code, and retries it if it fails.
    /// - Parameter block: The block of code to execute.
    ///                    The block accepts a RetryInformation object, which contains information about the current retry attempt.
    ///                    This information can be used to attach additional information to the request.
    /// - Returns: The result of the block of code.
    func execute<Result>(block: (RetryInformation) async throws -> Result) async throws -> Result
}

/// Information about the current retry attempt.
struct RetryInformation {
    /// The number of times the block of code has been executed.
    let attempt: Int

    /// The maximum number of times the block of code will be executed.
    let maxAttempts: Int
}

struct StandardRetryer: Retryer {
    let tokenBucket: RetryTokenBucket
    let delayProvider: DelayProvider
    let retryStrategy: RetryStrategy
    let errorInfoProvider: ErrorInfoProvider
    let sleeper: Sleeper
    let maxAttempts: Int
    let attempt = 0
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "StandardRetryer")

    init(tokenBucket: RetryTokenBucket,
         delayProvider: DelayProvider,
         retryStrategy: RetryStrategy,
         errorInfoProvider: ErrorInfoProvider = StandardErrorInfoProvider(),
         sleeper: Sleeper,
         maxAttempts: Int = 3) {
        self.tokenBucket = tokenBucket
        self.delayProvider = delayProvider
        self.retryStrategy = retryStrategy
        self.errorInfoProvider = errorInfoProvider
        self.sleeper = sleeper
        self.maxAttempts = maxAttempts
    }

    func execute<Result>(block: (RetryInformation) async throws -> Result) async throws -> Result {
        var retryToken = try await retryStrategy.acquireInitialToken()
        let initialDelay = try await delayProvider.backoff(attempt: retryToken.attempt)
        logger.info("Sleeping for \(initialDelay) seconds; attempt \(retryToken.attempt)")
        try await sleeper.sleep(seconds: initialDelay)

        while true {
            do {
                logger.info("Executing block; attempt \(retryToken.attempt)")
                let result = try await block(.init(attempt: retryToken.attempt, maxAttempts: maxAttempts))
                retryStrategy.recordSuccess(token: retryToken)
                logger.info("Block executed successfully; attempt \(retryToken.attempt)")
                return result
            } catch let httpError as HTTPError {
                // check if we exhausted the number of attempts
                guard attempt < maxAttempts else {
                    logger.info("Exhausted number of attempts; attempt \(attempt)")
                    throw RetryerError.exhaustedAttempts
                }

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

enum RetryerError: Error {
    case exhaustedAttempts
}

struct HTTPError: Error {
    let response: HTTPURLResponse?
    let error: Error?
}
