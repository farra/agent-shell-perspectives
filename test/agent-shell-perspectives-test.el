;;; agent-shell-perspectives-test.el --- Tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with `just test'.  The lifecycle tests use real git against
;; repositories in a temporary directory; nothing touches the network.
;; agent-shell is stubbed, so it need not be installed.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-shell-perspectives)

;;; Fixtures

(defun asp-test--git (dir &rest args)
  "Run git with ARGS in DIR, signalling an error on failure."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (error "git %s failed: %s" (string-join args " ") (buffer-string)))
      (string-trim (buffer-string)))))

(defun asp-test--make-origin (dir)
  "Create an origin repository in DIR with a main and a feature branch."
  (make-directory dir t)
  (asp-test--git dir "init" "-q" "-b" "main")
  (asp-test--git dir "config" "user.email" "test@example.com")
  (asp-test--git dir "config" "user.name" "Test")
  (with-temp-file (expand-file-name "README.md" dir) (insert "# demo\n"))
  (asp-test--git dir "add" "README.md")
  (asp-test--git dir "commit" "-q" "-m" "init")
  (asp-test--git dir "branch" "feature/x")
  dir)

(defmacro asp-test--with-sandbox (&rest body)
  "Run BODY with a temporary stash, base directory and origin repository.
Binds `root' and `origin'.  The base directory has groups \"me\" and \"ref\"."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory
                 (file-truename (make-temp-file "asp-test-" t))))
          (origin (asp-test--make-origin (expand-file-name "origin/demo" root)))
          (agent-shell-perspectives-bare-dir (expand-file-name "stash" root))
          (agent-shell-perspectives-base-dir (expand-file-name "dev" root))
          (agent-shell-perspectives-extra-groups nil)
          (agent-shell-perspectives-default-group nil)
          (agent-shell-perspectives-open-functions nil)
          (process-environment (append '("GIT_CONFIG_GLOBAL=/dev/null"
                                         "GIT_AUTHOR_NAME=Test"
                                         "GIT_AUTHOR_EMAIL=test@example.com"
                                         "GIT_COMMITTER_NAME=Test"
                                         "GIT_COMMITTER_EMAIL=test@example.com")
                                       process-environment)))
     (ignore origin)
     (make-directory (expand-file-name "me" agent-shell-perspectives-base-dir) t)
     (make-directory (expand-file-name "ref" agent-shell-perspectives-base-dir) t)
     (unwind-protect
         (progn ,@body)
       (delete-directory root t))))

(defmacro asp-test--with-agents (agents &rest body)
  "Run BODY with agent-shell stubbed to report AGENTS.
AGENTS is a list of (BUFFER STATUS NAME)."
  (declare (indent 1))
  `(let ((agents ,agents))
     (cl-letf (((symbol-function 'agent-shell-buffers)
                (lambda () (mapcar #'car agents)))
               ((symbol-function 'agent-shell-status)
                (lambda (&rest args)
                  (nth 1 (assq (plist-get args :shell-buffer) agents))))
               ((symbol-function 'agent-shell-get-config)
                (lambda (buf) `((:buffer-name . ,(nth 2 (assq buf agents))))))
               ((symbol-function 'agent-shell--config-icon) (lambda (&rest _) nil))
               ((symbol-function 'agent-shell-subscribe-to) #'ignore))
       ,@body)))

(defun asp-test--agent-buffer (dir)
  "Return a fresh buffer whose `default-directory' is DIR."
  (let ((buf (generate-new-buffer "fake-agent")))
    (with-current-buffer buf
      (setq default-directory (file-name-as-directory dir)))
    buf))

;;; Naming

(ert-deftest asp-test-slug ()
  (should (equal (agent-shell-perspectives--slug "/d/me/demo-fix-auth" "demo")
                 "fix-auth"))
  (should (equal (agent-shell-perspectives--slug "/d/me/demo-fix-auth/" "demo")
                 "fix-auth"))
  (should (equal (agent-shell-perspectives--slug "/d/me/other" "demo") "other")))

(ert-deftest asp-test-workspace-name-ignores-branch ()
  "The name comes from the directory, so it survives branch switches."
  (should (equal (agent-shell-perspectives--workspace-name "/d/me/demo-fix-auth" "demo")
                 "demo/fix-auth"))
  (let ((agent-shell-perspectives-workspace-format "%s@%p"))
    (should (equal (agent-shell-perspectives--workspace-name "/d/me/demo-x" "demo")
                   "x@demo"))))

