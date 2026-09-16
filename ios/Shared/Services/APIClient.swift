import Foundation

struct APIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL? = APIClient.configuredBaseURL, session: URLSession = .shared) throws {
        guard let baseURL else { throw APIClientError.invalidBaseURL }
        self.baseURL = baseURL
        self.session = session
        decoder = JSONDecoder.busWidget
    }

    func searchStations(query: String) async throws -> [StationSummary] {
        let response: StationSearchResponse = try await get(
            path: "/api/v1/stations/search",
            queryItems: [URLQueryItem(name: "q", value: query)]
        )
        return response.stations
    }

    func stationDetail(stationId: String) async throws -> StationDetailResponse {
        try await get(path: "/api/v1/stations/\(stationId)")
    }

    func arrivals(stationId: String, routeIds: [String]) async throws -> ArrivalsResponse {
        let routeValue = routeIds.isEmpty ? nil : routeIds.joined(separator: ",")
        return try await get(
            path: "/api/v1/stations/\(stationId)/arrivals",
            queryItems: [URLQueryItem(name: "route_ids", value: routeValue)]
        )
    }

    func liveActivitiesAvailable() async throws -> Bool {
        struct Availability: Decodable { let available: Bool }
        let result: Availability = try await get(path: "/api/v1/live-activities/availability")
        return result.available
    }

    func registerLiveWait(
        secret: String, stationId: String, routeId: String, pushToken: String, environment: String
    ) async throws -> LiveWaitRegistration {
        let body = try JSONSerialization.data(withJSONObject: [
            "station_id": stationId, "route_id": routeId, "push_token": pushToken, "environment": environment
        ])
        return try await get(path: "/api/v1/live-activities", method: "POST", body: body, secret: secret)
    }

    func endLiveWait(secret: String) async throws {
        let _: LiveWaitRegistration = try await get(path: "/api/v1/live-activities", method: "DELETE", secret: secret)
    }

    private func get<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        secret: String? = nil
    ) async throws -> Response {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw APIClientError.invalidBaseURL
        }
        components.queryItems = queryItems.filter { $0.value != nil }
        guard let url = components.url else { throw APIClientError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIClientError.transport
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            if let envelope = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                throw APIClientError.server(code: envelope.error.code, message: envelope.error.message)
            }
            throw APIClientError.invalidResponse
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIClientError.invalidResponse
        }
    }

    static var configuredBaseURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String else { return nil }
        return URL(string: value)
    }
}
