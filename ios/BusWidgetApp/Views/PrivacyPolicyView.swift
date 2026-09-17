import SwiftUI

private struct PrivacyPolicy: Decodable {
    struct Section: Decodable {
        let title: String
        let paragraphs: [String]
    }

    let title: String
    let effectiveDate: String
    let contactEmail: String
    let sections: [Section]

    static func load() throws -> PrivacyPolicy {
        guard let url = Bundle.main.url(forResource: "privacy", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(PrivacyPolicy.self, from: Data(contentsOf: url))
    }
}

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    private let policy = try? PrivacyPolicy.load()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.spacingLarge) {
                    if let policy {
                        Text("시행일: \(policy.effectiveDate)")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)

                        ForEach(policy.sections.indices, id: \.self) { index in
                            let section = policy.sections[index]
                            VStack(alignment: .leading, spacing: AppTheme.spacingSmall) {
                                Text(section.title)
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.paragraphs, id: \.self) { paragraph in
                                    Text(paragraph)
                                }
                            }
                        }

                        if let url = URL(string: "mailto:\(policy.contactEmail)") {
                            Link(destination: url) {
                                Label("문의: \(policy.contactEmail)", systemImage: "envelope")
                            }
                            .frame(minHeight: 44).foregroundStyle(AppTheme.action)
                        }
                    } else {
                        Text("개인정보처리방침을 불러오지 못했습니다. 아래 웹페이지에서 확인해 주세요.")
                    }

                    Link("웹에서 개인정보처리방침 보기", destination: URL(string: "https://bus.pangjoong.com/privacy")!)
                        .frame(minHeight: 44).foregroundStyle(AppTheme.action)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppTheme.spacingLarge)
                .textSelection(.enabled)
            }
            .background(AppTheme.background).foregroundStyle(AppTheme.text).tint(AppTheme.action)
            .navigationTitle(policy?.title ?? "개인정보처리방침")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}

struct PrivacyPolicyButton: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("개인정보처리방침", systemImage: "hand.raised")
        }
        .sheet(isPresented: $isPresented) {
            PrivacyPolicyView()
        }
    }
}
