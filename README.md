Implements retry strategy for executing a code of block (this focuses on HTTP request).

It uses token bucket and exponential backoff algorithm with jitter to control the rate of retry.

It uses learnings of [AWS SDKs](https://docs.aws.amazon.com/general/latest/gr/api-retries.html)

Example usage

```swift
let tokenBucket = StandardRetryTokenBucket(configuration: .init())
let delayProvider = ExponentialBackoffWithJitter(configuration: .init())
let retryStrategy = StandardRetryStrategy(tokenBucket: tokenBucket, delayProvider: delayProvider)
let retryer = StandardRetryer(tokenBucket: tokenBucket, delayProvider: delayProvider, retryStrategy: retryStrategy, partition: "foobar")

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
```