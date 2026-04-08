# Code Clarity Over Feature Velocity

Readable, well-structured code matters more than shipping features or
adding tests. After every change, pause and ask:

1. **Would a newcomer understand this?** If a function needs a comment
   to explain *what* it does (not *why*), it should be renamed or
   restructured instead.

2. **Does the abstraction earn its weight?** Each layer, helper, or
   indirection must reduce total complexity. If removing it makes the
   code shorter *and* clearer, remove it.

3. **Does the literate narrative still flow?** This project uses
   literate programming — the org file is a document humans read
   top-to-bottom. After editing, re-read the surrounding section.
   Ensure headings, prose, and code tell a coherent story. Move
   misplaced code to where a reader would expect it.

4. **Are names precise?** A variable named `result` or `data` is a
   missed opportunity. Prefer names that encode the *role*:
   `cli-session-id`, `workspace-heading-pos`, `ready-pattern-re`.

5. **Is there unnecessary ceremony?** Boilerplate wrappers, defensive
   nil-checks that can never trigger, over-parameterised functions —
   delete them. The simplest correct code is the best code.

## When to apply

- After implementing a feature, review your diff for clarity before
  calling it done.
- During code review, prioritise readability feedback over style nits.
- When refactoring, measure success by whether the code is *easier to
  read*, not just shorter.
