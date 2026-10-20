import Foundation

enum ToolPropIdentity: Hashable {
    case application(String)
    case browser
    case computer
    case tool

    var label: String {
        switch self {
        case .application: return "已注册软件"
        case .browser: return "浏览器工具（目标未确认）"
        case .computer: return "电脑工具（目标未确认）"
        case .tool: return "通用工具"
        }
    }
}

struct ToolProp: Equatable {
    let identity: ToolPropIdentity
    var callCount: Int
}

/// Explicit local registrations only. Names of servers, foreground apps and
/// script contents are not evidence of a particular local application.
struct ToolApplicationRegistry {
    var servers: [String: String] = [:]
    var connectors: [String: String] = [:]

    static func local(defaults: UserDefaults = .standard) -> ToolApplicationRegistry {
        ToolApplicationRegistry(
            servers: defaults.dictionary(forKey: "toolServerApplications") as? [String: String] ?? [:],
            connectors: defaults.dictionary(forKey: "toolConnectorApplications") as? [String: String] ?? [:]
        )
    }

    func identity(type: String, server: String?, tool: String?, connector: String?) -> ToolPropIdentity {
        if let connector, let bundle = connectors[connector], Self.validBundleID(bundle) {
            return .application(bundle)
        }
        if let server, let bundle = servers[server], Self.validBundleID(bundle) {
            return .application(bundle)
        }
        if ["playwright", "chrome-devtools"].contains(server ?? "") || type == "webSearch" {
            return .browser
        }
        if ["cua_repl", "cua-repl"].contains(server ?? "")
            || tool == "mcp__cua_repl__js" || type == "computerUse" || type == "commandExecution" {
            return .computer
        }
        return .tool
    }

    private static func validBundleID(_ value: String) -> Bool {
        value.count <= 160 && value.contains(".")
            && value.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]+$", options: .regularExpression) != nil
    }
}

/// A bounded reducer for the observed Desktop IPC patch shapes, not a JSON
/// mirror. Only known turn/item containers and five metadata fields survive.
/// Owned by ThreadStatusStore on the main queue; never persists or logs IDs.
struct ToolCallTracker {
    private struct Key: Hashable { let thread: String; let id: String }
    private struct Location: Hashable { let thread: String; let path: [String] }
    private struct Item {
        var id: String?
        var type: String?
        var server: String?
        var tool: String?
        var connector: String?
        var status: String?
    }
    private struct Call {
        var item: Item
        let startedAt: Date
        var active: Bool
        var ended: Bool
    }

    static let lifetime: TimeInterval = 300
    private let capacity: Int
    private let registry: ToolApplicationRegistry
    private var items: [Location: Item] = [:]
    private var calls: [Key: Call] = [:]
    private var order: [Key] = []
    private(set) var saturated = false

    init(registry: ToolApplicationRegistry = .local(), capacity: Int = 2048) {
        self.registry = registry
        self.capacity = capacity
    }

    var retainedCount: Int { max(items.count, calls.count) }

    var nextExpiry: Date? {
        calls.values.filter { $0.active && !$0.ended }.map { $0.startedAt.addingTimeInterval(Self.lifetime) }.min()
    }

    mutating func reset() {
        items.removeAll(); calls.removeAll(); order.removeAll(); saturated = false
    }

    mutating func end(thread: String) {
        for key in calls.keys where key.thread == thread {
            calls[key]?.active = false
            calls[key]?.ended = true
        }
    }

    mutating func endAll() {
        for key in calls.keys {
            calls[key]?.active = false
            calls[key]?.ended = true
        }
    }

    mutating func expire(at date: Date) {
        for key in calls.keys where date.timeIntervalSince(calls[key]!.startedAt) >= Self.lifetime {
            calls[key]?.active = false
            calls[key]?.ended = true
        }
    }

