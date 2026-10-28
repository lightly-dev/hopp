import Foundation

public struct AppEntry: Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    /// The bundle's file name when the localized name differs, e.g. "Calculator" for 计算器.
    public let alternateName: String?
    public let bundleID: String?
    public var id: String { path }

    public init(path: String, name: String, alternateName: String? = nil, bundleID: String? = nil) {
        self.path = path
        self.name = name
        self.alternateName = alternateName
        self.bundleID = bundleID
    }
}

public enum AppSearch {
    public struct Match {
        public let app: AppEntry
        public let nameRanges: [NSRange]
        fileprivate let score: Int
    }

    public static func filter(_ apps: [AppEntry], query: String) -> [Match] {
        var matches: [(match: Match, index: Int)] = []
        for (index, app) in apps.enumerated() {
            if let match = match(app, query: query) {
                matches.append((match, index))
            }
        }
        matches.sort {
            $0.match.score == $1.match.score ? $0.index < $1.index : $0.match.score > $1.match.score
        }
        return matches.map(\.match)
    }

    /// Each token must match the name or the alternate name; only name matches are highlighted.
    public static func match(_ app: AppEntry, query: String) -> Match? {
        var nameRanges: [NSRange] = []
        var score = 0
        for token in query.split(whereSeparator: \.isWhitespace) {
            let name = WindowSearch.matchText(app.name, token: String(token))
            let alternate = app.alternateName.flatMap { WindowSearch.matchText($0, token: String(token)) }
            guard name != nil || alternate != nil else { return nil }
            nameRanges += name?.ranges ?? []
            score += max(name?.score ?? Int.min, alternate?.score ?? Int.min)
        }
        return Match(app: app, nameRanges: nameRanges, score: score)
    }
}
