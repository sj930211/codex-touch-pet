import AppKit
import Darwin

// Bounded read-only integration check of the production IPC adapter/store.
// It emits only connection state and aggregate prop/count data. No task
// titles, thread/call IDs, arguments, results or raw IPC frames are logged.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let store = ThreadStatusStore()
let client = CodexIPCClient(statusStore: store)
var previous: [ToolProp] = []
var previousConnection: CodexConnectionState?
var peak = 0
var observedStart = false
var observedEnd = false
var observing = true
store.onChange = { value in
    guard observing else { return }
    if value.connectionState != previousConnection {
        print("LIVE_CONNECTION \(value.connectionState.diagnosticLabel)")
        previousConnection = value.connectionState
    }
    if value.toolProps != previous {
        let count = value.toolProps.reduce(0) { $0 + $1.callCount }
        peak = max(peak, count)
        if count > 0 { observedStart = true }
        if observedStart, value.connectionState == .online,
           count < previous.reduce(0, { $0 + $1.callCount }) { observedEnd = true }
        print("LIVE_PROPS identities=\(value.toolProps.count) calls=\(count)")
        previous = value.toolProps
    }
}

// Exercise the observer itself without opening IPC: disconnect cleanup must
// never satisfy the real online start/end acceptance criterion.
if CommandLine.arguments.contains("--self-test") {
    var fixture = AggregatePetStatus(state: .working(nil), connectionState: .online,
        activeCount: 1, waitingCount: 0, trackedCount: 1)
    fixture.toolProps = [ToolProp(identity: .computer, callCount: 1)]
    store.onChange?(fixture)
    fixture.connectionState = .reconnecting
    fixture.toolProps = []
    store.onChange?(fixture)
    guard observedStart && !observedEnd else {
        fputs("LIVE_OBSERVER_FALSE_END: disconnect cleanup counted as online completion\n", stderr)
        exit(1)
    }
    fixture.connectionState = .online
    fixture.toolProps = [ToolProp(identity: .computer, callCount: 1)]
    store.onChange?(fixture)
    fixture.toolProps = []
    store.onChange?(fixture)
    guard observedEnd else { fatalError("Online completion must count") }
    observedEnd = false
    fixture.toolProps = [ToolProp(identity: .computer, callCount: 1)]
    store.onChange?(fixture)
    observing = false
    fixture.toolProps = []
    store.onChange?(fixture)
    guard !observedEnd else { fatalError("Shutdown callbacks cannot satisfy acceptance") }
    print("LIVE_OBSERVER_SELF_TEST_OK")
    exit(0)
}
client.start()
RunLoop.main.run(until: Date().addingTimeInterval(35))
observing = false
client.stop()
print("LIVE_SUMMARY start=\(observedStart) end=\(observedEnd) peak_calls=\(peak)")
var usage = rusage()
if getrusage(RUSAGE_SELF, &usage) == 0 { print("LIVE_PEAK_RSS_MB \(usage.ru_maxrss / 1_048_576)") }
exit(observedStart && observedEnd ? 0 : 2)
