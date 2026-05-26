# Reflect Skill

Transform mistakes into persistent rules through structured reflection.

## Triggers

- `/reflect`
- "reflect on this mistake"
- "learn from this"
- "add this as a rule"
- "don't do that again"

## Meta-Rules (Internal Guidelines)

When creating rules, follow these standards:

| # | Principle | Example |
|---|-----------|---------|
| 1 | Use ALWAYS/NEVER for absolutes | "NEVER use heading text for navigation" |
| 2 | Rationale first (1-3 bullets) | - Heading text is ambiguous |
| 3 | Concrete examples | Show wrong AND correct code |
| 4 | Session provenance | Include session ID where discovered |
| 5 | One rule per entry | Atomic, findable |
| 6 | Problem → Solution format | State error, then fix |

## Workflow

### Step 1: REFLECT

Analyze what went wrong:
- What specific action caused the problem?
- What was expected vs actual outcome?
- What context was missing?

### Step 2: ABSTRACT

Find the underlying pattern:
- Is this a one-off or a class of errors?
- Category: navigation / file-ops / syntax / mcp / org-mode / elisp / git / etc.
- What signal should trigger different behavior?

### Step 3: GENERALIZE

Form the rule following meta-rules above:
- Write rule preventing this ERROR CLASS, not just this instance
- Use ALWAYS/NEVER for absolutes
- Include detection criteria (how to recognize when rule applies)

### Step 4: PROPOSE

Output rule in this format:

---
**Rule Proposal**

**Title**: [Short descriptive name]

**Category**: [navigation/file-ops/mcp/org-mode/elisp/git/etc.]

**Problem**: [What went wrong - 1-2 sentences]

**Rule**: [ALWAYS/NEVER + directive]

**Rationale**:
- [Why this matters]
- [What class of errors this prevents]

**Example**:
```
// WRONG
[code that causes problem]

// CORRECT
[code that prevents problem]
```

**Session**: [Current session ID if available]

---

### Step 5: ASK USER

Use AskUserQuestion tool with these questions:

**Question 1**: "Add this rule to your configuration?"
- Options:
  - "Yes" - Add the rule as proposed
  - "No" - Discard this rule
  - "Modify" - Edit the rule before adding

If "Modify": Ask what to change, update proposal, then ask again.

**Question 2** (if Yes): "Where should this rule be stored?"
- Options:
  - "Global CLAUDE.md" - ~/.claude/CLAUDE.md (affects all projects)
  - "Global rules folder" - ~/.claude/rules/{category}/ (categorized)
  - "Project CLAUDE.md" - .claude/CLAUDE.md (this project only)
  - "Notebook section" - Current org file's :system_prompt: section

### Step 6: WRITE RULE

Based on user's choice, write the rule to the appropriate location.

#### For Global CLAUDE.md (~/.claude/CLAUDE.md)

Use Write tool to append:

```markdown
## [Rule Title]

**Problem**: [description]

**Rule**: [ALWAYS/NEVER + directive]

**Rationale**:
- [point 1]
- [point 2]

**Example**:
```[lang]
// WRONG
[bad code]

// CORRECT
[good code]
```

*Session: [session-id]*
```

#### For Global rules folder (~/.claude/rules/{category}/)

Create file: `~/.claude/rules/{category}/{slug}.md`
- slug = lowercase, hyphenated title (e.g., "search-by-custom-id")

Use Write tool with content:

```markdown
# [Rule Title]

## Session
[session-id]

## Problem
[What went wrong - 1-2 sentences]

## Rule
[ALWAYS/NEVER + directive]

## Rationale
- [Why this matters]
- [What class of errors this prevents]

## Example

```[lang]
// WRONG - causes [problem]
[bad code]

// CORRECT - prevents [problem]
[good code]
```
```

#### For Project CLAUDE.md (.claude/CLAUDE.md)

Same format as Global CLAUDE.md, but write to `.claude/CLAUDE.md` in project root.
Create .claude directory if it doesn't exist.

#### For Notebook :system_prompt: section

Use evalElisp MCP tool to add rule to current org file's :system_prompt: section:

```elisp
(let ((debug-on-error nil)
      (debug-on-quit nil))
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^\\*+ .*:system_prompt:" nil t)
        (progn
          (org-end-of-subtree)
          (insert "\n\n** [Rule Title]\n\n[ALWAYS/NEVER + directive]\n\n[Rationale and example]"))
      ;; Create :system_prompt: section if missing
      (goto-char (point-max))
      (insert "\n* Project Rules :system_prompt:\n\n** [Rule Title]\n\n[content]"))))
```

Format for org:
```org
** [Rule Title]

[ALWAYS/NEVER + directive]

*Rationale*:
- [point 1]
- [point 2]

*Example*:
#+begin_src [lang]
;; WRONG
[bad code]

;; CORRECT
[good code]
#+end_src

/Session: [session-id]/
```

## Complete Example

User: "You searched for the heading text and found the wrong section. /reflect"

Claude's response:

---

**Rule Proposal**

**Title**: Search by CUSTOM_ID, Not Heading Text

**Category**: navigation

**Problem**: Searching for heading text "Research Output :research_output:" matched 14 different sections. The first match was an old section, causing content to be written to the wrong location.

**Rule**: ALWAYS search by `:CUSTOM_ID:` pattern, NEVER by heading text when navigating to org sections.

**Rationale**:
- Heading text is ambiguous - multiple sections can have identical names
- CUSTOM_ID with session suffix is guaranteed unique
- Wrong-section writes corrupt user's document

**Example**:
```elisp
;; WRONG - finds first match, may be wrong section!
(re-search-forward "Research Output :research_output:" nil t)

;; CORRECT - use the CUSTOM_ID
(re-search-forward ":CUSTOM_ID: code-agent-dev-research-output-sdd-20251229" nil t)
```

**Session**: sdd-20251229-172814

---

Then use AskUserQuestion:
1. "Add this rule?" → User selects "Yes"
2. "Where to store?" → User selects "Global rules folder"

Then write to `~/.claude/rules/navigation/search-by-custom-id.md`

## Tips

- Be specific about the error class, not just the instance
- Include the "detection signal" - what should trigger this rule?
- Keep examples minimal but complete
- Reference the session ID for traceability
- If uncertain about category, ask user
