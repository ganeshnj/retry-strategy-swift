import Foundation
import OSLog

/// Protocol which inspects the response and error, and returns a RetryErrorInfo if the request should be retried.
protocol RetryPolicy {
    /// Evaluates whether the request should be retried.
    /// - Parameters:
    ///   - token: The RetryToken used to make the request.
    ///   - errorInfo: The RetryErrorInfo returned by the request.
    /// - Returns: true if the request should be retried, false otherwise.
    func retry(token: RetryToken, errorInfo: RetryErrorInfo) -> Bool
}

struct ErrorTypePolicy: RetryPolicy {
    let errorTypes: Set<RetryErrorType>
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "ErrorTypePolicy")

    init(errorTypes: Set<RetryErrorType>) {
        self.errorTypes = errorTypes
    }

    func retry(token: RetryToken, errorInfo: RetryErrorInfo) -> Bool {
        logger.info("Checking if error type \(errorInfo.errorType) is in \(errorTypes)")
        return errorTypes.contains(errorInfo.errorType)
    }
}
