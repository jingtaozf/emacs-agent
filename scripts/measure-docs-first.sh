#!/usr/bin/env bash
# measure-docs-first.sh — score docs-first reflex adoption over recent commits
#
# For each commit in the last N (default 20) that touched a literate
# .org file (claude-agent*.org, code-agent-org-*.org,
# claude-agent-python.org), classify it into one of four buckets:
#
#   1. CO-EDIT      — both prose lines and src-block lines changed.
#                     The docs-first signal we want.
#   2. PROSE-ONLY   — only prose lines changed.  Docs maintenance.
#   3. BYPASS       — only src lines changed AND commit message
#                     contains a stated-bypass phrase.
#   4. VIOLATION    — only src lines changed and NO stated bypass.
#                     This is what we want to drive to zero.
#
# Output: a one-line tally + a per-commit table.
#
# Usage:
#   scripts/measure-docs-first.sh           # last 20 .org-touching commits
#   scripts/measure-docs-first.sh 50        # last 50
#   scripts/measure-docs-first.sh 50 v0.5..HEAD   # within a revrange

set -euo pipefail

N="${1:-20}"
REVRANGE="${2:-HEAD}"

FILE_PATTERN='claude-agent.*\.org$|code-agent-org.*\.org$|claude-agent-python\.org$'
BYPASS_RE='trivial[;:]? skipping prose|mechanical (rename|format|bump)|dependency bump|test-only|revert[;:]? prose'

declare -i N_COEDIT=0 N_PROSE=0 N_BYPASS=0 N_VIO=0

# Collect commits touching any literate .org file
COMMITS=$(git log --format='%H' -n "$N" "$REVRANGE" -- \
  $(git ls-files | grep -E "$FILE_PATTERN" 2>/dev/null) 2>/dev/null \
  | head -n "$N" || true)

if [[ -z "$COMMITS" ]]; then
  echo "no commits matched"
  exit 0
fi

printf '%-12s  %-9s  %s\n' "commit" "verdict" "subject"
printf '%-12s  %-9s  %s\n' "------------" "---------" "-------------------------------"

for sha in $COMMITS; do
  # Classify diff lines:
  # - "prose" line = added/removed line that is NOT inside a
  #   #+BEGIN_SRC ... #+END_SRC block, in a literate .org file.
  # - "src" line = added/removed line inside such a block.
  #
  # Implementation: walk diff hunks for matching files; track an
  # in-src-block flag that flips on #+begin_src and back on
  # #+end_src; count +/- lines by flag.
  read -r prose_lines src_lines <<<"$(
    git show "$sha" -- \
      $(git diff-tree --no-commit-id --name-only -r "$sha" \
          | grep -E "$FILE_PATTERN" || true) \
    2>/dev/null | awk '
      # Classify each +/- diff line by content heuristic.
      # Reliable across hunks (state-machine on #+begin_src failed
      # when hunks were entirely WITHIN a src block — no boundary in
      # the diff so the default "prose" was wrong).
      /^[+-][^+-]/ {
        body = substr($0, 2)
        if (body ~ /^[[:space:]]*\((defun|cl-defun|defcustom|defvar|cl-defstruct|cl-defgeneric|cl-defmethod|defmacro|let\*?|when|unless|if|cond|setf|setq|require|provide|dolist|while|save-excursion|with-current-buffer|condition-case|ignore-errors|interactive)/ ||
            body ~ /^[[:space:]]*(def |class |from .* import|import |return |if |elif |else:|for |while |try:|except|raise |yield |async )/ ||
            body ~ /^[[:space:]]*#\+(begin_src|end_src|name:|property:|BEGIN_SRC|END_SRC|NAME:|PROPERTY:)/ ||
            body ~ /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=[[:space:]]/ ||
            body ~ /^[[:space:]]*[)}]/ ||
            body ~ /^[[:space:]]*;;[[:space:]]/) {
          src++
        } else if (body ~ /[a-z][.!?]([[:space:]]|$)/ ||
                   body ~ /^[[:space:]]*\*+[[:space:]]/ ||
                   body ~ /^[[:space:]]*[-+*][[:space:]][A-Z]/ ||
                   body ~ /^[[:space:]]*\|/) {
          prose++
        }
      }
      END { print prose+0, src+0 }
    '
  )"
  subj=$(git log -1 --format='%s' "$sha")

  if (( prose_lines > 0 && src_lines > 0 )); then
    verdict=CO-EDIT
    N_COEDIT+=1
  elif (( prose_lines > 0 && src_lines == 0 )); then
    verdict=PROSE-ONLY
    N_PROSE+=1
  else
    # src-only — check for stated bypass in subject + body
    body=$(git log -1 --format='%B' "$sha")
    if echo "$body" | grep -Eqi "$BYPASS_RE"; then
      verdict=BYPASS
      N_BYPASS+=1
    else
      verdict=VIOLATION
      N_VIO+=1
    fi
  fi
  printf '%-12s  %-9s  %s\n' "${sha:0:12}" "$verdict" "${subj:0:60}"
done

total=$(( N_COEDIT + N_PROSE + N_BYPASS + N_VIO ))
echo
echo "tally over ${total} .org-touching commits:"
printf '  CO-EDIT     %3d  (%.0f%%)  ← docs-first signal\n'   "$N_COEDIT"  "$(awk "BEGIN{print 100*$N_COEDIT/$total}")"
printf '  PROSE-ONLY  %3d  (%.0f%%)\n'                          "$N_PROSE"   "$(awk "BEGIN{print 100*$N_PROSE/$total}")"
printf '  BYPASS      %3d  (%.0f%%)  ← legitimate skips\n'      "$N_BYPASS"  "$(awk "BEGIN{print 100*$N_BYPASS/$total}")"
printf '  VIOLATION   %3d  (%.0f%%)  ← drive to zero\n'         "$N_VIO"     "$(awk "BEGIN{print 100*$N_VIO/$total}")"
