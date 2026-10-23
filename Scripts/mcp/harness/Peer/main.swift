// TEST-ONLY foreign peer. It is NOT the production bridge. It exists so the harness can
// present a differently-signed process (team-signed foreign identifier, or ad-hoc with the
// genuine identifier) to the fixture and prove the fixture refuses it before replying.
//
// It uses production LocalSocket/FrameIO/BrokerProtocol code, deliberately performs no
// server verification (permissive client policy), sends a hello, and counts bytes received.

import Darwin
import Foundation

func emit(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

signal(SIGPIPE, SIG_IGN)
guard CommandLine.arguments.count == 2 else {
    emit("peer_usage_error")
    exit(2)
}
let started = MonotonicDeadline.now
let fd: Int32
do {
    fd = try LocalSocket.connect(to: CommandLine.arguments[1])
} catch {
    emit("peer_connect_failed reason=\(BrokerConnectionHandler.reason(error)) detail=\(error)")
    exit(4)
}
do {
    try FrameIO.writeFrame(
        fd,
        try BrokerProtocol.encode(BridgeHello(clientDisplayName: "CR-FOREIGN-CLIENT-NAME")),
        maxBytes: 16 * 1024,
        timeout: 2
    )
    emit("peer_hello_written")
} catch {
    emit("peer_hello_write_failed reason=\(BrokerConnectionHandler.reason(error))")
}
var total = 0
var sawEOF = false
let deadline = MonotonicDeadline.after(5)
var buffer = [UInt8](repeating: 0, count: 4096)
while !deadline.hasPassed {
    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&poller, 1, Int32(max(deadline.remaining, 0) * 1000))
    if ready <= 0 { break }
    let count = read(fd, &buffer, buffer.count)
    if count > 0 {
        total += count
    } else if count == 0 {
        sawEOF = true
        break
    } else if errno != EINTR && errno != EAGAIN {
        sawEOF = errno == ECONNRESET
        break
    }
}
let elapsed = Int((MonotonicDeadline.now.uptimeNanoseconds &- started.uptimeNanoseconds) / 1_000_000)
emit("peer_bytes_received=\(total) eof=\(sawEOF) elapsed_ms=\(elapsed)")
close(fd)
exit(total == 0 ? 0 : 7)
