import XCTest
@testable import RetryStrategy

final class StandardRetryerTests: XCTestCase {
    func testParallelExecution() async throws  {
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest

        // Defining Test Cases and Test Methods
        // https://developer.apple.com/documentation/xctest/defining_test_cases_and_test_methods

        // make 10 requests in parallel

        let group = DispatchGroup()
        for index in 0..<10 {
            group.enter()
            Task {
                defer { group.leave() }
                try await makeRequest(id: "Task \(index)")
            }
        }
        _ = group.wait(timeout: .now() + 10)
    }

    func makeRequest(id: String) async throws {
        let tokenBucket = StandardRetryTokenBucket(configuration: .init())
        let delayProvider = ExponentialBackoffWithJitter(configuration: .init())
        let retryStrategy = StandardRetryStrategy(tokenBucket: tokenBucket, delayProvider: delayProvider)
        let retryer = StandardRetryer(tokenBucket: tokenBucket, delayProvider: delayProvider, retryStrategy: retryStrategy, partiion: id)


        let (data, _) = try await retryer.execute {
            let session = URLSession.shared
            let url = URL(string: "https://httpbin.org/get")!
            let (data, response) = try await session.data(from: url)
            let httpResponse = response as! HTTPURLResponse
            if httpResponse.statusCode != 200 {
                throw HTTPError(response: httpResponse, error: nil)
            }
            return (data, response)
        }
        let prettyJson = try JSONSerialization.jsonObject(with: data, options: .mutableContainers)
        print(prettyJson)
    }
}
