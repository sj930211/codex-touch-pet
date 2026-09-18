import Foundation

struct RecentThreadProvider {
    private let fileManager = FileManager.default

    func recentThreadIDs(limit: Int = 20) -> [String] {
        var result: [String] = []
        if let current = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"], !current.isEmpty {
            result.append(current)
        }

        guard let database = stateDatabasePath() else {
            return result
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            database,
            "SELECT id FROM threads WHERE archived = 0 " +
                "AND (source IS NULL OR source NOT LIKE '%\"subagent\"%') " +
                "ORDER BY recency_at_ms DESC LIMIT \(limit);"
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return result }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return result }
            for line in output.split(whereSeparator: \Character.isNewline) {
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !result.contains(value) {
                    result.append(value)
                }
            }
        } catch {
            return result
        }
        return result
    }

    private func stateDatabasePath() -> String? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.codex/state_5.sqlite",
            "\(home)/.codex/sqlite/state_5.sqlite"
        ]
        return candidates.first(where: fileManager.fileExists(atPath:))
    }
}
