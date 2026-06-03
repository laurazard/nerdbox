# Formal specs (Quint)

Formal specifications of protocols and state machines in nerdbox,
written in [Quint](https://quint-lang.org/) and verified with Apalache and TLC.

## Layout

The spec directory mirrors the production package path so spec and code are
easy to navigate side-by-side:

```
spec/
└── shim/task/   # internal/shim/task
    ├── stdio.qnt        # container stdio forwarding state machine
    ├── stdio_test.qnt   # concrete scenarios (run blocks)
    └── stdio.md         # protocol contract in plain English
```

## Installing Quint

See the [Quint getting-started guide](https://quint-lang.org/docs/getting-started)
(`npm install -g @informalsystems/quint`). `quint verify` additionally
fetches Apalache on demand (JDK 17+ required).

## Running

| Target | What it does |
|---|---|
| `task spec:test`            | Run concrete-trace tests (`run` blocks). Fast, no Apalache. |
| `task spec:run`             | Random-simulation invariant check on the spec. |
| `task spec:verify`          | Symbolic model check (Apalache) of safety properties. |
| `task spec:verify:liveness` | Liveness check (TLC backend) of temporal properties. |

## CI

`task spec:test`, `task spec:run`, and `task spec:verify` run on PRs
that touch `spec/` (see `.github/workflows/spec-verify.yml`).
