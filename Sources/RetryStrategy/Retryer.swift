import Foundation
import OSLog

protocol Retryer {
    func execute<Result>(block: () async throws -> Result) async throws -> Result
}

struct StandardRetryer: Retryer {
    let tokenBucket: StandardRetryTokenBucket
    let delayProvider: ExponentialBackoffWithJitter
    let retryStrategy: StandardRetryStrategy
    let partition: String
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "StandardRetryer")

    init(tokenBucket: StandardRetryTokenBucket,
         delayProvider: ExponentialBackoffWithJitter,
         retryStrategy: StandardRetryStrategy,
         partiion: String) {
        self.tokenBucket = tokenBucket
        self.delayProvider = delayProvider
        self.retryStrategy = retryStrategy
        self.partition = partiion
    }

    func execute<Result>(block: () async throws -> Result) async throws -> Result {
        var retryToken = try await retryStrategy.acquireInitialToken(partition: partition)
        var attempts = 0

        while true {
            do {
                logger.info("Executing block with retry count \(retryToken.attempt)")
                let result = try await block()
                retryStrategy.recordSuccess(token: retryToken)
                logger.info("Block executed successfully with retry count \(retryToken.attempt)")
                return result
            } catch let httpError as HTTPError {
                logger.error("Block failed with error \(httpError.error) and response \(httpError.response)")
                guard let retryErrorInfo = errorInfo(response: httpError.response, error: httpError) else {
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

    func errorType(response: HTTPURLResponse, error: Error) -> RetryErrorType {
        if isThrottlingError(response: response, error: error) {
            return .throttling
        }

        if isTransientError(response: response, error: error) {
            return .transient
        }

        if isServerError(response: response, error: error) {
            return .server
        }

        return .client
    }

    func isClockSkewError(response: HTTPURLResponse, erorr: Error) -> Bool {
        return false
    }

    func isTransientError(response: HTTPURLResponse, error: Error) -> Bool {
        switch response.statusCode {
            case 500, 502, 503, 504:
                return true
            default:
                return false
        }
    }

    func isServerError(response: HTTPURLResponse, error: Error) -> Bool {
        if response.statusCode >= 500
            && response.statusCode < 600 && !isTransientError(response: response, error: error) {
            return true
        }
        return false
    }

    func isThrottlingError(response: HTTPURLResponse, error: Error) -> Bool {
        response.statusCode == 429
    }

    func errorInfo(response: HTTPURLResponse?, error: Error) -> RetryErrorInfo? {
        guard let response = response else {
            return nil
        }
        let retryAfter = retryAfterHint(response: response)
        let errorType = errorType(response: response, error: error)
        return RetryErrorInfo(errorType: errorType, retryAfterHint: retryAfter)
    }

    func retryAfterHint(response: HTTPURLResponse) -> TimeInterval {
        response.allHeaderFields["Retry-After"] as? TimeInterval ?? 0
    }
}

struct HTTPError: Error {
    let response: HTTPURLResponse?
    let error: Error?
}
