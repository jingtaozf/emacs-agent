;;; claude-org-templates.el --- Default templates for claude-org AI blocks -*- no-byte-compile: t; -*-

;; Copyright (C) 2024 Jingtao Xu

;; Author: Jingtao Xu
;; Keywords: templates, ai

;;; Commentary:

;; Default template definitions loaded by `claude-org--get-templates'.
;; This is a data file — the top-level form is an alist read by
;; `claude-org--load-templates-from-file'.
;;
;; Templates are reloaded from this file every time the template menu
;; is invoked, so edits take effect immediately without restarting Emacs.
;;
;; Each entry is (NAME . VALUE) where VALUE is either:
;;   - A string to insert verbatim into an AI block
;;   - A symbol naming a function (no args) that returns a string
;;
;; To customize, copy this file to your preferred location and set
;; `claude-org-templates-file' to point to it.

;;; Data:

(("Analyze Backtrace" . claude-org-template--backtrace)
 ("Code Review" . "run code simplifier and code review to the code changes.")
 ("Explain Code" . "Please explain what this code does, including:
1. Overall purpose
2. Key functions and their roles
3. Data flow
4. Any notable patterns or techniques

")
 ("Fix Error" . "Please help fix this error:

Error:

Context:

")
 ("continue" . "Please continue the previous instruction if not finished.")
 ("Git Commit and Push" . "Please commit and push the changes.

Note: If there are pre-commit hooks configured, please wait for them to complete
before considering the commit successful. If hooks fail, fix the issues and retry.

")
 ("Enter Worktree" . "Please enter a worktree for this story.
All code changes should happen in the worktree.
")
 ("Exit Worktree (keep)" . "Please exit the worktree and keep it.
I'll review and merge manually.
")
 ("Exit Worktree (remove)" . "Please exit the worktree and remove it — discard all changes.
")
 ("Merge Worktree" . "Please merge the worktree branch into master:
1. Exit the worktree if still inside
2. git checkout master
3. git merge --squash <branch-name>
4. Run make check
5. If tests pass, commit with a descriptive message
6. Clean up: git worktree remove .claude/worktrees/<name> && git branch -d <branch>
")
 ("Debug with Phoenix Traces" . "Please check recent Phoenix traces to understand what happened:

1. Query recent spans from the emacs-agent project:
   curl -s -X POST http://localhost:6006/graphql -H 'Content-Type: application/json' \\
     -d '{\"query\": \"query { node(id: \\\"UHJvamVjdDoy\\\") { ... on Project { spans(first: 20, sort: {col: startTime, dir: desc}) { edges { node { name spanId parentId spanKind statusCode startTime latencyMs attributes } } } } } }\"}' | jq '.data.node.spans.edges[].node | {name, statusCode, latencyMs, attrs: (.attributes | fromjson | keys)}'

2. Look for: error status spans, unusually high latency, missing child spans
3. For a specific span, fetch its full tree with descendants
4. Check input.value and output.value attributes for data flow issues
5. Report what you find and suggest fixes.
"))

;;; claude-org-templates.el ends here
