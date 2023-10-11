import Foundation
import OSLog

protocol RetryPolicy {
    func retry(token: RetryToken, errorInfo: RetryErrorInfo) -> Bool
}

struct MaxAttemptPolicy: RetryPolicy {
    let maxAttempts: Int
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "MaxAttemptPolicy")

    init(maxAttempts: Int) {
        self.maxAttempts = maxAttempts
    }

    func retry(token: RetryToken, errorInfo: RetryErrorInfo) -> Bool {
        logger.info("Checking if retry count \(token.attempt) is less than max attempts \(maxAttempts)")
        return token.attempt < maxAttempts
    }
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
