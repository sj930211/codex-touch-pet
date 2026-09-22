import Foundation

struct RecentThread {
    let id: String
    let title: String
}

struct RecentThreadProvider {
    private let fileManager = FileManager.default

    func recentThreadIDs(limit: Int = 20) -> [String] {
        recentThreads(limit: limit).map(\.id)
    }

    func recentThreads(limit: Int = 20) -> [RecentThread] {
        var result: [String] = []

        guard let database = stateDatabasePath() else {
            return uniqueThreads(result.map(parseThread))
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let safeLimit = max(1, min(limit, 100))
        process.arguments = [
            "-readonly",
            database,
            "SELECT id || char(9) || replace(replace(title, char(9), ' '), char(10), ' ') " +
                "FROM threads WHERE archived = 0 " +
                "AND (source IS NULL OR source NOT LIKE '%\"subagent\"%') " +
                "ORDER BY recency_at_ms DESC LIMIT \(safeLimit);"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return uniqueThreads(result.map(parseThread)) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                return uniqueThreads(result.map(parseThread))
            }
            for line in output.split(whereSeparator: \Character.isNewline) {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !result.contains(value) {
                    result.append(value)
                }
            }
        } catch {
            return uniqueThreads(result.map(parseThread))
        }
        return uniqueThreads(result.map(parseThread))
    }

    func filteredInternalThreadCount() -> Int? {
        guard let database = stateDatabasePath() else { return nil }
        let output = runSQLite(
            database: database,
            query: "SELECT count(*) FROM threads WHERE archived = 0 " +
                "AND source LIKE '%\"subagent\"%';"
        )
        return output.flatMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func parseThread(_ value: String) -> RecentThread {
        let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        let id = parts.first.map(String.init) ?? value
        let title = parts.count > 1 ? String(parts[1]) : ""
        return RecentThread(id: id, title: title)
    }

    private func uniqueThreads(_ threads: [RecentThread]) -> [RecentThread] {
        var seen = Set<String>()
        return threads.filter { seen.insert($0.id).inserted }
    }

    private func stateDatabasePath() -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.codex/state_5.sqlite",
            "\(home)/.codex/sqlite/state_5.sqlite"
        ]
        return candidates.first(where: fileManager.fileExists(atPath:))
    }

    private func runSQLite(database: String, query: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", database, query]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
