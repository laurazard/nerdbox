# Container stdio forwarding — contract and scenarios

Specifies the host-side container stdio teardown state machine modeled in
[`stdio.qnt`](./stdio.qnt). Backs the `forwardIO` closure in
[`internal/shim/task/io.go`](../../../internal/shim/task/io.go) and
`copyStreams` in
[`internal/shim/task/io_copystreams_unix.go`](../../../internal/shim/task/io_copystreams_unix.go).

## Wire-level data flow

The shim bridges the container's three standard streams between host FIFOs and
guest vsock connections.
```
                 stdin   (host FIFO) ──> guest   [host->guest]
container <──    stdout  (host FIFO) <── guest   [guest->host]
                 stderr  (host FIFO) <── guest   [guest->host]
```

`copyStreams` spawns one copy goroutine per stream:

- **stdout / stderr** copy guest → host (`io.CopyBuffer(hostFIFO, stream)`).
  These are the **output** goroutines.
- **stdin** copies host → guest. It is the **input** goroutine.

## The drain barrier

`copyStreams` initialises an atomic counter to **2** — one slot for stdout and
one for stderr. Each output goroutine decrements it on exit, and the goroutine
that drops it to zero closes the `ioDone` channel. stdin is deliberately
**excluded**: it copies host → guest, so it has no buffered guest output to
lose, and abandoning it must not block teardown.

The cleanup closure returned by `forwardIO` (stored as `ioShutdown`, invoked
from the `Delete` RPC) **waits for `ioDone` before closing the stream
connections**, bounded by a 30 s deadline if the caller supplied none.

## Contract

1. **`forwardIO` opens the streams and starts the copy goroutines.** Both
   output goroutines begin in the `Running` state.

2. **Each output goroutine drains cleanly only after the guest closes its send
   side** (the container process exited and vminitd propagated EOF). It reads
   every buffered byte, observes EOF, and exits `DrainedClean`.

3. **`ioDone` fires once both output goroutines have exited** — the `close(done)`
   in the last goroutine to finish.

4. **The cleanup closure and the guest EOF are independent in time.** `Delete`
   may invoke `ioShutdown` before the guest has sent EOF, while the output
   goroutines are still copying. The cleanup must still wait for `ioDone`; code
   that assumes `Delete` only arrives after the data plane has drained is
   unsafe.

5. **A clean teardown closes the streams only after `ioDone`.** This is the
   **close-before-drain** contract: closing the connections while an output
   goroutine is mid-`Read` makes it observe "use of closed network connection"
   and drop bytes still buffered in the socket receive queue (`io.go:112-122`).
   Waiting for `ioDone` guarantees every output goroutine has already drained.

6. **A wedged guest cannot pin teardown forever.** If EOF never arrives (VM
   crash, vminitd hang, kernel wedge), `ioDone` never fires and the 30 s
   deadline elapses. The cleanup force-closes the streams and returns a
   timeout error. Output goroutines still mid-copy abort truncated — this is
   the **only** path on which truncation is reachable.

## Properties (verified in [`stdio.qnt`](./stdio.qnt))

- **P1 `CleanShutdownDrains` (safety).** A clean teardown
  (`shutdownResult == OkClean`) implies both output goroutines are
  `DrainedClean`. Equivalently: a clean teardown never truncates an output
  stream. This is contract point 5; removing the `ioDone` guard from
  `ShutdownCloseClean` makes the invariant fail with a close-before-drain
  counterexample.
- **P2 `TruncationImpliesTimeout` (safety).** Output truncation is reachable
  only on the bounded timeout path (contract point 6); it can never accompany a
  clean teardown.
- **L1 `EventualCloseAfterShutdown` (liveness).** Teardown is *conditional*: a
  container may run forever, so if `Delete` never invokes the cleanup the
  streams legitimately never close (not a violation). The guarantee is a
  leads-to — `shutdownCalled` ⟹ eventually `streamsClosed` — that holds even
  when the guest never sends EOF, because the deadline guarantees the timeout
  path fires. Verified under weak fairness on *only* the teardown-completing
  actions: termination depends on neither the guest cooperating nor `Delete`
  ever arriving, only on the cleanup being allowed to finish once invoked.

## Modeling notes

- **Two output streams.** The model represents exactly the two gated output
  goroutines (`outCopy`, `errCopy`) — the analog of the counter initialised to
  2. The **TTY** case (stderr aliased to stdout over a single connection,
  counted twice via `countingWriteCloser`) is a degenerate refinement of this
  two-stream model: the drain barrier still decrements twice, so the state
  machine is unchanged.
- **stdin** is a single non-gating goroutine (`stdinExited`); it never affects
  `ioDone` or `shutdownResult`.
- **A running container** is modeled by `Copy`, a repeatable step (an output
  goroutine still `Running` copies a unit of data) that changes no abstracted
  variable. It
  makes the machine's runs genuinely unbounded — a container may run for any
  length of time before it exits or is deleted — which is also why the bounded
  model checker does not mistake the (reachable) terminal state for a deadlock.
- **Platform symmetry.** The Unix (`io_copystreams_unix.go`) and Windows
  (`io_copystreams_windows.go`) implementations share this state machine; only
  the FIFO/named-pipe open differs.

## Scenarios

| Run | What it pins |
|---|---|
| `cleanDrainTest` | Normal exit: guest EOFs, both outputs drain, `ioDone`, clean close. |
| `deleteBeforeGuestEofTest` | `Delete` arrives before guest EOF; cleanup blocks on `ioDone` then closes clean (contract 4 + 5). |
| `guestWedgeTimeoutTest` | Guest never EOFs; deadline elapses, force-close, `ErrTimeout`, outputs aborted (contract 6). |
| `stdinDoesNotGateTest` | stdin exits early; the barrier ignores it; clean close. |
