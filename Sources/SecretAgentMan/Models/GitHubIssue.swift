import Foundation

struct GitHubIssue: Identifiable, Equatable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: String
    let authorLogin: String
    let authorAvatarURL: URL?
    let labels: [IssueLabel]
    let commentCount: Int
    let createdAt: Date
    let updatedAt: Date
}

struct IssueLabel: Equatable, Hashable {
    let name: String
    let color: String
}

struct IssueComment: Identifiable, Equatable {
    let id: String
    let authorLogin: String
    let authorAvatarURL: URL?
    let body: String
    let createdAt: Date
}

enum IssueSection: String, CaseIterable {
    case assigned = "Assigned to me"
    case mentioned = "Mentioning me"
    case authored = "Created by me"
}