(ert-deftest asp-test-path-aliases ()
  (let ((agent-shell-perspectives-path-aliases '(("/asp-alias-a/" . "/asp-alias-b/"))))
    (should (equal (agent-shell-perspectives--canonical-path "/asp-alias-a/x/y")
                   "/asp-alias-b/x/y"))
    (should (agent-shell-perspectives--path-within-p "/asp-alias-a/x/y" "/asp-alias-b/x"))
    (should-not (agent-shell-perspectives--path-within-p "/asp-alias-b/xy" "/asp-alias-b/x"))))

(ert-deftest asp-test-normalize-url ()
  (should (equal (agent-shell-perspectives--normalize-url "farra/homebase")
                 "git@github.com:farra/homebase.git"))
  (should (equal (agent-shell-perspectives--normalize-url "https://example.com/a/b.git")
                 "https://example.com/a/b.git"))
  (should-error (agent-shell-perspectives--normalize-url "nonsense") :type 'user-error))

(ert-deftest asp-test-groups ()
  (asp-test--with-sandbox
    (should (equal (mapcar #'car (agent-shell-perspectives-groups)) '("me" "ref")))
    (let ((agent-shell-perspectives-extra-groups `(("elsewhere" . ,root))))
      (should (equal (mapcar #'car (agent-shell-perspectives-groups))
                     '("elsewhere" "me" "ref"))))
    (should (equal (agent-shell-perspectives--default-group) "me"))
    (should (equal (agent-shell-perspectives--worktree-dir "demo" "fix/auth" "ref")
                   (expand-file-name "ref/demo-fix-auth" agent-shell-perspectives-base-dir)))
    (should-error (agent-shell-perspectives--worktree-dir "demo" "x" "nope")
                  :type 'user-error)))

;;; Lifecycle

(ert-deftest asp-test-clone-create-checkout-dispose ()
  (asp-test--with-sandbox
    (let ((bare (agent-shell-perspectives-clone origin)))
      (should (file-directory-p bare))
      (should (equal (mapcar (lambda (c) (plist-get c :name))
                             (agent-shell-perspectives--bare-clones))
                     '("demo")))
      ;; Create a new branch from origin's default branch.
      (let ((wt (agent-shell-perspectives-create "demo" "fix/auth" "me")))
        (should (file-exists-p (expand-file-name "README.md" wt)))
        (should (equal (asp-test--git wt "branch" "--show-current") "fix/auth"))
        ;; Check out an existing remote branch into another group.
        (let ((wt2 (agent-shell-perspectives-checkout "demo" "feature/x" "ref")))
          (should (equal (asp-test--git wt2 "branch" "--show-current") "feature/x"))
          (should (equal (asp-test--git wt2 "rev-parse" "--abbrev-ref" "@{u}")
                         "origin/feature/x"))
          (let* ((projects (agent-shell-perspectives--all-projects))
                 (by-group (agent-shell-perspectives--projects-by-group projects)))
            (should (equal (mapcar #'car by-group) '("me" "ref" "bare")))
            (should (equal (mapcar (lambda (w) (plist-get w :branch))
                                   (plist-get (cadr (assoc "me" by-group)) :worktrees))
                           '("fix/auth"))))
          ;; Dispose of one; the other is untouched.
          (agent-shell-perspectives--dispose wt "demo" bare)
          (should-not (file-exists-p wt))
          (should (file-exists-p wt2))
          (should (equal (length (agent-shell-perspectives--worktrees bare)) 1)))))))

(ert-deftest asp-test-create-refuses-existing-dir ()
  (asp-test--with-sandbox
    (agent-shell-perspectives-clone origin)
    (agent-shell-perspectives-create "demo" "one" "me")
    (should-error (agent-shell-perspectives-create "demo" "one" "me") :type 'user-error)))

(ert-deftest asp-test-dispose-when-already-deleted ()
  "Disposing of a worktree deleted behind our back prunes git's record."
  (asp-test--with-sandbox
    (let* ((bare (agent-shell-perspectives-clone origin))
           (wt (agent-shell-perspectives-create "demo" "gone" "me")))
      (delete-directory wt t)
      (agent-shell-perspectives--dispose wt "demo" bare)
      (should (null (agent-shell-perspectives--worktrees bare))))))

(ert-deftest asp-test-dispose-warnings ()
  (asp-test--with-sandbox
    (agent-shell-perspectives-clone origin)
    (let ((wt (agent-shell-perspectives-create "demo" "dirty" "me")))
      (asp-test--with-agents nil
        (should (null (agent-shell-perspectives--dispose-warnings wt)))
        (with-temp-file (expand-file-name "new.txt" wt) (insert "x"))
        (should (equal (agent-shell-perspectives--dispose-warnings wt)
                       '("uncommitted changes"))))
      (let ((buf (asp-test--agent-buffer wt)))
        (unwind-protect
            (asp-test--with-agents (list (list buf 'ready "Claude Code"))
              (should (member "1 agent session(s), which will be killed"
                              (agent-shell-perspectives--dispose-warnings wt))))
          (kill-buffer buf))))))

(ert-deftest asp-test-dispose-kills-agents ()
  (asp-test--with-sandbox
    (let* ((bare (agent-shell-perspectives-clone origin))
           (wt (agent-shell-perspectives-create "demo" "agents" "me"))
           (inside (asp-test--agent-buffer (expand-file-name "sub" wt)))
           (outside (asp-test--agent-buffer root)))
      (unwind-protect
          (asp-test--with-agents (list (list inside 'busy "Claude Code")
                                       (list outside 'ready "Codex"))
            (agent-shell-perspectives--dispose wt "demo" bare)
            (should-not (buffer-live-p inside))
            (should (buffer-live-p outside)))
        (kill-buffer outside)))))

;;; Dashboard

(defun asp-test--render ()
  "Render the dashboard into a temporary buffer and return its text."
  (with-temp-buffer
    (agent-shell-perspectives--render)
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest asp-test-render ()
  (asp-test--with-sandbox
    (agent-shell-perspectives-clone origin)
    (let* ((wt (agent-shell-perspectives-create "demo" "work" "me"))
           (_dormant (agent-shell-perspectives-create "demo" "idle" "ref"))
           (in-wt (asp-test--agent-buffer wt))
           (loose (asp-test--agent-buffer root)))
      (unwind-protect
          (asp-test--with-agents (list (list in-wt 'busy "Claude Code")
                                       (list loose 'blocked "Codex"))
            (clrhash agent-shell-perspectives--show-dormant)
            (let ((text (asp-test--render)))
              ;; The worktree with an agent is active and shows the agent.
              (should (string-match-p "me .*1 active" text))
              (should (string-match-p "work\n.*Claude Code +busy" text))
              ;; The idle worktree is collapsed away as dormant.
              (should (string-match-p "ref .*0 active  \\+1" text))
              (should-not (string-match-p "idle" text))
              ;; The agent outside any worktree is listed under sessions.
              (should (string-match-p "sessions .* 1\n" text))
              (should (string-match-p "Codex +blocked" text)))
            ;; Showing dormant worktrees reveals the idle one.
            (puthash "ref" t agent-shell-perspectives--show-dormant)
            (should (string-match-p "idle" (asp-test--render))))
        (clrhash agent-shell-perspectives--show-dormant)
        (kill-buffer in-wt)
        (kill-buffer loose)))))

(ert-deftest asp-test-render-branch-drift ()
  "A worktree whose branch was switched keeps its name and shows the branch."
  (asp-test--with-sandbox
    (agent-shell-perspectives-clone origin)
    (let ((wt (agent-shell-perspectives-create "demo" "orig" "me")))
      (asp-test--git wt "switch" "-q" "-c" "agent-made")
      (with-temp-file (expand-file-name "x" wt) (insert "x"))
      (asp-test--with-agents nil
        (should (string-match-p "orig \\[agent-made\\]" (asp-test--render)))))))

(ert-deftest asp-test-render-empty ()
  (asp-test--with-sandbox
    (asp-test--with-agents nil
      (should (string-match-p "No bare clones" (asp-test--render))))))

;;; Perspectives

(ert-deftest asp-test-perspectives ()
  "Opening a worktree creates its perspective; disposing of it kills it."
  (skip-unless (require 'persp-mode nil t))
  (asp-test--with-sandbox
    (let ((persp-auto-resume-time -1)
          (persp-auto-save-opt 0)
          (persp-save-dir (expand-file-name "persp/" root)))
      (persp-mode 1)
      (unwind-protect
          (asp-test--with-agents nil
            (let* ((bare (agent-shell-perspectives-clone origin))
                   (wt (agent-shell-perspectives-create "demo" "p" "me")))
              (should (member "demo/p" (persp-names-current-frame-fast-ordered)))
              (should (equal (safe-persp-name (get-current-persp)) "demo/p"))
              ;; An open perspective makes the worktree active.
              (should (string-match-p "me .*1 active" (asp-test--render)))
              ;; Branch drift doesn't create a second perspective.
              (asp-test--git wt "switch" "-q" "-c" "drifted")
              (persp-switch "none")
              (should (agent-shell-perspectives--open wt "demo"))
              (should (equal (safe-persp-name (get-current-persp)) "demo/p"))
              (should-not (member "demo/drifted" (persp-names-current-frame-fast-ordered)))
              (agent-shell-perspectives--dispose wt "demo" bare)
              (should-not (member "demo/p" (persp-names-current-frame-fast-ordered)))))
        (persp-mode -1)))))

(provide 'agent-shell-perspectives-test)
;;; agent-shell-perspectives-test.el ends here
