import Foundation
import OSLog

protocol RetryStrategy {
    func acquireInitialToken(partition: String) async throws -> RetryToken
    func recordSuccess(token: RetryToken)
    mutating func refreshRetryToken(token: RetryToken, errorInfo: RetryErrorInfo) async throws -> RetryToken
}

enum RetryErrorType: Error {
    case transient
    case throttling
    case server
    case client
}

struct RetryErrorInfo {
    let errorType: RetryErrorType
    let retryAfterHint: TimeInterval?
}

open class StandardRetryStrategy: RetryStrategy {
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "StandardRetryStrategy")
    let tokenBucket: RetryTokenBucket
    let delayProvider: DelayProvider
    let retryPolicies: [RetryPolicy]

    init(
        tokenBucket: RetryTokenBucket,
        delayProvider: DelayProvider) {
        self.tokenBucket = tokenBucket
        self.delayProvider = delayProvider
        self.retryPolicies = [
            MaxAttemptPolicy(maxAttempts: 3),
            ErrorTypePolicy(errorTypes: [.transient, .throttling])
        ]
    }

    func acquireInitialToken(partition: String) async throws -> RetryToken {
        logger.info("Acquiring initial token with partition \(partition)")
        let token = try await tokenBucket.acquireToken()
        let delayForFirstAttempt = try await delayProvider.backoff(attempt: token.attempt)
        logger.info("Sleeping for \(delayForFirstAttempt) seconds")
        try await Task.sleep(nanoseconds: UInt64(delayForFirstAttempt * 1_000_000_000))
        return token
    }

    func recordSuccess(token: RetryToken) {
        logger.info("Recording success for token with retry count \(token.attempt)")
        tokenBucket.returnToken(retryToken: token)
    }

    func refreshRetryToken(token: RetryToken, errorInfo: RetryErrorInfo) async throws -> RetryToken {
        logger.info("Refreshing retry token with error type \(errorInfo.errorType)")

        if shouldRetry(tokenToRenew: token, errorInfo: errorInfo) {
            let delayFromErrorType = try await delayProvider.backoff(attempt: token.attempt)
            let retryDelay = max(errorInfo.retryAfterHint ?? 0, delayFromErrorType)
            logger.info("Sleeping for \(retryDelay) seconds")
            try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            let refreshToken = try await tokenBucket.acquireToken(retryToken: token, retryError: errorInfo.errorType)
            return refreshToken
        }

        logger.info("No retry token available, throwing error")
        throw RetryStrategyError.retryCapacityExceeded
    }

    func shouldRetry(tokenToRenew: RetryToken, errorInfo: RetryErrorInfo) -> Bool {
        for policy in retryPolicies {
            logger.info("Checking retry policy \(type(of: policy))")
            if policy.retry(token: tokenToRenew, errorInfo: errorInfo) {
                return true
            }
        }
        return false
    }

    func retryableError(error: RetryErrorType) -> Bool {
        switch error {
        case .transient, .throttling:
            return true
        default:
            return false
        }
    }
}

enum RetryStrategyError: Error {
    case retryCapacityExceeded
}

struct RetryToken {
    let delay: TimeInterval
    let attempt: Int
    let size: Int?
}

protocol RetryBackoffStrategy {
    func computeNextBackoffDelay(attempts: Int) -> TimeInterval
}