    mutating func apply(patch: [String: Any], thread: String, at date: Date, historical: Bool = false) {
        guard !saturated, let rawPath = patch["path"] as? [Any], rawPath.count <= 20 else { return }
        let path = rawPath.map { String(describing: $0) }
        guard Self.safePath(path) else { return }
        let location = Location(thread: thread, path: path)
        if patch["op"] as? String == "remove" {
            var itemPath = Array(path.dropLast())
            if path.last == "connectorId", itemPath.last == "appContext" { itemPath.removeLast() }
            if ["appContext", "connectorId"].contains(path.last ?? ""), Self.isItemPath(itemPath) {
                merge(["appContext": [String: String]()], location: Location(thread: thread, path: itemPath), at: date, historical: historical)
                return
            }
            removeDescendants(of: location)
            shiftArrayLocations(at: location, inserting: false)
            return
        }
        let value = patch["value"]
        if patch["op"] as? String == "add", let dict = value as? [String: Any] {
            let duplicate = Self.token(dict["id"]).map { $0 == items[location]?.id } ?? false
            // Property-first delivery leaves an incomplete item at this
            // position. Completing it is not a new array insertion; in
            // particular a prior terminal status must keep precedence.
            let completingPartial = items[location] != nil && items[location]?.id == nil
            if !duplicate && !completingPartial { shiftArrayLocations(at: location, inserting: true) }
        }
        if path.last == "appContext", Self.isItemPath(Array(path.dropLast())), let context = value as? [String: Any] {
            merge(["appContext": context], location: Location(thread: thread, path: Array(path.dropLast())), at: date, historical: historical)
            return
        }
        // Scalar property patches can arrive before the full item. Retain a
        // terminal status, so a late inProgress cannot resurrect that item.
        if let property = path.last, ["id", "type", "server", "tool", "status", "connectorId"].contains(property) {
            var itemPath = Array(path.dropLast())
            if property == "connectorId", itemPath.last == "appContext" { itemPath.removeLast() }
            if Self.isItemPath(itemPath) {
                var fields: [String: Any] = [:]
                if let value { fields[property] = value }
                merge(fields, location: Location(thread: thread, path: itemPath), at: date, historical: historical)
            }
            return
        }
        // Collection replacements must also end calls absent from the new
        // collection. The traversal below only enumerates metadata locations.
        if patch["op"] as? String == "replace", !Self.isItemPath(path) {
            let incoming = itemLocations(in: value, at: location)
            for old in Array(items.keys) where old.thread == thread && old.path.starts(with: path)
                && !incoming.contains(old) {
                endItem(at: old)
            }
        }
        walk(value, at: location, date: date, historical: historical, depth: 0)
    }

    /// Strip content before handing a worker-queue patch to the main queue.
    /// A slow UI must never accumulate closures retaining tool outputs.
    static func metadataPatch(_ patch: [String: Any]) -> [String: Any]? {
        guard let rawPath = patch["path"] as? [Any], rawPath.count <= 20 else { return nil }
        let path = rawPath.map { String(describing: $0) }
        guard safePath(path) else { return nil }
        let op = patch["op"] as? String ?? "replace"
        if op == "remove" { return ["op": op, "path": path] }
        if path.last == "appContext", isItemPath(Array(path.dropLast())), let context = patch["value"] as? [String: Any] {
            var filtered: [String: String] = [:]
            if let connector = token(context["connectorId"]) { filtered["connectorId"] = connector }
            return ["op": op, "path": path, "value": filtered]
        }
        if ["id", "type", "server", "tool", "status", "connectorId"].contains(path.last ?? "") {
            guard let value = token(patch["value"]) else { return nil }
            return ["op": op, "path": path, "value": value]
        }
        guard let value = metadataValue(patch["value"], path: path, depth: 0) else { return nil }
        return ["op": op, "path": path, "value": value]
    }

