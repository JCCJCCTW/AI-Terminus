import Foundation

struct SSHHost: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var password: String
    var privateKeyPath: String
    var notes: String
    var group: String

    init(
        id: UUID = UUID(),
        name: String = "",
        hostname: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .password,
        password: String = "",
        privateKeyPath: String = "",
        notes: String = "",
        group: String = ""
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.notes = notes
        self.group = group
    }

    enum AuthMethod: String, Codable, CaseIterable {
        case password = "密碼"
        case privateKey = "私鑰"
        case agent = "SSH Agent"

        var localizedLabel: String {
            switch self {
            case .password:
                return localizedAppText("密碼", "Password")
            case .privateKey:
                return localizedAppText("私鑰", "Private Key")
            case .agent:
                return "SSH Agent"
            }
        }
    }

    var displayTitle: String {
        name.isEmpty ? hostname : name
    }

    var connectionLabel: String {
        port == 22 ? "\(username)@\(hostname)" : "\(username)@\(hostname):\(port)"
    }
}
