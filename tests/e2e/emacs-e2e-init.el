;;; emacs-e2e-init.el --- Boot script for E2E Emacs tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jingtao Xu

;;; Commentary:

;; Minimal init for E2E testing.  Loads the project via literate-elisp,
;; starts the MCP server on a specified port, and keeps Emacs alive
;; so the test harness can send HTTP requests.

;;; Code:

(require 'literate-elisp)

;; Load project source
(let ((project-root (file-name-directory
                     (directory-file-name
                      (file-name-directory
                       (directory-file-name
                        (file-name-directory (or load-file-name
                                                 default-directory))))))))
  (literate-elisp-load (expand-file-name "lp/chat/code-agent.org" project-root))
  (literate-elisp-load (expand-file-name "lp/sdk/emacs-mcp-server.org" project-root))
  (literate-elisp-load (expand-file-name "lp/org/code-agent-org.org" project-root)))

(defun emacs-e2e-start-server (port)
  "Start the MCP HTTP server on PORT for E2E testing."
  (require 'emacs-mcp-server)
  (setq emacs-mcp-server-default-port port)
  (emacs-mcp-server-start)
  (message "E2E: MCP server started on port %d" port))

(defun emacs-e2e-wait-forever ()
  "Keep Emacs alive, accepting process output.
This prevents batch Emacs from exiting so the test harness can
communicate via HTTP."
  (message "E2E: Emacs waiting for requests...")
  (while t
    (accept-process-output nil 1)))

(provide 'emacs-e2e-init)
;;; emacs-e2e-init.el ends here
