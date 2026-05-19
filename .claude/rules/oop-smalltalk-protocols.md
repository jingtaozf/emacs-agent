# OOP Design — Smalltalk-Flavoured Protocols

Each module models its domain as a small set of **classes** (state +
identity) and **protocols** (published behaviour, dispatched on the
receiver). New code must follow this style; older modules are being
refactored to match. Applies to both languages: Elisp
(`cl-defstruct` + `cl-defgeneric`) and Python (classes + methods +
`typing.Protocol`/ABC).

## Core idea

Instead of free functions operating on plists/dicts or passing state
through every call, each major actor is a class:

- **Identity + state** lives in **slots / attributes** (`cl-defstruct`,
  `class ...`).
- **Public behaviour** lives in **protocol generic functions /
  methods** (`cl-defgeneric`, `def method_name(self, ...)` with a
  `typing.Protocol` or ABC contract).
- **Implementations** are **methods** dispatched on the receiver's
  class (`cl-defmethod ... ((obj some-class) ...)`; Python subclassing).

Callers interact by "sending a message to an object":

```elisp
;; Elisp
(claude-agent-backend-query backend prompt callbacks)   ; dispatches on backend class
(claude-agent-backend-cancel backend handle)
```

```python
# Python
backend.query(prompt, on_token=cb)   # dispatches on backend's class
backend.cancel(handle)
```

This is the Smalltalk pattern. It gives us:

- **Clear protocols between modules.** The set of generic functions on
  a class is the published API; everything else is private.
- **Pluggability.** Subclass + override to mock, record, or swap
  backends — `claude-agent-acp-backend` vs. `claude-agent-claude-code-backend`
  both implement the same `claude-agent-backend-*` protocol.
- **Hot-reload.** Redefining a `cl-defmethod` hot-swaps it everywhere
  the live system dispatches — no plumbing. Python: reloading the
  subclass module picks up new method bodies (with care).

## What this looks like in Elisp

A module typically has:

1. **Condition-like errors** — raised via `error` with a structured
   `plist` payload, or wrapped by the caller's classification
   (`claude-agent-backend-classify-error` dispatches on backend type).
2. **Entity classes** for identity + small state — `cl-defstruct` is
   fine here (e.g. `claude-agent-acp-backend` struct with agent-name,
   session-id, spawn-args slots).
3. **Coordinator / registry classes** for modules with process state —
   the backend *is* the coordinator.
4. **Generic functions** named after the operation, specialized on the
   receiver:

```elisp
(cl-defgeneric claude-agent-backend-query (backend prompt callbacks))
(cl-defgeneric claude-agent-backend-cancel (backend handle))
(cl-defgeneric claude-agent-backend-cleanup (backend))

(cl-defmethod claude-agent-backend-query
  ((backend claude-agent-acp-backend) prompt callbacks &rest args)
  ...)
```

Factory helpers like `claude-agent-acp-opencode-create` stay as plain
`defun`s — they don't need dispatch; they're wrappers over
`make-instance`-equivalent.

## What this looks like in Python

```python
# protocol.py
from typing import Protocol, Callable

class BackendProtocol(Protocol):
    """Protocol every backend must implement — published API of the module."""
    def query(self, prompt: str, on_token: Callable[[str], None]) -> None: ...
    def cancel(self, handle: object) -> None: ...
    def cleanup(self) -> None: ...

# acp_backend.py
class AcpBackend:
    """ACP backend — one subprocess, one session, one agent."""
    def __init__(self, agent_name: str, spawn_args: list[str], ...):
        self.agent_name = agent_name
        ...

    def query(self, prompt, on_token):
        ...

    def cancel(self, handle):
        ...
```

Callers type against `BackendProtocol`, never against a specific
class — structural typing keeps the protocol as the contract.

## What to avoid

- **Naked free functions on module-level dicts/hash-tables as "API".**
  Wrap the hash in a class; expose methods/generics.
- **Struct/dict + accessor-style code** for anything with non-trivial
  behaviour. `cl-defstruct` without any `cl-defgeneric` is a smell
  once behaviour accrues — promote to protocol. Python `dict` with
  a dozen helper functions that take the dict as first arg → class.
- **Keyword arguments to choose behaviour** — `(do-thing x :style :a)`
  should be `(do-thing a-instance x)` with different methods. Python:
  `do_thing(x, style="a")` branching on string → separate subclasses.
- **Direct global-var access from another module.** Module A publishes
  *classes + generics*, not hash-tables, sockets, or threads. If you
  find yourself reaching into `code-agent-org--persistent-clients` from
  an ACP file, expose a generic instead.

## Concrete examples in this repo

**Good** — `claude-agent-backend.org` defines a protocol:

```elisp
(cl-defgeneric claude-agent-backend-query (backend prompt callbacks &rest args))
(cl-defgeneric claude-agent-backend-cancel (backend handle))
(cl-defgeneric claude-agent-backend-cleanup (backend))
(cl-defgeneric claude-agent-backend-ready-p (backend))
(cl-defgeneric claude-agent-backend-classify-error (backend error))
(cl-defgeneric claude-agent-backend-supports-p (backend capability))
```

`claude-agent-acp-backend`, `claude-agent-claude-code-backend`, and others
each `cl-defmethod` these generics. Caller (`code-agent-org.org`) dispatches
on the backend instance.

**Mixed** — `python/claude_agent/workspace_bridge.py` uses mostly free
functions over dicts. Candidate for refactor into:
`WorkspaceBridge` class with `handle_response`, `handle_prompt`,
`handle_session_start` methods; a `BridgeProtocol` if we ever grow a
second bridge (e.g. a test mock).

## Per-module checklist

Before shipping a new module (or reviewing one in a PR):

1. Is there a **class** (`cl-defstruct` / Python `class`) representing
   the entity or coordinator?
2. Is the **public API** a set of generics/methods on that class, or
   a `Protocol`/ABC the class implements?
3. Do callers dispatch on the **receiver**, not on a string/keyword
   discriminator?
4. Are internals reachable only through the public protocol, or do
   other modules still reach into internals directly?
5. Is there a **factory function** (`-create`, `make_*`) wrapping the
   constructor so call sites read well?

If any answer is "no", the module isn't following the style — either
fix it or document why this case is an exception (in the module's own
`.org` / docstring).
