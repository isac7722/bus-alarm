import Foundation

struct APIErrorEnvelope: Codable, Sendable {
    struct Detail: Codable, Sendable {
        let code: String
        let message: String
    }

    let error: Detail
}

enum APIClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidResponse
    case server(code: String, message: String)
    case transport

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "서버 주소가 설정되지 않았습니다."
        case .invalidResponse:
            return "서버 응답을 처리할 수 없습니다."
        case let .server(_, message):
            return message
        case .transport:
            return "네트워크 연결을 확인한 뒤 다시 시도해 주세요."
        }
    }
}

