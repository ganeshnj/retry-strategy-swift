import Foundation
import OSLog

/// Protocol which is responsible for handling the retry logic.
protocol RetryStrategy {
    /// Acquires a RetryToken to use for a request.
    /// This method should be called before the first attempt for a code block
    /// - Returns: A RetryToken to use for the request.
    func acquireInitialToken() async throws -> RetryToken

    /// Records a successful attempt for a code block.
    /// This method should be called after a successful attempt for a code block.
    /// - Parameter token: The RetryToken used for the previous attempt.
    func recordSuccess(token: RetryToken)

    /// Refreshes a RetryToken to use for a request.
    /// - Parameters:
    ///   - token: The RetryToken used for the previous attempt.
    ///   - errorInfo: The RetryErrorInfo returned by the previous attempt.
    /// - Returns: A RetryToken to use for the request.
    func refreshRetryToken(token: RetryToken, errorInfo: RetryErrorInfo) async throws -> RetryToken
}

/// A type of error that may be retried.
enum RetryErrorType: Error {
    /// A connection level error such as a timeout or a connection failure.
    /// These errors can be retried for non-idempotent requests.
    case transient

    /// A server-indicated throttling error.
    case throttling

    /// A general server error.
    case server

    /// A general client error.
    case client
}

/// Information about the error that occurred.
struct RetryErrorInfo {
    /// The type of error that occurred.
    let errorType: RetryErrorType

    /// The number of seconds to wait before retrying the request.
    /// Usually indicated by the `Retry-After` header in the response.
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
            ErrorTypePolicy(errorTypes: [.transient, .throttling])
        ]
    }

    func acquireInitialToken() async throws -> RetryToken {
        logger.info("Acquiring initial token")
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
