import Foundation

/// 所有打到 app.folia-api.top 的请求都基于这里。
enum APIClient {
    static let baseURL = URL(string: "https://app.folia-api.top")!

    enum APIError: Error {
        case badStatus(Int, String?)
        case decoding(Error)
        case transport(Error)
        case notLoggedIn
    }

    /// GET 请求；网易云特有：把 Cookie 以 `?cookie=` 形式拼到 URL 末尾（Web 端常用做法）。
    static func get(_ path: String, query: [String: String] = [:], provider: Provider, cookie: String?) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let cookie, !cookie.isEmpty {
            // Worker 的网易云链把 `cookie` 当查询参数透传给上游。
            items.append(URLQueryItem(name: "cookie", value: cookie))
        }
        components.queryItems = items.isEmpty ? nil : items

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("FoliaNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw APIError.badStatus(-1, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(400), encoding: .utf8)
            throw APIError.badStatus(http.statusCode, body)
        }
        return data
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}
