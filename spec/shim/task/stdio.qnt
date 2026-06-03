// Quint specification of the docker-next-nerdbox container stdio
// forwarding state machine.
//
// Models the host-side stdio teardown backing
// internal/shim/task/io.go (forwardIO + its returned ioShutdown
// closure) and internal/shim/task/io_copystreams_unix.go (copyStreams):
//
//   - data plane: per-direction copy goroutines moving bytes between the
//     host FIFOs and the guest vsock streams (stdin host->guest;
//     stdout/stderr guest->host).
//   - drain barrier: an atomic counter over the two OUTPUT goroutines
//     (stdout, stderr); the last one to exit closes the `ioDone` channel.
//   - teardown: the cleanup closure (invoked from the Delete RPC) waits
//     for `ioDone`, bounded by a 30s deadline, BEFORE closing the stream
//     connections.
//
// The hidden complexity this spec pins down is the *close-before-drain
// race* (io.go:112-122): if the stream connections are closed before the
// output copy goroutines have drained, goroutines mid-Read observe
// "use of closed network connection" and drop bytes still buffered in
// the socket receive queue. The contract is: a clean teardown never
// truncates; truncation is reachable only on the bounded timeout path.
//
// This spec is normative: it describes the correct, intended behavior.
// Implementation defects are not modeled here.
//
// See stdio.md for a description in plain English.

// Types-only module. Declared separately from the operational `stdio`
// module so consumers (stdio_test.qnt) can import the types directly.
module stdio_types {
    // Lifecycle state of an output copy goroutine (stdout / stderr).
    type CopyState =
        | Running           // io.CopyBuffer active (or not yet started)
        | DrainedClean      // saw EOF after copying every buffered byte
        | AbortedTruncated  // stream force-closed mid-copy; buffered bytes lost

    // Result the ioShutdown cleanup closure returns to its caller (Delete).
    type ShutdownResult =
        | NoResult          // cleanup not finished
        | OkClean           // ioDone observed; streams closed cleanly
        | ErrTimeout        // deadline hit before ioDone; force-closed
}

module stdio {
    import stdio_types.*

    // ---- Direction / arity note --------------------------------------------
    //
    // copyStreams gates the drain barrier on exactly the OUTPUT directions
    // (stdout + stderr), initialising the counter to 2. We model those two
    // output goroutines explicitly (`outCopy`, `errCopy`) — the analog of
    // transfer.qnt's MaxPayloads=2 bound. The TTY case (stderr aliased to
    // stdout, counted twice over one connection) is a documentation-level
    // refinement of this two-stream model; see stdio.md. stdin is modeled
    // as a single non-gating goroutine.

    // ---- State variables ----------------------------------------------------

    // forwardIO opened the streams and copyStreams spawned the goroutines.
    var streamsOpen: bool

    // The guest closed its send side of stdout / stderr (the container
    // process exited and vminitd propagated EOF on the wire). Once set,
    // the corresponding output goroutine can drain cleanly.
    var guestEofOut: bool
    var guestEofErr: bool

    // The two gated output copy goroutines.
    var outCopy: CopyState
    var errCopy: CopyState

    // The stdin copy goroutine returned. It is NOT part of the drain
    // barrier: stdin can be abandoned without blocking teardown.
    var stdinExited: bool

    // close(done): both output goroutines have exited (cleanly or aborted).
    var ioDone: bool

    // The Delete RPC invoked the ioShutdown closure.
    var shutdownCalled: bool

    // The cleanup closed the stream connections.
    var streamsClosed: bool

    // Final result the ioShutdown closure returns.
    var shutdownResult: ShutdownResult

    // ---- Initialization -----------------------------------------------------

    action init = all {
        streamsOpen' = false,
        guestEofOut' = false,
        guestEofErr' = false,
        outCopy' = Running,
        errCopy' = Running,
        stdinExited' = false,
        ioDone' = false,
        shutdownCalled' = false,
        streamsClosed' = false,
        shutdownResult' = NoResult,
    }

    // ---- "Keep" helpers -----------------------------------------------------
    //
    // Quint requires every variable to be assigned in every step. Conjoining
    // a `keepX` is the idiomatic way to declare a variable unchanged.

