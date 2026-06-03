// Concrete-trace tests for the stdio forwarding spec.
//
// Run with:    quint test stdio_test.qnt --main=stdio_test
// Or via:      task spec:test
//
// Test naming: `quint test` matches names containing "Test"/"test" by
// default; we use a `Test` suffix to opt in.
//
// The spec is normative (see stdio.qnt header): every run asserts the
// outcome a correct implementation must produce.

module stdio_test {
    import stdio_types.* from "./stdio"
    import stdio.* from "./stdio"

    // cleanDrainTest — the normal case.
    //
    // The container exits, both output goroutines drain the buffered bytes
    // and observe EOF, ioDone fires, then Delete invokes the cleanup, which
    // sees ioDone already set and closes the streams cleanly. No truncation.
    run cleanDrainTest =
        init
            .then(OpenStreams)
            .then(GuestEofOut)
            .then(GuestEofErr)
            .then(OutDrainsClean)
            .then(ErrDrainsClean)
            .then(IoDoneFires)
            .then(CallShutdown)
            .then(ShutdownCloseClean)
            .expect(shutdownResult == OkClean)
            .expect(outCopy == DrainedClean)
            .expect(errCopy == DrainedClean)

    // deleteBeforeGuestEofTest — Delete arrives BEFORE the guest EOFs.
    //
    // The cleanup is invoked while the output goroutines are still copying.
    // It must block on ioDone rather than close immediately; only after the
    // guest EOFs and both goroutines drain does it close cleanly. This pins
    // the "wait for drain regardless of Delete ordering" contract (the
    // analog of transfer.qnt's transferReturnBeforeDataTest).
    run deleteBeforeGuestEofTest =
        init
            .then(OpenStreams)
            .then(CallShutdown)            // <- Delete before any guest EOF
            .then(GuestEofOut)
            .then(GuestEofErr)
            .then(OutDrainsClean)
            .then(ErrDrainsClean)
            .then(IoDoneFires)
            .then(ShutdownCloseClean)
            .expect(shutdownResult == OkClean)
            .expect(outCopy == DrainedClean)
            .expect(errCopy == DrainedClean)

    // guestWedgeTimeoutTest — the guest never sends EOF (VM crash / wedge).
    //
    // The output goroutines stay blocked mid-copy, ioDone never fires, and
    // the cleanup's deadline elapses. The cleanup force-closes the streams,
    // returns ErrTimeout, and both output goroutines abort truncated. This
    // is the only path on which truncation is reachable — bounded by the
    // 30s deadline so teardown cannot hang forever.
    run guestWedgeTimeoutTest =
        init
            .then(OpenStreams)
            .then(CallShutdown)
            .then(ShutdownTimeout)
            .expect(shutdownResult == ErrTimeout)
            .expect(outCopy == AbortedTruncated)
            .expect(errCopy == AbortedTruncated)

    // stdinDoesNotGateTest — stdin exits early; the barrier ignores it.
    //
    // The stdin goroutine returns before any output drains, yet ioDone still
    // gates solely on stdout + stderr and the teardown is clean. Pins the
    // stdin/stdout asymmetry (copyStreams initialises the counter to 2,
    // excluding stdin).
    run stdinDoesNotGateTest =
        init
            .then(OpenStreams)
            .then(StdinExits)              // <- stdin gone, must not gate ioDone
            .then(GuestEofOut)
            .then(GuestEofErr)
            .then(OutDrainsClean)
            .then(ErrDrainsClean)
            .then(IoDoneFires)
            .then(CallShutdown)
            .then(ShutdownCloseClean)
            .expect(shutdownResult == OkClean)
            .expect(stdinExited == true)
}
