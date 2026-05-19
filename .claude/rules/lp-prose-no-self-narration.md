# LP Prose: No Self-Narration / No Filler Parentheticals

LP prose must carry *new information*. After every paragraph, ask:
if I delete this paragraph, does the reader's understanding of the
system degrade? If no — delete it.

The literate-programming push is "the document teaches". Self-narrating
prose — "as shown above", "see below", "(Source: foo.svg — GitHub
renders it inline)" — does not teach. It comments on the document's
own mechanics. Every line of self-narration steals attention from
the lines that *do* teach.

## Anti-patterns (forbidden)

### 1. Self-narration immediately following the artefact

Restating what an immediately-preceding link, image, table, or
section heading already shows.

```org
[[file:images/architecture.svg]]

(Source: architecture.svg — GitHub renders the SVG inline.)   ← NO
```

The link is the source. The reader sees the SVG. The parenthetical
adds zero.

```org
| col | col |
|-----|-----|
| a   | b   |

(The table above shows ... )                                    ← NO
```

### 2. Mechanism explanation that does not change reader action

Explaining *how* the document renders, *how* a tool works at the
mechanical level, or *how* a path resolves — when the explanation
neither warns the reader nor changes what they do next.

```org
The =:tangle ../../repos/<sub>/foo.py= path resolves relative to
this .org file.                                                  ← NO
```

The reader either already knows (in which case the line is wasted)
or will learn from `make tangle` blowing up (in which case the line
was not load-bearing). Compare with the acceptable variant below
that does carry a warning.

### 3. Filler parentheticals

`(see below)`, `(for details)`, `(note that …)`, `(as mentioned earlier)`,
when the referent is already in the reader's working memory or
re-states the immediately preceding sentence.

```org
The hook fires on every tool call (the hook fires on every tool
call, see the table above).                                      ← NO
```

### 4. Pleasantries and meta-narration

"In this section we will discuss…", "First, let's understand…",
"Hopefully this clarifies…" — direct narrator-to-reader voice
that adds no system fact.

## Acceptable prose

| Kind                | What it carries                                                              |
|---------------------|------------------------------------------------------------------------------|
| Decision rationale  | Why path A was chosen over path B; the trade-off the code embodies          |
| Trap / gotcha       | This breaks if X; common mistake when Y; failure mode that bit us           |
| New-content pointer | "See `scripts.org` § log_hook for the rotation policy" — sending the reader's eye to *new* material |
| Warning-bearing mechanism | "Paths resolve relative to the .org file — a `git mv` of the .org silently breaks tangling" (mechanism + the actionable consequence) |

The third row is the bar: a pointer to *new* material is fine;
a pointer to "what the reader is already looking at" is not.

## The deletion test

After every paragraph, run the test:

1. Delete the paragraph in your head.
2. Re-read the surrounding text.
3. Does the reader still understand the system equally well?

If yes — delete the paragraph for real. The cost of cutting genuine
content is one re-add; the cost of leaving filler is permanent
attention tax on every future reader.

## When you catch yourself writing self-narration

The typical trigger is a *just-completed artefact* — you just
embedded an SVG, finished a table, dropped a code block — and the
agent reflex is to "narrate" what was just produced. Resist:

- After an image / SVG link → the next line is either prose about
  *what the diagram shows* (new content) or a heading. Not a
  parenthetical naming the source.
- After a table → the next line is the next concept, not "the table
  above shows…".
- After a code block → either prose about *why this code* or the
  next section. Not "this code does X" repeating the obvious.

## Enforcement

PR review. Reviewer scans for the trigger phrases listed below and
asks the author to delete or replace with a decision / trap / pointer.

Trigger phrases reviewers should grep for:

- `^\s*\(Source:` after an org link
- `^\s*\(See ` followed by a position word (`above`, `below`, `next`)
- `GitHub renders`
- `As shown (above|below)`
- `The (diagram|table|code) above`
- `In this section`, `First, let's`, `Hopefully`
