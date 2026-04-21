# Literate Programming — Document First

**The single most important style rule in this codebase.** `.org` files are
documents that happen to contain code, not source files that happen to
have comments. Write the document first; the code blocks are evidence
that backs up the prose. The same principle applies to Python modules
(`python/claude_agent/*.py`) — favour docstrings that explain *why*, not
*what*, and prefer module-level prose over flat function lists.

Adapted from `~/projects/mind-ai/agents/mega/dev-agent/lisp-style.org`
§"Literate programming — document first", calibrated for this project.

## What "document first" means

For every `.org` module under the repo root (`claude-agent.org`,
`claude-org.org`, `claude-agent-acp*.org`, etc.), and for every meaningful
Python module under `python/claude_agent/`, the file must justify its
own existence in prose **before the first code block**.

1. **Overview section** — what this module owns, where it fits in the
   lifecycle (loading order, dependencies, role). Cross-link to calling
   modules and to `ARCHITECTURE.org` invariants.
2. **Public API section** when relevant — table of exported symbols /
   classes / functions with one-sentence roles. This is what consumers
   read first.
3. **Section heading + prose preamble before every code block.** Heading
   names a *concept* (`* ACP Handshake`, `* Permission Request Handler`),
   not a phase (`* Functions`, `* Helpers`). Each section opens with 1-3
   sentences explaining *what the code does, why it's shaped this way,
   what trade-off it embodies.*

Code blocks stay short and self-contained. If a block does something
non-obvious, the prose around it explains the non-obvious part. Don't
bury the explanation in `;;` comments — those are for implementation
details, not for the *reason* the code exists.

## Three principles that shape the document

1. **Intent before implementation.** Explain *why* before showing *how*.
   Prose drives the narrative; code blocks illustrate. No "Functions"
   section with no preamble.

2. **One block = one meaningful step.** Each code block does one thing,
   like a paragraph in prose. If a single `#+begin_src elisp` contains
   five unrelated `defun`s, split it — each gets its own section with
   its own 1-3 sentences of "why".

3. **Structure follows narrative logic, not execution order.** Present
   concepts in the order best for a human reader. `literate-elisp` doesn't
   care about order within a file — don't contort the document to match
   definition order.

## What looks right

```org
** Permission Request Handler

Handles `session/request_permission` server-to-client requests from the
agent. Default prompts the user via `completing-read` — C-g sends
`outcome: cancelled`. `claude-agent-acp-auto-approve` flips to legacy
first-option behaviour for trusted sandboxes.

#+BEGIN_SRC elisp
(defun claude-agent-acp--handle-permission (backend request)
  ...)
#+END_SRC
```

Three sentences of prose answer: *what* (handles a specific request),
*why* (default safer than auto-approve), *how to customise* (the
defcustom). A reader who can't run Elisp still understands the intent.

## What looks wrong

```org
** Functions

#+BEGIN_SRC elisp
(defvar claude-agent-acp-auto-approve nil)
(defun claude-agent-acp--handle-permission (backend request) ...)
#+END_SRC
```

No prose, generic heading, multiple unrelated definitions stacked in
one block. Even if the code is correct, the file is **failing as a
literate document**.

## Org files are the design record

Every design decision, tradeoff, open question, and "why not the other
approach" belongs in the module's `.org` file as prose. The org file is
the *only* durable record of *why* the code looks the way it does.

Chat conversations with AI agents, Slack threads, PR discussions are
ephemeral. If the reasoning lives only there, it's lost the next time
someone asks "why is this a cl-defstruct and not a plist?" or "why did
we reject session/load without fallback?"

Each module's `.org` file should carry:

- **Overview** — what this owns and where it fits.
- **Design intent** — why this shape was chosen. One paragraph usually
  suffices; if two approaches were considered, record both and the
  reason for the pick.
- **Rejected alternatives** — one short section per major "why not"
  that would otherwise be rediscovered later. Even one sentence is
  worth keeping.
- **Open questions / TODO** — acceptable in prose, not as bare `TODO`
  comments. Future readers read the prose, not the comments.

When a design conversation happens in an agent chat or PR review, **the
output of that conversation must land in the relevant `.org` file(s)
before the branch merges.** If you can't point at the prose that
captures the decision, it didn't happen.

## Self-check before committing

For each modified `.org` or `.py` file, ask:

1. Does the section heading describe a **concept**, not a phase or
   "Functions"/"Helpers"?
2. Does the prose before each code block answer **why** the code is
   shaped this way?
3. If you stripped every code block and read only the prose, would a
   human still understand the module's role?
4. Is each `defun` / `defclass` / `defmethod` / Python `def` / `class`
   accompanied by a docstring that's a **sentence**, not a label?

If any answer is "no", the file isn't done — keep writing prose, not
more code.

## Why this matters specifically here

- `literate-elisp` loads `.org` files **directly** via
  `literate-elisp-load` — the org file **is** the source of truth.
  There is no separate "tangle" step that strips the prose. When you
  edit a function, you're editing inside its own justification.
- Python modules are read by both humans and AI agents continuously.
  A module-level docstring explaining *why the module exists* saves
  every future reader the archaeology.
- One file = one set of decisions = one readable story.

This style has a cost: writing prose takes time. Pay the cost. The
codebase is small enough that future you (and reviewers, and other
agents) will read every module multiple times. One extra paragraph at
authoring saves hours of "what does this do?" archaeology later.
