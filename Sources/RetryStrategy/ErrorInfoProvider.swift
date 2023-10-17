//
//  File.swift
//  
//
//  Created by Ganesh Jangir on 17/10/2023.
//
import Foundation
import OSLog

protocol ErrorInfoProvider {
    func errorInfo(response: HTTPURLResponse?, error: Error) -> RetryErrorInfo?
}

struct StandardErrorInfoProvider: ErrorInfoProvider {
    func errorInfo(response: HTTPURLResponse?, error: Error) -> RetryErrorInfo? {
        guard let response = response else {
            return nil
        }
        let retryAfter = retryAfterHint(response: response)
        let errorType = errorType(response: response, error: error)
        return RetryErrorInfo(errorType: errorType, retryAfterHint: retryAfter)
    }

    private func errorType(response: HTTPURLResponse, error: Error) -> RetryErrorType {
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

    private func isClockSkewError(response: HTTPURLResponse, erorr: Error) -> Bool {
        return false
    }

    private func isTransientError(response: HTTPURLResponse, error: Error) -> Bool {
        switch response.statusCode {
            case 500, 502, 503, 504:
                return true
            default:
                return false
        }
    }

    private func isServerError(response: HTTPURLResponse, error: Error) -> Bool {
        if response.statusCode >= 500
            && response.statusCode < 600 && !isTransientError(response: response, error: error) {
            return true
        }
        return false
    }

    private func isThrottlingError(response: HTTPURLResponse, error: Error) -> Bool {
        response.statusCode == 429
    }

    private func retryAfterHint(response: HTTPURLResponse) -> TimeInterval {
        response.allHeaderFields["Retry-After"] as? TimeInterval ?? 0
    }
}
