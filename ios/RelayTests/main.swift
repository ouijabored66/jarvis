import Foundation

var failures: [String] = []

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("ok \(name)")
    } else {
        failures.append(name)
        print("FAIL \(name)")
    }
}

func lateReply(delay: TimeInterval) {
    var inbox = WatchInbox()
    let reply = RelayReply(id: "late-\(Int(delay))", transcript: "what time is it", say: "Three o'clock.", channel: .original)
    let turn = inbox.receive(reply, elapsed: delay)
    check(RelayWait.accepts(elapsed: delay), "still waiting at \(Int(delay))s")
    check(turn.replyLine == "Three o'clock.", "reply shown at \(Int(delay))s")
    check(turn.thinking == false, "thinking ends when the reply shows at \(Int(delay))s")
    check(turn.userLine == "what time is it", "transcript shown at \(Int(delay))s")
}

for delay in [15.0, 60.0, 95.0] {
    lateReply(delay: delay)
}

check(RelayWait.accepts(elapsed: 99.9), "99.9s is still inside the cap")
check(RelayWait.accepts(elapsed: 100) == false, "the cap is 100s")
check(RelayWait.cap == 100, "phone reply cap is 100 seconds")

let queued = PhoneDelivery.plan(reachable: false, handlerOpen: true)
check(queued.contains(.sendMessage), "unreachable session still tries a message")
check(queued.contains(.sendMessageRetry), "unreachable session retries the message")
check(queued.contains(.userInfo), "unreachable session queues user info")
check(queued.contains(.context), "unreachable session queues context")
check(queued.contains(.originalHandler) == false, "unreachable session does not use the original handler")

var queuedInbox = WatchInbox()
let queuedReply = RelayReply(id: "queued", transcript: "hello", say: "Hi.", channel: .context)
let queuedTurn = queuedInbox.receive(queuedReply, elapsed: 20)
check(queuedTurn.replyLine == "Hi.", "queued fallback is shown")
check(queuedInbox.lines == ["Hi."], "queued fallback is the only line")

let open = PhoneDelivery.plan(reachable: true, handlerOpen: true)
check(open.first == .originalHandler, "reachable session uses the original handler")
check(open.contains(.userInfo) && open.contains(.context), "reachable session also keeps a queued copy")

var once = WatchInbox()
let first = RelayReply(id: "same", transcript: "ping", say: "Pong.", channel: .original)
let second = RelayReply(id: "same", transcript: "ping", say: "Pong.", channel: .userInfo)
let third = RelayReply(id: "same", transcript: "ping", say: "Pong.", channel: .context)
_ = once.receive(first, elapsed: 15)
let dupA = once.receive(second, elapsed: 16)
let dupB = once.receive(third, elapsed: 17)
check(once.lines == ["Pong."], "one id is shown once")
check(dupA.replyLine == nil && dupB.replyLine == nil, "later copies add no line")

var slow = WatchInbox()
let partial = RelayReply(id: "slow", transcript: "turn on the lamp", say: nil, error: nil, channel: .original)
let partialTurn = slow.receive(partial, elapsed: 4)
let miss = RelayReply(id: "slow", transcript: "turn on the lamp", say: nil, error: RelayWait.miss, channel: .sendMessage)
let missTurn = slow.receive(miss, elapsed: 8)
let done = RelayReply(id: "slow", transcript: "turn on the lamp", say: "Lamp on.", channel: .context)
let doneTurn = slow.receive(done, elapsed: 16)
check(partialTurn.thinking, "transcript alone keeps thinking")
check(partialTurn.userLine == "turn on the lamp", "transcript is kept")
check(missTurn.replyLine == nil, "miss is not a reply")
check(slow.lines.contains(RelayWait.miss) == false, "miss is not shown after a transcript")
check(doneTurn.replyLine == "Lamp on.", "slow assistant reply is shown")
check(slow.lines == ["Lamp on."], "only the assistant reply is listed")

let base = "https://relay.example/v1"
let transcribe = CloudRoutes.url(base: base, path: "api/transcribe")?.absoluteString ?? ""
let text = CloudRoutes.url(base: base, path: "api/text")?.absoluteString ?? ""
let chat = CloudRoutes.url(base: base, path: "chat/completions")?.absoluteString ?? ""
check(transcribe == "https://relay.example/api/transcribe", "transcribe uses the host root")
check(text == "https://relay.example/api/text", "text uses the host root")
check(transcribe.contains("/v1/api") == false && text.contains("/v1/api") == false, "api is not appended to /v1")
check(chat == "https://relay.example/v1/chat/completions", "chat stays on the /v1 base")
check(CloudRoutes.skipTranscribe(status: 404), "404 skips transcribe")
check(CloudRoutes.skipTranscribe(status: 200) == false, "200 does not skip transcribe")

let plain = CloudRoutes.url(base: "https://relay.example", path: "api/text")?.absoluteString ?? ""
check(plain == "https://relay.example/api/text", "a base without /v1 still joins api/text")

if failures.isEmpty {
    print("all checks passed")
    exit(0)
}
print("failed \(failures.count): \(failures.joined(separator: ", "))")
exit(1)
