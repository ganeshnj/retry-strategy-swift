import XCTest
@testable import RetryStrategy

final class StandardRetryerTests: XCTestCase {
    func testParallelExecution() async throws  {
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
    
    func testSingle() async throws  {
        try await makeRequest(id: "Single")
    }

    func makeRequest(id: String) async throws {
        let tokenBucket = StandardRetryTokenBucket(configuration: .init())
        let delayProvider = ExponentialBackoffWithJitter(configuration: .init())
        let retryStrategy = StandardRetryStrategy(tokenBucket: tokenBucket, delayProvider: delayProvider, maxAttempts: 3)
        let retryer = StandardRetryer(tokenBucket: tokenBucket, delayProvider: delayProvider, retryStrategy: retryStrategy, partition: id)


        let (data, _) = try await retryer.execute { retryInfo in
            let session = URLSession.shared
            let url = URL(string: "https://httpbin.org/get")!
            var request = URLRequest(url: url)

            // for illustration purposes only
            request.addValue("attempt=\(retryInfo.attempt + 1); max=\(retryInfo.maxAttempts)", forHTTPHeaderField: "X-Attempt")

            let (data, response) = try await session.data(for: request)
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
