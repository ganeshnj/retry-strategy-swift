import XCTest
@testable import RetryStrategy

class StandardRetryTokenBucketTest: XCTestCase {
    func testWaitForCapacity() async throws {
        let timeSource = TestTimeSource()
        let sleeper = TestSleeper(timeSource: timeSource)
        let bucket = tokenBucket(initialTryCost: 10, timeSource: timeSource, sleeper: sleeper)

        XCTAssertEqual(10, bucket.capacity)

        _ = try await bucket.acquireToken()
        XCTAssertEqual(0, bucket.capacity)
        XCTAssertEqual(0, timeSource.current)

        timeSource.current += 1
        XCTAssertEqual(1, timeSource.current)

        _ = try await bucket.acquireToken()
        XCTAssertEqual(0, bucket.capacity)
    }

    func testReturnCapacityOnSuccess() async throws {
        let timeSource = TestTimeSource()
        let sleeper = TestSleeper(timeSource: timeSource)
        let bucket = tokenBucket(initialTryCost: 5, initialTrySuccessIncrement: 3, timeSource: timeSource, sleeper: sleeper)

        XCTAssertEqual(10, bucket.capacity)

        let token = try await bucket.acquireToken()

        XCTAssertEqual(5, bucket.capacity)
        
        bucket.returnToken(retryToken: token)
        XCTAssertEqual(8, bucket.capacity)
    }

    func testNoCapacityChangeOnFailure() async throws {
        let timeSource = TestTimeSource()
        let sleeper = TestSleeper(timeSource: timeSource)
        let bucket = tokenBucket(initialTryCost: 1, timeSource: timeSource, sleeper: sleeper)

        XCTAssertEqual(10, bucket.capacity)

        _ = try await bucket.acquireToken()
        XCTAssertEqual(9, bucket.capacity)
    }

    func testRetryCapacityAdjustments() async throws {
        let costs = [
            RetryErrorType.throttling: 3,
            RetryErrorType.transient: 3,
            RetryErrorType.server: 2,
            RetryErrorType.client: 2
        ]

        for (errorType, cost) in costs {
            let timeSource = TestTimeSource()
            let sleeper = TestSleeper(timeSource: timeSource)
            let bucket = tokenBucket(timeSource: timeSource, sleeper: sleeper)
            XCTAssertEqual(10, bucket.capacity)

            let token = try await bucket.acquireToken()
            XCTAssertEqual(10, bucket.capacity)

            let _ = try await bucket.acquireToken(retryToken: token, retryError: errorType)
            XCTAssertEqual(10 - cost, bucket.capacity)
        }
    }

    func testRefillOverTime() async throws {
        let timeSource = TestTimeSource()
        let sleeper = TestSleeper(timeSource: timeSource)
        let bucket = tokenBucket(initialTryCost: 5, timeSource: timeSource, sleeper: sleeper)

        XCTAssertEqual(10, bucket.capacity)

        _ = try await bucket.acquireToken()
        XCTAssertEqual(5, bucket.capacity)

        // Refill rate is 10/s == 1/100ms so after 250ms we should have 2 more tokens.
        timeSource.current += 0.25

        _ = try await bucket.acquireToken()
        XCTAssertEqual(2, bucket.capacity)
    }

    func testCircuitBreakerMode() async throws {
        let timeSource = TestTimeSource()
        let sleeper = TestSleeper(timeSource: timeSource)
        let bucket = tokenBucket(useCircuitBreakerMode: true, initialTryCost: 10, timeSource: timeSource, sleeper: sleeper)

        XCTAssertEqual(10, bucket.capacity)

        let token = try await bucket.acquireToken()
        XCTAssertEqual(0, bucket.capacity)

        await XCTAssertThrowsError(try await bucket.acquireToken(retryToken: token, retryError: RetryErrorType.throttling),
                                   matching: RetryStrategyError.retryCapacityExceeded)
    }

    func tokenBucket(
        useCircuitBreakerMode: Bool = false,
        initialTryCost: Int = 0,
        initialTrySuccessIncrement: Int = 1,
        maxCapacity: Int = 10,
        refillUnitsPerSecond: Int = 10,
        retryCost: Int = 2,
        timeoutRetryCost: Int = 3,
        timeSource: TimeSource,
        sleeper: Sleeper
    ) -> StandardRetryTokenBucket {
        let configuration = StandardRetryTokenBucket.Configuration(
            initialRetryCost: initialTryCost,
            initialRetrySuccessIncrement: initialTrySuccessIncrement,
            maxCapacity: maxCapacity,
            retryCost: retryCost,
            timeoutRetryCost: timeoutRetryCost,
            refillUnitsPerSecond: refillUnitsPerSecond,
            useCircuitBreaker: useCircuitBreakerMode
        )
        return StandardRetryTokenBucket(configuration: configuration, timeSource: timeSource, sleeper: sleeper)
    }

}

protocol Delayer {
    func delay(delay: TimeInterval) async
}

class TestDelayer: Delayer {
    var timeSource: TestTimeSource

    init(timeSource: TestTimeSource) {
        self.timeSource = timeSource
    }

    func delay(delay: TimeInterval) async {
        timeSource.current += delay
    }
}

class TestTimeSource: TimeSource {
    var current: TimeInterval

    init(start: TimeInterval = 0) {
        current = start
    }
    func now() -> TimeInterval {
        return current
    }
}

class TestSleeper: Sleeper {
    var timeSource: TestTimeSource

    init(timeSource: TestTimeSource) {
        self.timeSource = timeSource
    }

    func sleep(seconds: TimeInterval) async {
        timeSource.current += seconds
    }
}

func XCTAssertThrowsError<T, E: Error>(_ expression: @autoclosure () async throws -> T, matching expectedError: E,
                                       file: StaticString = #filePath, line: UInt = #line) async where E: Equatable {
    do {
        _ = try await expression()
        XCTFail("Expected to throw error, but did not!", file: file, line: line)
    } catch {
        guard let error = error as? E else {
            XCTFail("An error was thrown, but it was not the right type!", file: file, line: line)
            return
        }

        XCTAssertEqual(expectedError, error, file: file, line: line)
    }
}
