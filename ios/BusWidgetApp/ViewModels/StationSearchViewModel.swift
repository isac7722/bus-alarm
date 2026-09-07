import Foundation

@MainActor
final class StationSearchViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var query = ""
    @Published private(set) var stations: [StationSummary] = []
    @Published private(set) var state: State = .idle

    private let client: APIClient?
    private var searchTask: Task<Void, Never>?

    init(client: APIClient? = try? APIClient()) {
        self.client = client
    }

    func queryDidChange() {
        searchTask?.cancel()
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            stations = []
            state = .idle
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.search(normalized)
        }
    }

    func retry() {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.search(normalized)
        }
    }

    private func search(_ normalizedQuery: String) async {
        guard let client else {
            state = .failed(APIClientError.invalidBaseURL.localizedDescription)
            return
        }
        state = .loading
        do {
            stations = try await client.searchStations(query: normalizedQuery)
            state = .loaded
        } catch is CancellationError {
            return
        } catch {
            stations = []
            state = .failed(error.localizedDescription)
        }
    }
}

