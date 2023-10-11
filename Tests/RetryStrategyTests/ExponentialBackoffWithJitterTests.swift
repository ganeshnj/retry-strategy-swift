import XCTest
@testable import RetryStrategy

final class ExponentialBackoffWithJitterTests: XCTestCase {
    func testScaling() async throws {
        let delayer = ExponentialBackoffWithJitter(
            configuration: .init(
                initialDelay: 0.01,
                jitter: 0.0,
                maxBackoff: TimeInterval.infinity,
                scaleFactor: 2.0
            )
        )

        let actual = try await backoffSeries(times: 6, delayer: delayer)
        let expected: [TimeInterval] = [0.01, 0.02, 0.04, 0.08, 0.16, 0.32]
        XCTAssertEqual(actual, expected)
    }

    func backoffSeries(times: Int, delayer: ExponentialBackoffWithJitter) async throws -> [TimeInterval] {
        let range = 0..<times
        var series: [TimeInterval] = []

        for attempt in range {
            let delay = try await delayer.backoff(attempt: attempt)
            series.append(delay)
        }

        return series
    }

    func testJitter() async throws {
        let delayer = ExponentialBackoffWithJitter(
            configuration: .init(
                initialDelay: 0.01,
                jitter: 0.6,
                maxBackoff: TimeInterval.infinity,
                scaleFactor: 2.0
            )
        )

        let actual = try await backoffSeries(times: 6, delayer: delayer)
        let expected: [(TimeInterval, TimeInterval)] = [
            (0.004, 0.010),
            (0.008, 0.020),
            (0.016, 0.040),
            (0.032, 0.080),
            (0.064, 0.160),
            (0.128, 0.320)
        ]
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual, expected.0, accuracy: expected.1)
        }
    }

    func testMaxBackoff() async throws {
        let delayer = ExponentialBackoffWithJitter(
            configuration: .init(
                initialDelay: 0.01,
                jitter: 0.0,
                maxBackoff: 0.1,
                scaleFactor: 2.0
            )
        )

        let actual = try await backoffSeries(times: 6, delayer: delayer)
        let expected: [TimeInterval] = [0.01, 0.02, 0.04, 0.08, 0.1, 0.1]
        XCTAssertEqual(actual, expected)
    }
}
