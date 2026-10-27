;;; agent-shell-perspectives.el --- Worktrees as perspectives with agents -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2026 J. Aaron Farr
;;
;; Author: J. Aaron Farr <jaaron@users.noreply.github.com>
;; Maintainer: J. Aaron Farr <jaaron@users.noreply.github.com>
;; Created: February 17, 2026
;; Version: 0.1.0
;; Keywords: tools, vc, convenience
;; URL: https://github.com/farra/agent-shell-perspectives
;; Package-Requires: ((emacs "29.1") (magit "4.0") (persp-mode "3.0") (agent-shell "0.88"))
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.
;;
;;; Commentary:
;;
;; An opinionated workflow for running coding agents in Emacs:
;;
;;   one piece of work = one git worktree = one perspective = N agents
;;
;; Bare clones live in a stash (`agent-shell-perspectives-bare-dir').
;; Worktrees are checked out from them into group directories (each
;; subdirectory of `agent-shell-perspectives-base-dir' is a group).
;; Every worktree gets its own persp-mode perspective, and every
;; agent-shell session started there belongs to it.
;;
;; A dashboard in a side window shows the groups, their worktrees with
;; git status, and the agents running in each worktree with their
;; status.  From the dashboard you can clone, create and check out
;; worktrees, jump to a worktree or agent (switching perspective),
;; start agents, and dispose of a worktree together with its
;; perspective and agents.  Agent sessions that run outside any
;; worktree are listed too, under "sessions".
;;
;; With magit's forge package installed, you can also turn GitHub
;; issues into worktrees with an agent primed with the issue text.
;;
;; Setup:
;;
;;   (require 'agent-shell-perspectives)
;;   (agent-shell-perspectives-setup)
;;   (keymap-global-set "C-c w" agent-shell-perspectives-command-map)
;;
;; Then `M-x agent-shell-perspectives-dashboard' (or C-c w w).
;;
;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'magit)
(require 'magit-clone)
(require 'persp-mode)

;; Soft dependencies, checked at runtime.
(declare-function agent-shell-buffers "agent-shell" ())
(declare-function agent-shell-status "agent-shell" (&rest args))
(declare-function agent-shell-get-config "agent-shell" (buffer))
(declare-function agent-shell-subscribe-to "agent-shell" (&rest args))
(declare-function agent-shell--config-icon "agent-shell" (&rest args))
(declare-function agent-shell-new-shell "agent-shell" ())
(declare-function agent-shell-start "agent-shell" (&rest args))
(declare-function agent-shell-select-config "agent-shell" (&rest args))
(declare-function agent-shell-insert "agent-shell" (&rest args))
(defvar agent-shell-agent-configs)
(declare-function +workspace/new "ext:+workspace" (&optional name clone-p))
(declare-function +workspace/switch-to "ext:+workspace" (index))
(declare-function +workspace/kill "ext:+workspace" (name))
(declare-function +workspace-list-names "ext:+workspace" ())
(declare-function forge-get-repository "forge-core" (&rest demand))
(declare-function forge--list-topics "forge-topics" (spec &optional repo))
(declare-function forge--topics-spec "forge-topics" (&rest args))
(declare-function projectile-remove-known-project "projectile" (project-root))
(declare-function nerd-icons-codicon "nerd-icons" (icon-name &rest args))
(declare-function nerd-icons-devicon "nerd-icons" (icon-name &rest args))
(declare-function nerd-icons-faicon "nerd-icons" (icon-name &rest args))

;;; Customization

(defgroup agent-shell-perspectives nil
  "Git worktrees as perspectives, with their agent-shell sessions."
  :group 'tools
  :prefix "agent-shell-perspectives-")

(defcustom agent-shell-perspectives-bare-dir "~/dev/.worktrees"
  "Directory holding the stash of bare clones (NAME.git)."
  :type 'directory)

(defcustom agent-shell-perspectives-base-dir "~/dev"
  "Parent directory of the worktree groups.
Each non-hidden subdirectory is a group.  Create a directory here and
it appears in the dashboard."
  :type 'directory)

(defcustom agent-shell-perspectives-extra-groups nil
  "Groups outside `agent-shell-perspectives-base-dir'.
An alist of (NAME . DIRECTORY), merged with the discovered groups."
  :type '(alist :key-type string :value-type directory))

(defcustom agent-shell-perspectives-default-group nil
  "Group offered by default for new worktrees.
When nil, the first group is offered."
  :type '(choice (const :tag "First group" nil) string))

(defcustom agent-shell-perspectives-workspace-format "%p/%s"
  "Format for perspective names.
%p is the project name and %s the worktree slug.  The slug comes
from the worktree's directory name, which never changes, rather than
from its branch, which agents may switch."
  :type 'string)

(defcustom agent-shell-perspectives-path-aliases '(("/var/home/" . "/home/"))
  "Path prefixes that name the same place, as (FROM . TO) pairs.
Used when matching agent buffers and groups to worktrees.  The
default covers systems such as Fedora Atomic, where /home is a
mount of /var/home that `file-truename' cannot see through."
  :type '(alist :key-type string :value-type string))

(defcustom agent-shell-perspectives-open-functions
  '(agent-shell-perspectives-visit-readme)
  "Functions called with a worktree path after its perspective is created.
The perspective is already current.  The default visits a README so
that project tools detect the right root."
  :type 'hook)

(defcustom agent-shell-perspectives-dashboard-buffer "*Agent Perspectives*"
  "Buffer name for the dashboard."
  :type 'string)

(defcustom agent-shell-perspectives-dashboard-side 'right
  "Side of the frame for the dashboard, or nil to let `display-buffer' choose."
  :type '(choice (const left) (const right) (const top) (const bottom)
                 (const :tag "display-buffer" nil)))

(defcustom agent-shell-perspectives-dashboard-width 50
  "Width of the dashboard when shown on the left or right."
  :type 'integer)

(defcustom agent-shell-perspectives-refresh-interval 10
  "Seconds between dashboard refreshes for git status.  0 disables.
Agent status updates arrive as agent-shell events and don't wait
for this timer."
  :type 'integer)

(defcustom agent-shell-perspectives-agent-icons t
  "When non-nil, show each agent's config icon in the dashboard."
  :type 'boolean)

(defcustom agent-shell-perspectives-issue-agent-config nil
  "Identifier of the agent config used for issue worktrees.
When nil, prompt for the agent each time."
  :type '(choice (const :tag "Prompt" nil) symbol))

(defcustom agent-shell-perspectives-issue-branch-prefix "issue/"
  "Branch name prefix for worktrees created from issues."
  :type 'string)

;;; Icons

(defun agent-shell-perspectives--icon (key &optional face)
  "Return an icon string for KEY with optional FACE.
Uses nerd-icons when available, ASCII otherwise.  KEY is one of
`chevron-down', `chevron-right', `git-branch', `robot' or `dot'."
  (if (fboundp 'nerd-icons-codicon)
      (pcase key
        ('chevron-down (nerd-icons-codicon "nf-cod-chevron_down" :face face))
        ('chevron-right (nerd-icons-codicon "nf-cod-chevron_right" :face face))
        ('git-branch (nerd-icons-devicon "nf-dev-git_branch" :face face))
        ('robot (nerd-icons-faicon "nf-fa-robot" :face face))
        ('dot (nerd-icons-codicon "nf-cod-circle_filled" :face face)))
    (let ((ch (pcase key
                ('chevron-down "v") ('chevron-right ">")
                ('git-branch "") ('robot ">") ('dot "*"))))
      (if face (propertize ch 'face face) ch))))

;;; Paths and groups

(defun agent-shell-perspectives--canonical-path (path)
  "Return PATH resolved, with `agent-shell-perspectives-path-aliases' applied."
  (let ((resolved (file-truename path)))
    (or (seq-some (lambda (alias)
                    (when (string-prefix-p (car alias) resolved)
                      (concat (cdr alias) (substring resolved (length (car alias))))))
                  agent-shell-perspectives-path-aliases)
        resolved)))

(defun agent-shell-perspectives--path-within-p (path dir)
  "Return non-nil if PATH is DIR or inside it, after canonicalizing both."
  (string-prefix-p
   (file-name-as-directory (agent-shell-perspectives--canonical-path dir))
   (file-name-as-directory (agent-shell-perspectives--canonical-path path))))

(defun agent-shell-perspectives-groups ()
  "Return the worktree groups as an alist of (NAME . DIRECTORY), sorted by name."
  (let ((base (expand-file-name agent-shell-perspectives-base-dir))
        (result (copy-alist agent-shell-perspectives-extra-groups)))
    (when (file-directory-p base)
      (dolist (path (directory-files base t "\\`[^.]" t))
        (let ((name (file-name-nondirectory path)))
          (when (and (file-directory-p path) (not (assoc name result)))
            (push (cons name path) result)))))
    (sort result (lambda (a b) (string< (car a) (car b))))))

(defun agent-shell-perspectives--find-group (path)
  "Return the name of the group containing PATH, or nil."
  (car (seq-find (lambda (group)
                   (agent-shell-perspectives--path-within-p path (cdr group)))
                 (agent-shell-perspectives-groups))))

;;; Discovery

(defun agent-shell-perspectives--bare-clones ()
  "Return the stashed bare clones as plists (:name NAME :path PATH)."
  (let ((dir (expand-file-name agent-shell-perspectives-bare-dir)))
    (when (file-directory-p dir)
      (sort (mapcar (lambda (path)
                      (list :name (file-name-sans-extension
                                   (file-name-nondirectory path))
                            :path path))
                    (seq-filter #'file-directory-p
                                (directory-files dir t "\\.git\\'" t)))
            (lambda (a b) (string< (plist-get a :name) (plist-get b :name)))))))

(defun agent-shell-perspectives--bare-path (project)
  "Return the bare clone path for PROJECT, or signal a user error."
  (or (plist-get (seq-find (lambda (c) (string= (plist-get c :name) project))
                           (agent-shell-perspectives--bare-clones))
                 :path)
      (user-error "No bare clone found for: %s" project)))

(defun agent-shell-perspectives--worktrees (bare-path)
  "Return the worktrees of the bare clone at BARE-PATH.
Each is a list (PATH COMMIT BRANCH), as from `magit-list-worktrees',
without the bare repository itself."
  (let ((default-directory (file-name-as-directory bare-path)))
    (seq-remove (lambda (wt) (nth 3 wt)) (magit-list-worktrees))))

(defun agent-shell-perspectives--all-projects ()
  "Return every stashed project with its worktrees.
Each project is (:project NAME :bare-path PATH :worktrees WTS), and
each worktree is (:path PATH :branch BRANCH :group GROUP)."
  (mapcar
   (lambda (clone)
     (let ((bare-path (plist-get clone :path)))
       (list :project (plist-get clone :name)
             :bare-path bare-path
             :worktrees
             (mapcar (lambda (wt)
                       (list :path (nth 0 wt)
                             :branch (or (nth 2 wt) "detached")
                             :group (agent-shell-perspectives--find-group (nth 0 wt))))
                     (agent-shell-perspectives--worktrees bare-path)))))
   (agent-shell-perspectives--bare-clones)))

(defun agent-shell-perspectives--projects-by-group (projects)
  "Arrange PROJECTS by group, as an alist of (GROUP . PROJECTS).
Within a group, each project carries only that group's worktrees.
A final \"bare\" group lists every project as an index.  Empty
groups are dropped."
  (let ((result (mapcar (lambda (g) (list (car g)))
                        (agent-shell-perspectives-groups))))
    (dolist (proj projects)
      (dolist (entry result)
        (when-let* ((wts (seq-filter (lambda (wt)
                                       (equal (plist-get wt :group) (car entry)))
                                     (plist-get proj :worktrees))))
          (setcdr entry (append (cdr entry)
                                (list (plist-put (copy-sequence proj)
                                                 :worktrees wts)))))))
    (when projects
      (setq result (append result (list (cons "bare" projects)))))
    (seq-filter #'cdr result)))

;;; Naming

(defun agent-shell-perspectives--slug (path project)
  "Return the slug for the worktree at PATH of PROJECT.
That is the directory name without the \"PROJECT-\" prefix."
  (let ((dirname (file-name-nondirectory (directory-file-name path)))
        (prefix (concat project "-")))
    (if (string-prefix-p prefix dirname)
        (substring dirname (length prefix))
      dirname)))

(defun agent-shell-perspectives--workspace-name (path project)
  "Return the perspective name for the worktree at PATH of PROJECT."
  (format-spec agent-shell-perspectives-workspace-format
               `((?p . ,project)
                 (?s . ,(agent-shell-perspectives--slug path project)))))

(defun agent-shell-perspectives--worktree-dir (project branch group)
  "Return the directory for a worktree of PROJECT on BRANCH in GROUP."
  (let ((group-dir (or (cdr (assoc group (agent-shell-perspectives-groups)))
                       (user-error "Unknown group: %s" group))))
    (expand-file-name (format "%s-%s" project (string-replace "/" "-" branch))
                      group-dir)))

;;; Perspectives
;;
;; Doom's workspace functions wrap persp-mode and do some extra
;; bookkeeping, so use them when they're present.

(defun agent-shell-perspectives--doom-p ()
  "Return non-nil when Doom's workspace functions are available."
  (fboundp '+workspace-list-names))

(defun agent-shell-perspectives--persp-active-p ()
  "Return non-nil when `persp-mode' is on."
  (bound-and-true-p persp-mode))

(defun agent-shell-perspectives--workspace-names ()
  "Return the names of the open perspectives."
  (cond ((agent-shell-perspectives--doom-p) (+workspace-list-names))
        ((agent-shell-perspectives--persp-active-p)
         (persp-names-current-frame-fast-ordered))))

(defun agent-shell-perspectives--workspace-exists-p (name)
  "Return non-nil if a perspective called NAME is open."
  (member name (agent-shell-perspectives--workspace-names)))

(defun agent-shell-perspectives--workspace-create (name)
  "Create the perspective NAME and make it current."
  (cond ((agent-shell-perspectives--doom-p) (+workspace/new name))
        ((agent-shell-perspectives--persp-active-p) (persp-switch name))))

(defun agent-shell-perspectives--workspace-switch (name)
  "Switch to the perspective NAME if it is open.  Return non-nil on success."
  (when (agent-shell-perspectives--workspace-exists-p name)
    (if (agent-shell-perspectives--doom-p)
        (+workspace/switch-to name)
      (persp-switch name))
    t))

(defun agent-shell-perspectives--workspace-kill (name)
  "Kill the perspective NAME, and its buffers, if it is open."
  (when (agent-shell-perspectives--workspace-exists-p name)
    (if (agent-shell-perspectives--doom-p)
        (+workspace/kill name)
      (persp-kill name))))

(defun agent-shell-perspectives-visit-readme (path)
  "Visit the README in PATH, or open PATH in Dired if there is none."
  (let ((file (seq-find #'file-exists-p
                        (mapcar (lambda (f) (expand-file-name f path))
                                '("README.md" "README.org" "README.rst" "README")))))
    (if file (find-file file) (dired path))))

(defun agent-shell-perspectives--open (path project)
  "Make the worktree at PATH of PROJECT the current perspective.
Switch to its perspective if open, or create it.  Return nil, after
killing any leftover perspective, if PATH no longer exists.  If the
dashboard was showing, show it again in the new perspective."
  (let ((name (agent-shell-perspectives--workspace-name path project))
        (dashboard (get-buffer-window agent-shell-perspectives-dashboard-buffer)))
    (cond
     ((not (file-directory-p path))
      (agent-shell-perspectives--workspace-kill name)
      (message "Worktree no longer exists: %s" (abbreviate-file-name path))
      nil)
     (t
      (unless (agent-shell-perspectives--workspace-switch name)
        (let ((default-directory (file-name-as-directory path)))
          (agent-shell-perspectives--workspace-create name)
          (run-hook-with-args 'agent-shell-perspectives-open-functions path)))
      (when dashboard
        (agent-shell-perspectives--ensure-dashboard))
      t))))

;;; Git status

(defun agent-shell-perspectives--git-status (path)
  "Return a plist (:dirty BOOL :ahead N :behind N) for the worktree at PATH."
  (let ((default-directory (file-name-as-directory path)))
    (cl-flet ((count (range)
                (string-to-number
                 (or (magit-git-string "rev-list" "--count" range) "0"))))
      (list :dirty (magit-git-string "status" "--porcelain")
            :ahead (count "@{u}..HEAD")
            :behind (count "HEAD..@{u}")))))

;;; Agents

(defun agent-shell-perspectives--agent-name (buffer config)
  "Return a display name for the agent in BUFFER with CONFIG."
  (or (map-elt config :buffer-name)
      (and (string-match "\\`\\(.*?\\) Agent @ " (buffer-name buffer))
           (match-string 1 (buffer-name buffer)))
      "Agent"))

(defun agent-shell-perspectives--agent-plist (buffer)
  "Return a plist describing the agent-shell BUFFER."
  (let ((config (ignore-errors (agent-shell-get-config buffer))))
    (list :buffer buffer
          :name (agent-shell-perspectives--agent-name buffer config)
          :status (or (ignore-errors (agent-shell-status :shell-buffer buffer))
                      'unknown)
          :config config
          :directory (buffer-local-value 'default-directory buffer))))

(defun agent-shell-perspectives--all-agents ()
  "Return plists for all live agent-shell buffers."
  (when (fboundp 'agent-shell-buffers)
    (mapcar #'agent-shell-perspectives--agent-plist
            (seq-filter #'buffer-live-p (agent-shell-buffers)))))

(defun agent-shell-perspectives--agents-in (path &optional agents)
  "Return the AGENTS whose directory is in PATH.
AGENTS defaults to all live agents."
  (seq-filter (lambda (agent)
                (agent-shell-perspectives--path-within-p
                 (plist-get agent :directory) path))
              (or agents (agent-shell-perspectives--all-agents))))

(defvar agent-shell-perspectives--refresh-pending nil
  "Timer for a refresh requested by an agent event, or nil.")

(defun agent-shell-perspectives--request-refresh (&rest _)
  "Refresh the dashboard shortly, coalescing bursts of events."
  (unless agent-shell-perspectives--refresh-pending
    (setq agent-shell-perspectives--refresh-pending
          (run-with-timer 0.2 nil
                          (lambda ()
                            (setq agent-shell-perspectives--refresh-pending nil)
                            (agent-shell-perspectives-dashboard-refresh))))))

(defconst agent-shell-perspectives--agent-events
  '(init-finished input-submitted turn-complete permission-request
                  permission-response error clean-up)
  "Agent-shell events that change what the dashboard shows.")

(defvar-local agent-shell-perspectives--subscribed nil
  "Non-nil in an agent-shell buffer the dashboard listens to.")

(defun agent-shell-perspectives--subscribe (&optional buffer)
  "Refresh the dashboard on status changes of the agent-shell BUFFER.
BUFFER defaults to the current buffer."
  (with-current-buffer (or buffer (current-buffer))
    (unless agent-shell-perspectives--subscribed
      (setq agent-shell-perspectives--subscribed t)
      (agent-shell-subscribe-to
       :shell-buffer (current-buffer)
       :on-event (lambda (event)
                   (when (memq (map-elt event :event)
                               agent-shell-perspectives--agent-events)
                     (agent-shell-perspectives--request-refresh)))))))

(defun agent-shell-perspectives--subscribe-all ()
  "Subscribe to every live agent-shell buffer."
  (when (fboundp 'agent-shell-buffers)
    (mapc #'agent-shell-perspectives--subscribe
          (seq-filter #'buffer-live-p (agent-shell-buffers)))))

;;; Prompts

(defun agent-shell-perspectives--read-project ()
  "Read the name of a stashed project."
  (completing-read "Project: "
                   (mapcar (lambda (c) (plist-get c :name))
                           (agent-shell-perspectives--bare-clones))
                   nil t))

(defun agent-shell-perspectives--read-group ()
  "Read a group name."
  (let ((names (mapcar #'car (agent-shell-perspectives-groups))))
    (unless names
      (user-error "No groups: create a directory in %s"
                  agent-shell-perspectives-base-dir))
    (completing-read "Group: " names nil t nil nil
                     (or agent-shell-perspectives-default-group (car names)))))

(defun agent-shell-perspectives--default-group ()
  "Return the group for new worktrees when none is given."
  (or agent-shell-perspectives-default-group
      (caar (agent-shell-perspectives-groups))
      (user-error "No groups: create a directory in %s"
                  agent-shell-perspectives-base-dir)))

(defun agent-shell-perspectives--fetch (bare-path)
  "Fetch origin into the bare clone at BARE-PATH.
Add the usual fetch refspec first if the clone lacks one: bare clones
made with plain `git clone --bare' do, and then fetch brings nothing."
  (let ((default-directory (file-name-as-directory bare-path)))
    (unless (magit-git-string "config" "remote.origin.fetch")
      (magit-call-git "config" "remote.origin.fetch"
                      "+refs/heads/*:refs/remotes/origin/*"))
    (message "Fetching %s..." (file-name-nondirectory bare-path))
    (magit-call-git "fetch" "origin")))

(defun agent-shell-perspectives--read-remote-branch (project)
  "Fetch PROJECT and read one of its remote branches."
  (let ((bare-path (agent-shell-perspectives--bare-path project)))
    (agent-shell-perspectives--fetch bare-path)
    (let ((default-directory (file-name-as-directory bare-path)))
      (completing-read "Branch: "
                       (mapcar (lambda (b) (string-remove-prefix "origin/" b))
                               (magit-list-remote-branch-names "origin"))
                       nil t))))

;;; Commands

(defun agent-shell-perspectives--normalize-url (input)
  "Return a clone URL for INPUT.
INPUT is a URL, a magit shorthand such as gh:user/repo, or a bare
user/repo, which is taken to be on GitHub."
  (cond
   ((string-match-p "\\`\\(?:https?://\\|git@\\|ssh://\\|file://\\)" input) input)
   ((string-match-p ":" input) (magit-clone--name-to-url input))
   ((string-match-p "\\`[^/]+/[^/]+\\'" input)
    (format "git@github.com:%s.git" input))
   ((file-directory-p input) (expand-file-name input))
   (t (user-error "Can't parse repository: %s" input))))

;;;###autoload
(defun agent-shell-perspectives-clone (url)
  "Add a bare clone of URL to the stash.
URL may also be a magit shorthand (gh:user/repo) or a bare user/repo
on GitHub."
  (interactive (list (magit-clone-read-repository)))
  (let* ((url (agent-shell-perspectives--normalize-url url))
         (name (string-remove-suffix
                ".git" (file-name-nondirectory (directory-file-name url))))
         (dest (expand-file-name (concat name ".git")
                                 agent-shell-perspectives-bare-dir)))
    (when (file-exists-p dest)
      (user-error "Bare clone already exists: %s" dest))
    (make-directory (file-name-directory dest) t)
    (message "Cloning %s..." name)
    (magit-call-git "clone" "--bare" url dest)
    (agent-shell-perspectives--fetch dest)
    (let ((default-directory (file-name-as-directory dest)))
      (magit-call-git "remote" "set-head" "origin" "--auto"))
    (agent-shell-perspectives-dashboard-refresh)
    (message "Cloned %s into %s" name (abbreviate-file-name dest))
    dest))

(defun agent-shell-perspectives--start-point ()
  "Return the start point for a new branch in the current bare clone."
  (or (magit-git-string "symbolic-ref" "--short" "refs/remotes/origin/HEAD")
      (and (magit-rev-verify "origin/main") "origin/main")
      (and (magit-rev-verify "origin/master") "origin/master")
      "HEAD"))

;;;###autoload
(defun agent-shell-perspectives-create (project branch &optional group)
  "Create a worktree of PROJECT on a new BRANCH in GROUP and open it.
The branch starts from origin's default branch.  Return the worktree
path."
  (interactive
   (let ((project (agent-shell-perspectives--read-project)))
     (list project (read-string (format "New branch for %s: " project))
           (agent-shell-perspectives--read-group))))
  (let* ((group (or group (agent-shell-perspectives--default-group)))
         (bare-path (agent-shell-perspectives--bare-path project))
         (dest (agent-shell-perspectives--worktree-dir project branch group)))
    (when (file-exists-p dest)
      (user-error "Worktree directory already exists: %s" dest))
    (agent-shell-perspectives--fetch bare-path)
    (let ((default-directory (file-name-as-directory bare-path)))
      (magit-call-git "worktree" "add" "-b" branch dest
                      (agent-shell-perspectives--start-point)))
    (agent-shell-perspectives--open dest project)
    (agent-shell-perspectives-dashboard-refresh)
    (message "Created worktree %s (branch %s)" (abbreviate-file-name dest) branch)
    dest))

;;;###autoload
(defun agent-shell-perspectives-checkout (project branch &optional group)
  "Check out the existing BRANCH of PROJECT as a worktree in GROUP and open it.
Return the worktree path."
  (interactive
   (let ((project (agent-shell-perspectives--read-project)))
     (list project (agent-shell-perspectives--read-remote-branch project)
           (agent-shell-perspectives--read-group))))
  (let* ((group (or group (agent-shell-perspectives--default-group)))
         (bare-path (agent-shell-perspectives--bare-path project))
         (dest (agent-shell-perspectives--worktree-dir project branch group)))
    (when (file-exists-p dest)
      (user-error "Worktree directory already exists: %s" dest))
    (let ((default-directory (file-name-as-directory bare-path))
          (remote (concat "origin/" branch)))
      (if (magit-local-branch-p branch)
          (progn
            (magit-call-git "worktree" "add" dest branch)
            ;; `git clone --bare' copies every branch as a local branch
            ;; with no upstream, so connect it to its remote here.
            (when (and (magit-rev-verify remote)
                       (not (magit-get "branch" branch "remote")))
              (magit-call-git "branch" (concat "--set-upstream-to=" remote) branch)))
        (magit-call-git "worktree" "add" "--track" "-b" branch dest remote)))
    (agent-shell-perspectives--open dest project)
    (agent-shell-perspectives-dashboard-refresh)
    (message "Checked out %s (branch %s)" (abbreviate-file-name dest) branch)
    dest))

(defun agent-shell-perspectives--read-worktree (prompt)
  "Read a worktree with PROMPT.  Return (:project :path :bare-path)."
  (let ((choices
         (cl-loop for proj in (agent-shell-perspectives--all-projects)
                  for project = (plist-get proj :project)
                  append
                  (cl-loop for wt in (plist-get proj :worktrees)
                           for path = (plist-get wt :path)
                           collect
                           (cons (format "%s  (%s)"
                                         (agent-shell-perspectives--workspace-name
                                          path project)
                                         (abbreviate-file-name path))
                                 (list :project project :path path
                                       :bare-path (plist-get proj :bare-path)))))))
    (unless choices
      (user-error "No worktrees"))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

;;;###autoload
(defun agent-shell-perspectives-switch (project path)
  "Switch to the perspective of the worktree at PATH of PROJECT."
  (interactive
   (let ((wt (agent-shell-perspectives--read-worktree "Switch to worktree: ")))
     (list (plist-get wt :project) (plist-get wt :path))))
  (unless (agent-shell-perspectives--open path project)
    (user-error "Worktree no longer exists: %s" (abbreviate-file-name path))))

(defun agent-shell-perspectives--dispose-warnings (path)
  "Return reasons to think twice before disposing of the worktree at PATH."
  (let ((warnings '()))
    (when (file-directory-p path)
      (let ((status (agent-shell-perspectives--git-status path)))
        (when (plist-get status :dirty)
          (push "uncommitted changes" warnings))
        (when (> (plist-get status :ahead) 0)
          (push (format "%d unpushed commit(s)" (plist-get status :ahead))
                warnings))))
    (when-let* ((agents (agent-shell-perspectives--agents-in path)))
      (push (format "%d agent session(s), which will be killed" (length agents))
            warnings))
    (nreverse warnings)))

(defun agent-shell-perspectives--gitdir-bare (path bare-path)
  "Return the bare clone that the worktree at PATH points to.
Git compares worktree paths as strings, so on systems with two names
for the home directory, the path recorded in the worktree's .git file
can differ from BARE-PATH.  Fall back to BARE-PATH."
  (let* ((git-file (expand-file-name ".git" path))
         (gitdir (when (file-regular-p git-file)
                   (with-temp-buffer
                     (insert-file-contents git-file)
                     (when (looking-at "gitdir: \\(.+\\)")
                       (string-trim-right (match-string 1)))))))
    (if (and gitdir (string-match "/worktrees/[^/]+\\'" gitdir))
        (substring gitdir 0 (match-beginning 0))
      bare-path)))

(defun agent-shell-perspectives--dispose (path project bare-path)
  "Kill the agents and perspective of the worktree at PATH, then remove it.
PROJECT and BARE-PATH identify its clone.  The Emacs side is cleaned
up even when PATH is already gone or git fails."
  (let ((dashboard (get-buffer-window agent-shell-perspectives-dashboard-buffer)))
    (agent-shell-perspectives--dispose-1 path project bare-path)
    (when dashboard
      (agent-shell-perspectives--ensure-dashboard))))

(defun agent-shell-perspectives--dispose-1 (path project bare-path)
  "Do the work of `agent-shell-perspectives--dispose' for PATH, PROJECT, BARE-PATH."
  (dolist (agent (agent-shell-perspectives--agents-in path))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer (plist-get agent :buffer))))
  (when (fboundp 'projectile-remove-known-project)
    (projectile-remove-known-project (file-name-as-directory path)))
  (agent-shell-perspectives--workspace-kill
   (agent-shell-perspectives--workspace-name path project))
  (if (file-directory-p path)
      (condition-case err
          ;; Plain git rather than `magit-worktree-delete', which leaves
          ;; magit buffers behind in whichever perspective survives.
          (let ((default-directory (file-name-as-directory
                                    (agent-shell-perspectives--gitdir-bare
                                     path bare-path))))
            (magit-call-git "worktree" "remove" "--force" path))
        (error (message "git worktree remove failed for %s: %s"
                        (abbreviate-file-name path)
                        (error-message-string err))))
    (let ((default-directory (file-name-as-directory bare-path)))
      (magit-call-git "worktree" "prune"))))

;;;###autoload
(defun agent-shell-perspectives-dispose (project path bare-path)
  "Dispose of the worktree at PATH of PROJECT, whose clone is BARE-PATH.
Kill its agent sessions and perspective, then remove the worktree.
Ask first, listing uncommitted changes, unpushed commits and agents."
  (interactive
   (let ((wt (agent-shell-perspectives--read-worktree "Dispose of worktree: ")))
     (list (plist-get wt :project) (plist-get wt :path) (plist-get wt :bare-path))))
  (let ((name (agent-shell-perspectives--workspace-name path project))
        (warnings (agent-shell-perspectives--dispose-warnings path)))
    (when (yes-or-no-p
           (if warnings
               (format "Dispose of %s?  It has:\n  - %s\n" name
                       (string-join warnings "\n  - "))
             (format "Dispose of %s? " name)))
      (agent-shell-perspectives--dispose path project bare-path)
      (agent-shell-perspectives-dashboard-refresh)
      (message "Disposed of %s" name))))

;;;###autoload
(defun agent-shell-perspectives-cleanup-stale ()
  "Kill perspectives whose worktree is gone from disk."
  (interactive)
  (let ((cleaned 0))
    (dolist (proj (agent-shell-perspectives--all-projects))
      (dolist (wt (plist-get proj :worktrees))
        (let* ((path (plist-get wt :path))
               (name (agent-shell-perspectives--workspace-name
                      path (plist-get proj :project))))
          (when (and (not (file-directory-p path))
                     (agent-shell-perspectives--workspace-exists-p name)
                     (yes-or-no-p (format "Kill perspective %s (%s is gone)? "
                                          name (abbreviate-file-name path))))
            (agent-shell-perspectives--workspace-kill name)
            (cl-incf cleaned)))))
    (agent-shell-perspectives-dashboard-refresh)
    (message "Killed %d stale perspective(s)" cleaned)))

;;;###autoload
(defun agent-shell-perspectives-new-agent (project path)
  "Start a new agent-shell session in the worktree at PATH of PROJECT."
  (interactive
   (let ((wt (agent-shell-perspectives--read-worktree "Start agent in: ")))
     (list (plist-get wt :project) (plist-get wt :path))))
  (unless (agent-shell-perspectives--open path project)
    (user-error "Worktree no longer exists: %s" (abbreviate-file-name path)))
  (let ((default-directory (file-name-as-directory path)))
    (agent-shell-new-shell)))

;;; Dashboard

(defvar-keymap agent-shell-perspectives-dashboard-mode-map
  :parent special-mode-map
  "RET" #'agent-shell-perspectives-dashboard-visit
  "<mouse-1>" #'agent-shell-perspectives-dashboard-mouse-visit
  "TAB" #'agent-shell-perspectives-dashboard-toggle-group
  "D" #'agent-shell-perspectives-dashboard-toggle-all
  "C" #'agent-shell-perspectives-clone
  "c" #'agent-shell-perspectives-dashboard-create
  "o" #'agent-shell-perspectives-dashboard-checkout
  "d" #'agent-shell-perspectives-dashboard-dispose
  "a" #'agent-shell-perspectives-dashboard-agent
  "m" #'agent-shell-perspectives-dashboard-magit
  "i" #'agent-shell-perspectives-dashboard-issue
  "S" #'agent-shell-perspectives-cleanup-stale
  "g" #'agent-shell-perspectives-dashboard-refresh)

(defvar agent-shell-perspectives--show-dormant (make-hash-table :test 'equal)
  "Groups whose dormant worktrees are shown, keyed by group name.")

(defvar agent-shell-perspectives--refresh-timer nil
  "Timer refreshing the dashboard for git status.")

(defvar agent-shell-perspectives--cache nil
  "Hash table of git status by path, bound during a render.")

(define-derived-mode agent-shell-perspectives-dashboard-mode special-mode
  "Perspectives"
  "Dashboard of worktrees, their perspectives and agent sessions.

\\{agent-shell-perspectives-dashboard-mode-map}"
  (setq truncate-lines t)
  (add-hook 'kill-buffer-hook #'agent-shell-perspectives--stop-timer nil t))

(defun agent-shell-perspectives--start-timer ()
  "Start the git status refresh timer."
  (when (and (> agent-shell-perspectives-refresh-interval 0)
             (not agent-shell-perspectives--refresh-timer))
    (setq agent-shell-perspectives--refresh-timer
          (run-with-timer agent-shell-perspectives-refresh-interval
                          agent-shell-perspectives-refresh-interval
                          #'agent-shell-perspectives-dashboard-refresh))))

(defun agent-shell-perspectives--stop-timer ()
  "Stop the git status refresh timer."
  (when agent-shell-perspectives--refresh-timer
    (cancel-timer agent-shell-perspectives--refresh-timer)
    (setq agent-shell-perspectives--refresh-timer nil)))

(defun agent-shell-perspectives--status (path)
  "Return the git status of PATH, cached for the current render."
  (if agent-shell-perspectives--cache
      (with-memoization (gethash path agent-shell-perspectives--cache)
        (agent-shell-perspectives--git-status path))
    (agent-shell-perspectives--git-status path)))

(defun agent-shell-perspectives--active-p (path project agents)
  "Return non-nil if the worktree at PATH of PROJECT is in use.
That is, it has an open perspective, is dirty or ahead of its
upstream, or has some of AGENTS running in it."
  (or (agent-shell-perspectives--workspace-exists-p
       (agent-shell-perspectives--workspace-name path project))
      (let ((status (agent-shell-perspectives--status path)))
        (or (plist-get status :dirty)
            (> (plist-get status :ahead) 0)))
      (agent-shell-perspectives--agents-in path agents)))

(defun agent-shell-perspectives--entry-at-point ()
  "Return the dashboard entry on the current line."
  (get-text-property (line-beginning-position) 'agent-shell-perspectives-entry))

(defun agent-shell-perspectives--insert-line (text entry &optional face)
  "Insert TEXT as a line carrying ENTRY, adding FACE beneath its own faces."
  (let ((start (point)))
    (insert text)
    (when entry
      (put-text-property start (point) 'agent-shell-perspectives-entry entry)
      (put-text-property start (point) 'mouse-face 'highlight))
    (when face
      (add-face-text-property start (point) face t))
    (insert "\n")))

(defun agent-shell-perspectives--right-align (left right width)
  "Return LEFT and RIGHT on one line of WIDTH, RIGHT flush right."
  (concat left
          (make-string (max 1 (- width (string-width left) (string-width right))) ?\s)
          right))

(defun agent-shell-perspectives--status-face (status)
  "Return the face for the agent STATUS symbol."
  (pcase status
    ('ready 'success)
    ('busy 'font-lock-keyword-face)
    ('blocked 'warning)
    (_ 'font-lock-comment-face)))

(defun agent-shell-perspectives--render-agent (agent indent width entry)
  "Insert a line for AGENT at INDENT, WIDTH wide, carrying ENTRY."
  (let* ((icon (or (and agent-shell-perspectives-agent-icons
                        (plist-get agent :config)
                        (ignore-errors
                          (agent-shell--config-icon :config (plist-get agent :config))))
                   (agent-shell-perspectives--icon 'robot)))
         (face (agent-shell-perspectives--status-face (plist-get agent :status))))
    (agent-shell-perspectives--insert-line
     (agent-shell-perspectives--right-align
      (concat (make-string indent ?\s) icon " "
              (propertize (plist-get agent :name) 'face face))
      (propertize (symbol-name (plist-get agent :status)) 'face face)
      width)
     entry)))

(defun agent-shell-perspectives--render-worktree (wt project bare-path agents width)
  "Insert the line for WT of PROJECT (clone BARE-PATH) and its AGENTS.
WIDTH is the line width."
  (let* ((path (plist-get wt :path))
         (branch (plist-get wt :branch))
         (slug (agent-shell-perspectives--slug path project))
         (stale (not (file-directory-p path)))
         (status (unless stale (agent-shell-perspectives--status path)))
         (here (unless stale (agent-shell-perspectives--agents-in path agents)))
         (dot (agent-shell-perspectives--icon
               'dot (cond (stale 'error)
                          ((plist-get status :dirty) 'warning)
                          ((> (plist-get status :ahead) 0) 'font-lock-keyword-face)
                          (t 'success))))
         (label (cond (stale (format "%s [gone]" slug))
                      ((string= slug (string-replace "/" "-" branch)) slug)
                      (t (format "%s [%s]" slug branch)))))
    (agent-shell-perspectives--insert-line
     (format "   %s %s" dot label)
     (list :type 'worktree :path path :project project :bare-path bare-path)
     (cond (stale 'error)
           ((not (agent-shell-perspectives--active-p path project agents))
            'font-lock-comment-face)))
    (dolist (agent here)
      (agent-shell-perspectives--render-agent
       agent 5 width
       (list :type 'agent :buffer (plist-get agent :buffer)
             :path path :project project)))))

(defun agent-shell-perspectives--render-header (name stats collapsed width)
  "Insert the header of group NAME with STATS, WIDTH wide.
COLLAPSED selects the chevron."
  (let ((left (format "%s %s " (agent-shell-perspectives--icon
                                (if collapsed 'chevron-right 'chevron-down))
                      name))
        (right (concat " " stats)))
    (agent-shell-perspectives--insert-line
     (concat left
             (make-string (max 1 (- width (string-width left) (string-width right))) ?─)
             right)
     (list :type 'group :group name)
     'font-lock-keyword-face)))

(defun agent-shell-perspectives--render-group (name projects agents width)
  "Insert group NAME with its PROJECTS, given all live AGENTS.
WIDTH is the line width."
  (let* ((show-dormant (gethash name agent-shell-perspectives--show-dormant))
         (wts (cl-loop for p in projects
                       append (mapcar (lambda (wt)
                                        (plist-put (copy-sequence wt)
                                                   :project (plist-get p :project)))
                                      (plist-get p :worktrees))))
         (stale (seq-count (lambda (wt) (not (file-directory-p (plist-get wt :path)))) wts))
         (active (seq-count (lambda (wt)
                              (let ((path (plist-get wt :path)))
                                (and (file-directory-p path)
                                     (agent-shell-perspectives--active-p
                                      path (plist-get wt :project) agents))))
                            wts))
         (dormant (- (length wts) active stale))
         (collapsed (and (not show-dormant) (= active 0) (= stale 0))))
    (agent-shell-perspectives--render-header
     name
     (string-join (delq nil (list (format "%d active" active)
                                  (and (> dormant 0) (not show-dormant)
                                       (format "+%d" dormant))
                                  (and (> stale 0) (format "%d gone" stale))))
                  "  ")
     collapsed width)
    (unless collapsed
      (dolist (proj projects)
        (let ((visible (seq-filter
                        (lambda (wt)
                          (let ((path (plist-get wt :path)))
                            (or show-dormant
                                (not (file-directory-p path))
                                (agent-shell-perspectives--active-p
                                 path (plist-get proj :project) agents))))
                        (plist-get proj :worktrees))))
          (when visible
            (agent-shell-perspectives--insert-line
             (format " %s %s" (agent-shell-perspectives--icon 'git-branch)
                     (plist-get proj :project))
             (list :type 'project :project (plist-get proj :project)
                   :bare-path (plist-get proj :bare-path))
             'bold)
            (dolist (wt visible)
              (agent-shell-perspectives--render-worktree
               wt (plist-get proj :project) (plist-get proj :bare-path)
               agents width))))))))

(defun agent-shell-perspectives--render-bare (projects width)
  "Insert the \"bare\" index of all PROJECTS.  WIDTH is the line width."
  (let ((collapsed (not (gethash "bare" agent-shell-perspectives--show-dormant))))
    (agent-shell-perspectives--render-header
     "bare" (format "%d repos" (length projects)) collapsed width)
    (unless collapsed
      (dolist (proj projects)
        (let ((n (length (plist-get proj :worktrees))))
          (agent-shell-perspectives--insert-line
           (concat "  " (plist-get proj :project)
                   (if (> n 0) (propertize (format " (%d)" n) 'face 'font-lock-type-face) ""))
           (list :type 'project :project (plist-get proj :project)
                 :bare-path (plist-get proj :bare-path))
           'font-lock-comment-face))))))

(defun agent-shell-perspectives--unplaced-agents (projects agents)
  "Return the AGENTS outside every worktree of PROJECTS."
  (let ((paths (cl-loop for p in projects
                        append (mapcar (lambda (wt) (plist-get wt :path))
                                       (plist-get p :worktrees)))))
    (seq-remove (lambda (agent)
                  (seq-some (lambda (path)
                              (agent-shell-perspectives--path-within-p
                               (plist-get agent :directory) path))
                            paths))
                agents)))

(defun agent-shell-perspectives--render-sessions (agents width)
  "Insert the \"sessions\" group for AGENTS that run outside any worktree.
WIDTH is the line width."
  (agent-shell-perspectives--render-header
   "sessions" (format "%d" (length agents)) nil width)
  (dolist (dir-agents (seq-group-by (lambda (a)
                                      (abbreviate-file-name
                                       (directory-file-name (plist-get a :directory))))
                                    agents))
    (agent-shell-perspectives--insert-line
     (concat " " (car dir-agents)) nil 'bold)
    (dolist (agent (cdr dir-agents))
      (agent-shell-perspectives--render-agent
       agent 3 width (list :type 'session :buffer (plist-get agent :buffer))))))

(defun agent-shell-perspectives--render ()
  "Render the dashboard into the current buffer."
  (let* ((inhibit-read-only t)
         (line (line-number-at-pos))
         (agent-shell-perspectives--cache (make-hash-table :test 'equal))
         (width (- (if-let* ((win (get-buffer-window (current-buffer) t)))
                       (window-body-width win)
                     agent-shell-perspectives-dashboard-width)
                   2))
         (projects (agent-shell-perspectives--all-projects))
         (agents (agent-shell-perspectives--all-agents))
         (unplaced (agent-shell-perspectives--unplaced-agents projects agents))
         (sections (agent-shell-perspectives--projects-by-group projects)))
    (erase-buffer)
    (dolist (section sections)
      (if (string= (car section) "bare")
          (agent-shell-perspectives--render-bare (cdr section) width)
        (agent-shell-perspectives--render-group
         (car section) (cdr section) agents width))
      (insert "\n"))
    (when unplaced
      (agent-shell-perspectives--render-sessions unplaced width)
      (insert "\n"))
    (unless projects
      (insert (format "No bare clones in %s.\nPress C to clone a repository.\n\n"
                      (abbreviate-file-name
                       (expand-file-name agent-shell-perspectives-bare-dir)))))
    (agent-shell-perspectives--insert-line
     "[C]lone [c]reate [o]checkout [d]ispose [a]gent [m]agit [i]ssue [D]ormant [S]tale [g]refresh"
     nil 'font-lock-comment-face)
    (goto-char (point-min))
    (forward-line (1- line))))

;;;###autoload
(defun agent-shell-perspectives-dashboard-refresh ()
  "Re-render the dashboard if it is visible, or always when called interactively."
  (interactive)
  (when-let* ((buf (get-buffer agent-shell-perspectives-dashboard-buffer)))
    (when (or (called-interactively-p 'any) (get-buffer-window buf t))
      (agent-shell-perspectives--subscribe-all)
      (with-current-buffer buf
        (let ((win (get-buffer-window buf t)))
          (if win
              (with-selected-window win
                (let ((start (window-start)))
                  (agent-shell-perspectives--render)
                  (set-window-start win start t)))
            (agent-shell-perspectives--render)))))))

(defun agent-shell-perspectives--display (buffer)
  "Display the dashboard BUFFER and return its window."
  (if agent-shell-perspectives-dashboard-side
      (let ((lateral (memq agent-shell-perspectives-dashboard-side '(left right))))
        (display-buffer-in-side-window
         buffer
         `((side . ,agent-shell-perspectives-dashboard-side)
           (slot . 1)
           (,(if lateral 'window-width 'window-height)
            . ,(if lateral agent-shell-perspectives-dashboard-width 0.35))
           (preserve-size . ,(if lateral '(t . nil) '(nil . t)))
           (dedicated . t)
           (window-parameters . ((no-delete-other-windows . t))))))
    (display-buffer buffer)))

;;;###autoload
(defun agent-shell-perspectives-dashboard ()
  "Toggle the dashboard."
  (interactive)
  (let* ((buffer (get-buffer-create agent-shell-perspectives-dashboard-buffer))
         (window (get-buffer-window buffer)))
    (if (window-live-p window)
        (progn (agent-shell-perspectives--stop-timer)
               (delete-window window))
      (with-current-buffer buffer
        (unless (derived-mode-p 'agent-shell-perspectives-dashboard-mode)
          (agent-shell-perspectives-dashboard-mode)))
      (let ((window (agent-shell-perspectives--display buffer)))
        (agent-shell-perspectives--subscribe-all)
        (agent-shell-perspectives--start-timer)
        (with-selected-window window
          (agent-shell-perspectives--render))
        (select-window window)))))

(defun agent-shell-perspectives--ensure-dashboard ()
  "Show the dashboard without toggling it off."
  (unless (get-buffer-window agent-shell-perspectives-dashboard-buffer)
    (save-selected-window (agent-shell-perspectives-dashboard))))

;;; Dashboard actions

(defun agent-shell-perspectives-dashboard-visit ()
  "Visit the worktree, agent or group at point."
  (interactive)
  (let ((entry (agent-shell-perspectives--entry-at-point)))
    (pcase (plist-get entry :type)
      ('worktree
       (unless (agent-shell-perspectives--open (plist-get entry :path)
                                               (plist-get entry :project))
         (agent-shell-perspectives-dashboard-refresh)))
      ('agent
       (let ((buf (plist-get entry :buffer)))
         (if (and (buffer-live-p buf)
                  (agent-shell-perspectives--open (plist-get entry :path)
                                                  (plist-get entry :project)))
             (pop-to-buffer buf)
           (agent-shell-perspectives-dashboard-refresh))))
      ('session
       (let ((buf (plist-get entry :buffer)))
         (if (buffer-live-p buf)
             (pop-to-buffer buf)
           (agent-shell-perspectives-dashboard-refresh))))
      ('group (agent-shell-perspectives-dashboard-toggle-group)))))

(defun agent-shell-perspectives-dashboard-mouse-visit (event)
  "Visit the entry clicked in EVENT."
  (interactive "e")
  (when-let* ((pos (posn-point (event-end event))))
    (goto-char pos)
    (agent-shell-perspectives-dashboard-visit)))

(defun agent-shell-perspectives--group-at-point ()
  "Return the name of the group containing point."
  (save-excursion
    (let (entry)
      (while (and (not (eq (plist-get (setq entry (agent-shell-perspectives--entry-at-point))
                                      :type)
                           'group))
                  (= (forward-line -1) 0)))
      (and (eq (plist-get entry :type) 'group) (plist-get entry :group)))))

(defun agent-shell-perspectives-dashboard-toggle-group ()
  "Show or hide the dormant worktrees of the group at point."
  (interactive)
  (when-let* ((group (agent-shell-perspectives--group-at-point)))
    (puthash group (not (gethash group agent-shell-perspectives--show-dormant))
             agent-shell-perspectives--show-dormant)
    (agent-shell-perspectives-dashboard-refresh)))

(defun agent-shell-perspectives-dashboard-toggle-all ()
  "Show or hide the dormant worktrees of every group."
  (interactive)
  (let* ((names (cons "bare" (mapcar #'car (agent-shell-perspectives-groups))))
         (show (not (seq-some (lambda (g) (gethash g agent-shell-perspectives--show-dormant))
                              names))))
    (dolist (g names)
      (puthash g show agent-shell-perspectives--show-dormant))
    (agent-shell-perspectives-dashboard-refresh)))

(defun agent-shell-perspectives--entry-worktree ()
  "Return the worktree entry at point, or signal a user error."
  (let ((entry (agent-shell-perspectives--entry-at-point)))
    (unless (memq (plist-get entry :type) '(worktree agent))
      (user-error "Not on a worktree"))
    entry))

(defun agent-shell-perspectives-dashboard-create ()
  "Create a worktree of the project at point."
  (interactive)
  (if-let* ((project (plist-get (agent-shell-perspectives--entry-at-point) :project)))
      (agent-shell-perspectives-create
       project (read-string (format "New branch for %s: " project))
       (agent-shell-perspectives--read-group))
    (call-interactively #'agent-shell-perspectives-create)))

(defun agent-shell-perspectives-dashboard-checkout ()
  "Check out a branch of the project at point."
  (interactive)
  (if-let* ((project (plist-get (agent-shell-perspectives--entry-at-point) :project)))
      (agent-shell-perspectives-checkout
       project (agent-shell-perspectives--read-remote-branch project)
       (agent-shell-perspectives--read-group))
    (call-interactively #'agent-shell-perspectives-checkout)))

(defun agent-shell-perspectives-dashboard-dispose ()
  "Dispose of the worktree at point."
  (interactive)
  (let ((entry (agent-shell-perspectives--entry-worktree)))
    (agent-shell-perspectives-dispose (plist-get entry :project)
                                      (plist-get entry :path)
                                      (or (plist-get entry :bare-path)
                                          (agent-shell-perspectives--bare-path
                                           (plist-get entry :project))))))

(defun agent-shell-perspectives-dashboard-agent ()
  "Start a new agent in the worktree at point."
  (interactive)
  (let ((entry (agent-shell-perspectives--entry-worktree)))
    (agent-shell-perspectives-new-agent (plist-get entry :project)
                                        (plist-get entry :path))))

(defun agent-shell-perspectives-dashboard-magit ()
  "Open magit for the worktree at point, in its perspective."
  (interactive)
  (let ((entry (agent-shell-perspectives--entry-worktree)))
    (when (agent-shell-perspectives--open (plist-get entry :path)
                                          (plist-get entry :project))
      (magit-status-setup-buffer (plist-get entry :path)))))

(defun agent-shell-perspectives-dashboard-issue ()
  "Create worktrees with agents for issues of the project at point."
  (interactive)
  (if-let* ((project (plist-get (agent-shell-perspectives--entry-at-point) :project)))
      (agent-shell-perspectives-issues
       project
       (agent-shell-perspectives--read-issues
        (agent-shell-perspectives--forge-repo project))
       (agent-shell-perspectives--read-group))
    (call-interactively #'agent-shell-perspectives-issues)))

;;; Issues (with magit's forge)

(defun agent-shell-perspectives--slot (object slot)
  "Return SLOT of the forge OBJECT.
A function rather than `oref', since forge is optional and its
classes are unknown when this file is compiled."
  (eieio-oref object slot))

(defun agent-shell-perspectives--forge-repo (project)
  "Return forge's repository object for PROJECT."
  (unless (require 'forge nil t)
    (user-error "This needs magit's forge package"))
  (let* ((bare-path (agent-shell-perspectives--bare-path project))
         (wt (car (agent-shell-perspectives--worktrees bare-path)))
         (default-directory (file-name-as-directory (or (car wt) bare-path))))
    (or (forge-get-repository :tracked?)
        (user-error "No forge data for %s; run forge-pull in a worktree first"
                    project))))

(defun agent-shell-perspectives--read-issues (repo)
  "Read one or more open issues of the forge REPO."
  (let* ((issues (sort (forge--list-topics
                        (forge--topics-spec :type 'issue :state 'open
                                            :active nil :limit nil)
                        repo)
                       (lambda (a b) (< (agent-shell-perspectives--slot a 'number) (agent-shell-perspectives--slot b 'number)))))
         (candidates (mapcar (lambda (i)
                               (cons (format "#%-5d %s" (agent-shell-perspectives--slot i 'number) (agent-shell-perspectives--slot i 'title)) i))
                             issues)))
    (unless issues
      (user-error "No open issues"))
    (mapcar (lambda (choice) (cdr (assoc choice candidates)))
            (completing-read-multiple
             "Issues: "
             (lambda (input pred action)
               (if (eq action 'metadata)
                   '(metadata (display-sort-function . identity))
                 (complete-with-action action (mapcar #'car candidates) input pred)))
             nil t))))

(defun agent-shell-perspectives--issue-prompt (issue)
  "Return a prompt for an agent that is to work on ISSUE."
  (concat
   "This worktree was created to investigate and solve the following GitHub issue:\n\n"
   (format "## Issue #%d: %s\n\n" (agent-shell-perspectives--slot issue 'number) (agent-shell-perspectives--slot issue 'title))
   (format "**Author:** @%s\n" (or (agent-shell-perspectives--slot issue 'author) "unknown"))
   (when-let* ((labels (mapcar #'cadr (ignore-errors (agent-shell-perspectives--slot issue 'labels)))))
     (format "**Labels:** %s\n" (string-join labels ", ")))
   "\n" (or (agent-shell-perspectives--slot issue 'body) "")
   (when-let* ((posts (ignore-errors (agent-shell-perspectives--slot issue 'posts))))
     (concat "\n\n### Comments\n"
             (mapconcat (lambda (post)
                          (format "\n**@%s** (%s):\n%s\n"
                                  (or (agent-shell-perspectives--slot post 'author) "unknown")
                                  (or (agent-shell-perspectives--slot post 'created) "")
                                  (or (agent-shell-perspectives--slot post 'body) "")))
                        posts "")))))

(defun agent-shell-perspectives--issue-config ()
  "Return the agent config for issue worktrees."
  (or (and agent-shell-perspectives-issue-agent-config
           (seq-find (lambda (c) (eq (map-elt c :identifier)
                                     agent-shell-perspectives-issue-agent-config))
                     agent-shell-agent-configs))
      (agent-shell-select-config :prompt "Agent for issues: ")))

;;;###autoload
(defun agent-shell-perspectives-issues (project issues &optional group)
  "Create a worktree in GROUP for each of the forge ISSUES of PROJECT.
Start an agent in each, with the issue text waiting in its prompt."
  (interactive
   (let ((project (agent-shell-perspectives--read-project)))
     (list project
           (agent-shell-perspectives--read-issues
            (agent-shell-perspectives--forge-repo project))
           (agent-shell-perspectives--read-group))))
  (let ((config (agent-shell-perspectives--issue-config))
        (group (or group (agent-shell-perspectives--default-group)))
        last)
    (dolist (issue issues)
      (let* ((branch (format "%s%d" agent-shell-perspectives-issue-branch-prefix
                             (agent-shell-perspectives--slot issue 'number)))
             (dest (agent-shell-perspectives--worktree-dir project branch group)))
        (if (file-exists-p dest)
            (agent-shell-perspectives--open dest project)
          (agent-shell-perspectives-create project branch group))
        (let* ((default-directory (file-name-as-directory dest))
               (shell (agent-shell-start :config config)))
          (when (buffer-live-p shell)
            (agent-shell-insert :text (agent-shell-perspectives--issue-prompt issue)
                                :shell-buffer shell :no-focus t)
            (setq last shell)))))
    (when last (pop-to-buffer last))
    (agent-shell-perspectives--ensure-dashboard)
    (message "Started agents for %s"
             (mapconcat (lambda (i) (format "#%d" (agent-shell-perspectives--slot i 'number))) issues ", "))))

;;; Setup

(defvar-keymap agent-shell-perspectives-command-map
  :doc "Keymap for agent-shell-perspectives commands.
Bind it to a prefix of your choice."
  "w" #'agent-shell-perspectives-dashboard
  "c" #'agent-shell-perspectives-create
  "o" #'agent-shell-perspectives-checkout
  "C" #'agent-shell-perspectives-clone
  "s" #'agent-shell-perspectives-switch
  "d" #'agent-shell-perspectives-dispose
  "a" #'agent-shell-perspectives-new-agent
  "i" #'agent-shell-perspectives-issues)
(fset 'agent-shell-perspectives-command-map agent-shell-perspectives-command-map)

(defun agent-shell-perspectives--dashboard-buffer-p (buffer)
  "Return non-nil if BUFFER is the dashboard."
  (string= (buffer-name buffer) agent-shell-perspectives-dashboard-buffer))

;;;###autoload
(defun agent-shell-perspectives-setup ()
  "Hook into agent-shell and `persp-mode'.
Agent sessions report status changes to the dashboard as they
happen, and the dashboard stays out of every perspective's buffer
list so it survives perspective switches."
  (interactive)
  (add-hook 'agent-shell-mode-hook #'agent-shell-perspectives--subscribe)
  (add-to-list 'persp-common-buffer-filter-functions
               #'agent-shell-perspectives--dashboard-buffer-p))

(provide 'agent-shell-perspectives)
;;; agent-shell-perspectives.el ends here