    action keepStreamsOpen    = streamsOpen'    = streamsOpen
    action keepGuestEofOut     = guestEofOut'     = guestEofOut
    action keepGuestEofErr     = guestEofErr'     = guestEofErr
    action keepOutCopy         = outCopy'         = outCopy
    action keepErrCopy         = errCopy'         = errCopy
    action keepStdinExited     = stdinExited'     = stdinExited
    action keepIoDone          = ioDone'          = ioDone
    action keepShutdownCalled  = shutdownCalled'  = shutdownCalled
    action keepStreamsClosed   = streamsClosed'   = streamsClosed
    action keepShutdownResult  = shutdownResult'  = shutdownResult

    // ---- Prelude ------------------------------------------------------------

    // OpenStreams: forwardIO opens the vsock streams and copyStreams spawns
    // the copy goroutines. Both output goroutines start Running.
    action OpenStreams = all {
        not(streamsOpen),
        streamsOpen' = true,
        outCopy' = Running,
        errCopy' = Running,
        keepGuestEofOut,
        keepGuestEofErr,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    // ---- Guest EOF (data source ends) ---------------------------------------

    // GuestEofOut / GuestEofErr: the container process exited and vminitd
    // closed its send side, so EOF is now available on the wire. This is
    // the precondition for the host output goroutine to drain cleanly.
    action GuestEofOut = all {
        streamsOpen,
        not(guestEofOut),
        guestEofOut' = true,
        keepStreamsOpen,
        keepGuestEofErr,
        keepOutCopy,
        keepErrCopy,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    action GuestEofErr = all {
        streamsOpen,
        not(guestEofErr),
        guestEofErr' = true,
        keepStreamsOpen,
        keepGuestEofOut,
        keepOutCopy,
        keepErrCopy,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    // ---- Output goroutines drain --------------------------------------------

    // OutDrainsClean / ErrDrainsClean: the output copy goroutine reads the
    // remaining buffered bytes and then observes EOF, exiting cleanly.
    //
    // Guard `not(streamsClosed)`: a clean drain is only possible while the
    // connection is still open. Once the cleanup force-closes the streams
    // (ShutdownTimeout), a still-Running goroutine aborts truncated instead.
    action OutDrainsClean = all {
        streamsOpen,
        outCopy == Running,
        guestEofOut,
        not(streamsClosed),
        outCopy' = DrainedClean,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepErrCopy,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    action ErrDrainsClean = all {
        streamsOpen,
        errCopy == Running,
        guestEofErr,
        not(streamsClosed),
        errCopy' = DrainedClean,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepOutCopy,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    // ---- stdin (non-gating) -------------------------------------------------

    // StdinExits: the stdin goroutine returns (host FIFO closed, or the
    // guest stopped reading). It does not touch the drain barrier.
    action StdinExits = all {
        streamsOpen,
        not(stdinExited),
        stdinExited' = true,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepOutCopy,
        keepErrCopy,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    // ---- Drain barrier ------------------------------------------------------

    // IoDoneFires: the last output goroutine to exit calls close(done).
    // Fires once both output goroutines have left Running — whether they
    // drained cleanly or aborted truncated.
    action IoDoneFires = all {
        streamsOpen,
        not(ioDone),
        outCopy != Running,
        errCopy != Running,
        ioDone' = true,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepOutCopy,
        keepErrCopy,
        keepStdinExited,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    // ---- Teardown -----------------------------------------------------------

    // CallShutdown: the Delete RPC invokes the ioShutdown closure. This may
    // happen at any point after streams are open — in particular BEFORE the
    // guest has sent EOF. The cleanup must still wait for ioDone; code that
    // assumes Delete arrives only after the data plane has drained is unsafe.
    action CallShutdown = all {
        streamsOpen,
        not(shutdownCalled),
        shutdownCalled' = true,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepOutCopy,
        keepErrCopy,
        keepStdinExited,
        keepIoDone,
        keepStreamsClosed,
        keepShutdownResult,
    }

    // ShutdownCloseClean: ioDone was observed, so the cleanup closes the
    // stream connections with every output goroutine already drained. This
    // is the only success path.
    action ShutdownCloseClean = all {
        shutdownCalled,
        ioDone,
        not(streamsClosed),
        streamsClosed' = true,
        shutdownResult' = OkClean,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepOutCopy,
        keepErrCopy,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
    }

    // ShutdownTimeout: the cleanup's deadline elapses before ioDone (the
    // guest wedged / the VM died and EOF never arrived). The cleanup
    // force-closes the streams and returns ErrTimeout. Any output goroutine
    // still mid-copy aborts truncated — the only way truncation is reachable.
    action ShutdownTimeout = all {
        shutdownCalled,
        not(ioDone),
        not(streamsClosed),
        streamsClosed' = true,
        shutdownResult' = ErrTimeout,
        outCopy' = if (outCopy == Running) AbortedTruncated else outCopy,
        errCopy' = if (errCopy == Running) AbortedTruncated else errCopy,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
    }

    // ---- Top-level step relation --------------------------------------------

    // Copy: an output goroutine copies a unit of data guest->host while the
    // container runs. We abstract payload bytes away (as transfer.qnt does),
    // so a copy step changes no modeled variable, but it's important to model
    // since it's this action that gives the machine unbounded runs, and that
    // lets the bounded model checker build full-length traces instead of 
    // mistaking a too-short maximum run for a deadlock.
    // This is a repeatable behavior: a container may run, with its goroutines
    // copying, arbitrarily long before it exits or is deleted. Enabled while
    // an output goroutine is still Running and teardown has not begun.
    action Copy = all {
        streamsOpen,
        not(streamsClosed),
        outCopy == Running or errCopy == Running,
        keepStreamsOpen,
        keepGuestEofOut,
        keepGuestEofErr,
        keepOutCopy,
        keepErrCopy,
        keepStdinExited,
        keepIoDone,
        keepShutdownCalled,
        keepStreamsClosed,
        keepShutdownResult,
    }

    action step = any {
        OpenStreams,
        GuestEofOut,
        GuestEofErr,
        OutDrainsClean,
        ErrDrainsClean,
        StdinExits,
        IoDoneFires,
        CallShutdown,
        ShutdownCloseClean,
        ShutdownTimeout,
        Copy,
    }

    // ---- Properties ---------------------------------------------------------

    val anyOutputTruncated: bool =
        outCopy == AbortedTruncated or errCopy == AbortedTruncated

    // P1: CleanShutdownDrains (safety)
    //
    // A clean teardown implies both output goroutines drained cleanly.
    // Equivalently: a clean teardown never truncates an output stream.
    // This is the close-before-drain contract — closing only after ioDone
    // guarantees no goroutine is force-closed mid-copy. Reordering the spec
    // so ShutdownCloseClean does not require `ioDone` makes this fail.
    val CleanShutdownDrains: bool =
        shutdownResult == OkClean
            implies (outCopy == DrainedClean and errCopy == DrainedClean)

    // P2: TruncationImpliesTimeout (safety)
    //
    // Output truncation is reachable only on the bounded timeout path; it
    // can never accompany a clean teardown. The corollary of P1, stated
    // from the truncation side.
    val TruncationImpliesTimeout: bool =
        anyOutputTruncated implies shutdownResult == ErrTimeout

    // ---- Liveness -----------------------------------------------------------

    // L1: EventualCloseAfterShutdown (liveness)
    //
    // Teardown is CONDITIONAL: a container may run forever, so if Delete never
    // invokes the cleanup the streams legitimately never close — that is not a
    // violation. The guarantee is a leads-to: once the cleanup IS invoked, it
    // always completes (streams closed, closure returns), even when the guest
    // never sends EOF. The 30s deadline ensures the timeout path fires, so a
    // wedged guest cannot pin teardown forever.
    //
    // Fairness is assumed ONLY on the teardown-completing actions. We do not
    // assume the guest cooperates (sends EOF), nor that Delete is ever called
    // — only that, once invoked, the cleanup is allowed to run to completion.
    // While shutdownCalled holds and streams are still open, exactly one of
    // ShutdownCloseClean / ShutdownTimeout is enabled, so weak fairness on
    // their disjunction forces the close.
    //
    // Caveat: run with `quint verify --backend=tlc` (Apalache has limited
    // temporal support).
    action shutdownStep = any {
        ShutdownCloseClean,
        ShutdownTimeout,
    }

    val allVars = (
        streamsOpen,
        guestEofOut,
        guestEofErr,
        outCopy,
        errCopy,
        stdinExited,
        ioDone,
        shutdownCalled,
        streamsClosed,
        shutdownResult,
    )

    temporal Fairness = weakFair(shutdownStep, allVars)

    temporal EventualCloseAfterShutdown =
        always(shutdownCalled implies eventually(streamsClosed))

    temporal Liveness = Fairness implies EventualCloseAfterShutdown
}

// ---- Main instance ----------------------------------------------------------

module main {
    import stdio_types.*
    import stdio.*
}