    private static func metadataValue(_ value: Any?, path: [String], depth: Int) -> Any? {
        guard depth <= 10 else { return nil }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            if isItemPath(path) {
                for key in ["id", "type", "server", "tool", "status"] {
                    if let value = token(dict[key]) { result[key] = value }
                }
                if let context = dict["appContext"] as? [String: Any], let id = token(context["connectorId"]) {
                    result["appContext"] = ["connectorId": id]
                }
            } else {
                for key in dict.keys.sorted().prefix(200) where !privateFields.contains(key)
                    && (containers.contains(key) || path.last == "entitiesByKey" || path.last == "itemsById") {
                    if let child = metadataValue(dict[key], path: path + [key], depth: depth + 1) { result[key] = child }
                }
            }
            return result
        }
        if let array = value as? [Any] {
            // Keep array indices stable even for non-tool items.
            return array.prefix(200).enumerated().map { index, child in
                metadataValue(child, path: path + [String(index)], depth: depth + 1) ?? [:]
            }
        }
        return nil
    }

    func props() -> [ToolProp] {
        var result: [ToolProp] = []
        for key in order {
            guard let call = calls[key], call.active, !call.ended, let type = call.item.type else { continue }
            let identity = registry.identity(
                type: type, server: call.item.server, tool: call.item.tool, connector: call.item.connector
            )
            if let index = result.firstIndex(where: { $0.identity == identity }) {
                result[index].callCount += 1
            } else {
                result.append(ToolProp(identity: identity, callCount: 1))
            }
        }
        return result
    }

    private static let types: Set<String> = [
        "mcpToolCall", "dynamicToolCall", "commandExecution", "webSearch", "computerUse"
    ]
    private static let starts: Set<String> = ["inProgress", "running", "started"]
    private static let ends: Set<String> = [
        "completed", "failed", "cancelled", "canceled", "interrupted", "declined", "success", "error"
    ]
    private static let containers: Set<String> = [
        "turns", "turnHistory", "entitiesByKey", "items", "itemsById", "item", "turn", "entries"
    ]
    private static let privateFields: Set<String> = [
        "arguments", "args", "input", "output", "result", "results", "error", "content", "contentItems",
        "text", "message", "messages", "prompt", "summary", "command", "cwd", "action", "query", "instructions"
    ]

    private static func safePath(_ path: [String]) -> Bool {
        guard let root = path.first, ["turns", "turnHistory"].contains(root) else { return false }
        return !path.contains(where: { privateFields.contains($0) })
            && path.allSatisfy { $0.count <= 200 }
    }

    private static func isItemPath(_ path: [String]) -> Bool {
        guard safePath(path), let index = path.lastIndex(where: { ["items", "itemsById", "item"].contains($0) }) else {
            return false
        }
        guard path.last != "entitiesByKey" else { return false }
        return (path[index] == "item" && index == path.count - 1)
            || index == path.count - 2
            || (index + 3 == path.count && path[index + 1] == "entitiesByKey")
    }

    private func itemLocations(in value: Any?, at location: Location, depth: Int = 0) -> Set<Location> {
        guard depth <= 10 else { return [] }
        if Self.isItemPath(location.path) { return [location] }
        var result: Set<Location> = []
        if let dict = value as? [String: Any] {
            for (key, child) in dict where !Self.privateFields.contains(key)
                && (Self.containers.contains(key) || location.path.last == "entitiesByKey" || location.path.last == "itemsById") {
                result.formUnion(itemLocations(in: child, at: Location(thread: location.thread, path: location.path + [key]), depth: depth + 1))
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.prefix(200).enumerated() {
                result.formUnion(itemLocations(in: child, at: Location(thread: location.thread, path: location.path + [String(index)]), depth: depth + 1))
            }
        }
        return result
    }

    private mutating func walk(_ value: Any?, at location: Location, date: Date, historical: Bool, depth: Int) {
        guard depth <= 10, !saturated else { return }
        if let dict = value as? [String: Any] {
            if Self.isItemPath(location.path) {
                merge(dict, location: location, at: date, historical: historical)
                return
            }
            for key in dict.keys.sorted() where !Self.privateFields.contains(key)
                && (Self.containers.contains(key) || location.path.last == "entitiesByKey" || location.path.last == "itemsById") {
                walk(dict[key], at: Location(thread: location.thread, path: location.path + [key]), date: date, historical: historical, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.prefix(200).enumerated() {
                walk(child, at: Location(thread: location.thread, path: location.path + [String(index)]), date: date, historical: historical, depth: depth + 1)
            }
        }
    }

    private mutating func merge(_ fields: [String: Any], location: Location, at date: Date, historical: Bool) {
        guard !saturated else { return }
        var item = items[location] ?? Item()
        let oldID = item.id
        if let id = Self.token(fields["id"]) { item.id = id }
        if oldID != nil, item.id != oldID {
            endItem(at: location)
            item = Item(id: item.id)
        }
        if let type = Self.token(fields["type"]) { item.type = type }
        if let server = Self.token(fields["server"]) { item.server = server }
        if let tool = Self.token(fields["tool"]) { item.tool = tool }
        let context = fields["appContext"] as? [String: Any]
        if fields["appContext"] != nil || fields["connectorId"] != nil {
            item.connector = Self.token(context?["connectorId"] ?? fields["connectorId"])
        }
        if let status = fields["status"] as? String,
           Self.starts.contains(status) || Self.ends.contains(status),
           !Self.ends.contains(item.status ?? "") { item.status = status }
        guard items[location] != nil || fields.keys.contains(where: {
            ["id", "type", "status", "server", "tool", "appContext", "connectorId"].contains($0)
        }) else { return }
        if items[location] == nil, items.count >= capacity { saturate(); return }
        items[location] = item
        guard let id = item.id, let type = item.type, Self.types.contains(type) else { return }
        let key = Key(thread: location.thread, id: id)
        if calls[key] == nil, calls.count >= capacity { saturate(); return }
        if calls[key] == nil { order.append(key) }
        var call = calls[key] ?? Call(item: item, startedAt: date, active: false, ended: false)
        call.item = item
        if historical || Self.ends.contains(item.status ?? "") { call.ended = true }
        if Self.starts.contains(item.status ?? ""), !call.ended { call.active = true }
        if call.ended { call.active = false }
        calls[key] = call
    }

    private mutating func removeDescendants(of location: Location) {
        for old in Array(items.keys) where old.thread == location.thread && old.path.starts(with: location.path) {
            endItem(at: old)
        }
    }

    private mutating func shiftArrayLocations(at location: Location, inserting: Bool) {
        guard let component = location.path.last, let index = Int(component) else { return }
        let parent = Array(location.path.dropLast())
        guard ["items", "turns", "entries"].contains(parent.last ?? "") else { return }
        let affected = items.filter { key, _ in
            key.thread == location.thread && key.path.starts(with: parent)
                && key.path.count > parent.count && Int(key.path[parent.count]).map { $0 >= index } == true
        }
        for key in affected.keys { items.removeValue(forKey: key) }
        for (key, item) in affected {
            let oldIndex = Int(key.path[parent.count])!
            if !inserting, oldIndex == index { continue }
            var path = key.path
            path[parent.count] = String(oldIndex + (inserting ? 1 : -1))
            items[Location(thread: key.thread, path: path)] = item
        }
    }

    private mutating func endItem(at location: Location) {
        guard var item = items[location] else { return }
        item.status = "cancelled"
        items[location] = item
        if let id = item.id {
            let key = Key(thread: location.thread, id: id)
            calls[key]?.active = false
            calls[key]?.ended = true
        }
    }

    private mutating func saturate() {
        endAll()
        saturated = true
    }

    private static func token(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 200,
              value.range(of: "^[A-Za-z0-9_.:/-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }
}
