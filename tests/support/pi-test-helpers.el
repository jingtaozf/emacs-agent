;;; pi-test-helpers.el --- Shared helpers for Pi-backend live tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers shared between `test-claude-agent-pi-backend.el' (unit-level
;; smoke + live tests) and `test-e2e-pi-backend.el' (fixture-driven
;; story tests).  All helpers gracefully skip when Pi is absent.

;;; Code:

(require 'cl-lib)

(defun test-pi--available-p ()
  "Non-nil if Pi is installed AND configured (settings.json exists)."
  (and (executable-find "pi")
       (file-exists-p (expand-file-name "~/.pi/agent/settings.json"))))

(defun test-pi--mcp-available-p ()
  "Non-nil if the Emacs MCP HTTP server is responding on port 9999."
  (and (executable-find "curl")
       (zerop
        (call-process "curl" nil nil nil "-fsS" "--max-time" "1"
                      "-X" "POST"
                      "-H" "Content-Type: application/json"
                      "-d" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"
                      "http://localhost:9999/mcp"))))

(defun test-pi--extension-installed-p ()
  "Non-nil if the Pi extension tangle target exists at the standard path."
  (file-exists-p (expand-file-name "~/.pi/agent/extensions/emacs-mcp.ts")))

(defmacro test-pi--with-backend (varname &rest body)
  "Spawn a Pi backend bound to VARNAME, run BODY, always cleanup.
Pumps the event loop for ~1 s after cleanup so the graceful-shutdown
timers fire before the next test's spawn (otherwise port races appear)."
  (declare (indent 1) (debug t))
  `(let ((,varname (claude-agent-pi-backend-create
                    :session-key (format "live-%d" (random 100000)))))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (claude-agent-backend-cleanup ,varname))
       (let ((t0 (float-time)))
         (while (< (- (float-time) t0) 1.0)
           (accept-process-output nil 0.05))))))

(defun test-pi--wait-until (pred timeout)
  "Pump the event loop until PRED returns non-nil or TIMEOUT seconds pass.
Returns the final value of PRED (so callers can `should' against truthy)."
  (let ((deadline (+ (float-time) timeout)))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (sleep-for 0.02))
    (funcall pred)))

(provide 'pi-test-helpers)
;;; pi-test-helpers.el ends here
