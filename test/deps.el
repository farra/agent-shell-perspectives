;;; deps.el --- Install test dependencies into .deps/ -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded first by every `just' recipe.  Installs magit, persp-mode and
;; the lint tools from MELPA into the repository's .deps/ directory, so
;; the tests never touch your own Emacs packages.  agent-shell is not
;; installed: the tests stub it.

;;; Code:

(require 'package)
(setq package-user-dir (expand-file-name ".deps" (file-name-directory
                                                 (directory-file-name
                                                  (file-name-directory load-file-name))))
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(let ((wanted '(magit persp-mode package-lint)))
  (unless (seq-every-p #'package-installed-p wanted)
    (package-refresh-contents)
    (dolist (pkg wanted)
      (unless (package-installed-p pkg)
        (package-install pkg)))))

;;; deps.el ends here
