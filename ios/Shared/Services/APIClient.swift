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

    func routeMapAvailable() async throws -> Bool {
        struct Capabilities: Decodable { let routeMap: Bool }
        let result: Capabilities = try await get(path: "/api/v2/capabilities")
        return result.routeMap
    }

    func searchRoutes(query: String) async throws -> CatalogSearchResponse {
        try await get(path: "/api/v2/routes/search", queryItems: [URLQueryItem(name: "q", value: query)])
    }

    func routeDetail(ref: String) async throws -> CatalogDetail {
        try await get(path: "/api/v2/routes/\(ref)")
    }

    func routeGeometry(ref: String) async throws -> RouteGeometry {
        try await get(path: "/api/v2/routes/\(ref)/geometry")
    }

    func resolveStation(id: String) async throws -> MapStation {
        try await get(path: "/api/v2/stations/resolve", queryItems: [URLQueryItem(name: "id", value: id)])
    }

    func boardingOptions(stationRef: String, routeRef: String? = nil) async throws -> BoardingOptions {
        try await get(path: "/api/v2/stations/\(stationRef)/boarding-options", queryItems: [URLQueryItem(name: "route_ref", value: routeRef)])
    }

    func validateSelection(stationRef: String, selections: [BoardingSelection]) async throws -> ValidatedSelection {
        try await get(path: "/api/v2/selections/validate", method: "POST",
                      body: JSONEncoder.busWidget.encode(SelectionRequest(stationRef: stationRef, selections: selections)))
    }

    func arrivals(configuration: WidgetConfigurationData, routeId: String? = nil) async throws -> ArrivalsResponse {
        if configuration.version == 2, let selections = configuration.selections {
            let requested = routeId.map { id in selections.filter { $0.routeRef == id } } ?? selections
            return try await get(path: "/api/v2/arrivals", method: "POST",
                                 body: JSONEncoder.busWidget.encode(SelectionRequest(stationRef: configuration.stationId, selections: requested)))
        }
        return try await arrivals(stationId: configuration.stationId, routeIds: routeId.map { [$0] } ?? configuration.routeIds)
    }

    func registerBoardingWait(secret: String, stationRef: String, boarding: BoardingSelection,
                              pushToken: String, environment: String) async throws -> LiveWaitRegistration {
        struct Registration: Encodable {
            let stationId: String
            let routeId: String
            let boarding: BoardingSelection
            let pushToken: String
            let environment: String
        }
        let body = try JSONEncoder.busWidget.encode(Registration(stationId: stationRef, routeId: boarding.routeRef,
                                                                 boarding: boarding, pushToken: pushToken, environment: environment))
        return try await get(path: "/api/v2/live-activities", method: "POST", body: body, secret: secret)
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
        let filteredItems = queryItems.filter { $0.value != nil }
        components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        guard let url = components.url else { throw APIClientError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let secret { request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = path.hasPrefix("/api/v2/") ? 30 : 8
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_SUITE"] != nil,
           let value = ProcessInfo.processInfo.environment["BUS_WIDGET_TEST_API_URL"] {
            return URL(string: value)
        }
        #endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String else { return nil }
        return URL(string: value)
    }
}
