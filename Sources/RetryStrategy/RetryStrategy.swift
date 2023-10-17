import Foundation
import OSLog

protocol RetryStrategy {
    func acquireInitialToken(partition: String) async throws -> RetryToken
    func recordSuccess(token: RetryToken)
    func refreshRetryToken(token: RetryToken, errorInfo: RetryErrorInfo) async throws -> RetryToken
    var maxAttempts: Int { get }
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
    let retryPolicies: [RetryPolicy]
    let maxAttempts: Int

    init(
        tokenBucket: RetryTokenBucket,
        delayProvider: DelayProvider,
        maxAttempts: Int) {
        self.tokenBucket = tokenBucket
        self.maxAttempts = maxAttempts
        self.retryPolicies = [
            MaxAttemptPolicy(maxAttempts: maxAttempts),
            ErrorTypePolicy(errorTypes: [.transient, .throttling])
        ]
    }

    func acquireInitialToken(partition: String) async throws -> RetryToken {
        logger.info("Acquiring initial token with partition \(partition)")
        return try await tokenBucket.acquireToken()
    }

    func recordSuccess(token: RetryToken) {
        logger.info("Recording success for token with retry count \(token.attempt)")
        tokenBucket.returnToken(retryToken: token)
    }

    func refreshRetryToken(token: RetryToken, errorInfo: RetryErrorInfo) async throws -> RetryToken {
        logger.info("Refreshing retry token with error type \(errorInfo.errorType)")

        if shouldRetry(tokenToRenew: token, errorInfo: errorInfo) {
            return try await tokenBucket.acquireToken(retryToken: token, retryError: errorInfo.errorType)
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
    let attempt: Int
    let size: Int?
}

protocol RetryBackoffStrategy {
    func computeNextBackoffDelay(attempts: Int) -> TimeInterval
}
