import Foundation
import OSLog

/// Protocol which provides a delay between invocations of a code block.
protocol DelayProvider {
    /// Returns the delay to wait before the next invocation of a code block.
    /// - Parameter attempt: The number of times the code block has been invoked.
    /// - Returns: The delay to wait before the next invocation of a code block.
    func backoff(attempt: Int) async throws -> TimeInterval
}

struct ExponentialBackoffWithJitter: DelayProvider {
    struct Configuration {
        let initialDelay: TimeInterval
        let jitter: Double
        let maxBackoff: TimeInterval
        let scaleFactor: Double

        init(
            initialDelay: TimeInterval =  0.01, // 10ms
            jitter: Double = 1.0,
            maxBackoff: TimeInterval = 20, // 20s
            scaleFactor: Double = 1.5) {
            self.initialDelay = initialDelay
            self.jitter = jitter
            self.maxBackoff = maxBackoff
            self.scaleFactor = scaleFactor
        }
    }

    let configuration: Configuration
    let logger = Logger(subsystem: "com.datadoghq.dd-sdk-ios", category: "ExponentialBackoffWithJitter")

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func backoff(attempt: Int) async throws -> TimeInterval {
        precondition(attempt >= 0, "Attempt must be greater than or equal to 0")

        let calculatedDelay = configuration.initialDelay * pow(configuration.scaleFactor, Double(attempt))
        let maxDelay = min(calculatedDelay, configuration.maxBackoff)
        let jitterProportion =  Double.random(in: 0...configuration.jitter)
        let delay = maxDelay * (1.0 - jitterProportion)
        logger.info("Backoff attempt \(attempt) with delay \(delay)")
        return delay
    }
}
