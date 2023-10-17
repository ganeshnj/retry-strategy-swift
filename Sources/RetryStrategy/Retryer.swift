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
    let partition: String
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "StandardRetryer")

    init(tokenBucket: RetryTokenBucket,
         delayProvider: DelayProvider,
         retryStrategy: RetryStrategy,
         errorInfoProvider: ErrorInfoProvider = StandardErrorInfoProvider(),
         partition: String) {
        self.tokenBucket = tokenBucket
        self.delayProvider = delayProvider
        self.retryStrategy = retryStrategy
        self.partition = partition
        self.errorInfoProvider = errorInfoProvider
    }

    func execute<Result>(block: (RetryInformation) async throws -> Result) async throws -> Result {
        var retryToken = try await retryStrategy.acquireInitialToken(partition: partition)
        var attempts = 0
        
        while true {
            do {
                logger.info("Executing block with retry count \(retryToken.attempt)")
                let result = try await block(.init(attempt: retryToken.attempt, maxAttempts: retryStrategy.maxAttempts))
                retryStrategy.recordSuccess(token: retryToken)
                logger.info("Block executed successfully with retry count \(retryToken.attempt)")
                return result
            } catch let httpError as HTTPError {
                logger.error("Block failed with error \(httpError.error) and response \(httpError.response)")
                guard let retryErrorInfo = errorInfoProvider.errorInfo(response: httpError.response, error: httpError) else {
                    throw httpError
                }
                attempts += 1
                do {
                    retryToken = try await retryStrategy.refreshRetryToken(token: retryToken, errorInfo: retryErrorInfo)
                    logger.info("Retrying block with retry count \(retryToken.attempt)")
                } catch {
                    logger.error("Failed to refresh retry token with error \(error)")
                    throw httpError
                }
                let delay = retryToken.delay
                logger.info("Sleeping for \(delay) seconds")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

struct HTTPError: Error {
    let response: HTTPURLResponse?
    let error: Error?
}
