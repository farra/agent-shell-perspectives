# agent-shell-perspectives

Git worktrees as [persp-mode](https://github.com/Bad-ptr/persp-mode.el)
perspectives, with their [agent-shell](https://github.com/xenodium/agent-shell)
sessions, and a dashboard showing all of it.

![Demo: the dashboard, cloning a repo, creating a worktree, and starting agents in two worktrees](media/demo.gif)

[Watch the demo as video (mp4)](media/demo.mp4). It was recorded with an
earlier version of this package under another name, so the key bindings
on screen (`C-c . w`) differ from the defaults below.

## The idea

This package is an opinionated workflow, and a demonstration of one way to
run several coding agents in Emacs at once. The rule it is built on:

> one piece of work = one git worktree = one perspective = N agents

- Bare clones of the repositories you work on sit in a stash
  (`~/dev/.worktrees/` by default).
- Each piece of work gets its own worktree, checked out from the stash into
  a group directory (`~/dev/me/`, `~/dev/work/`, ...).
- Each worktree gets its own perspective, so its files, magit buffers and
  agent sessions stay together and out of the way of the others.
- Any number of agent-shell sessions run in a worktree. The dashboard shows
  them under it, with their status.
- When the work is done, one command removes the worktree, its perspective
  and its agents, after warning about uncommitted changes, unpushed commits
  and running agents.

If you don't use persp-mode (Doom Emacs uses it for its workspaces) and
agent-shell, or you'd rather organize your work another way, this package
isn't for you, and that's fine. agent-shell has its own lighter command,
`agent-shell-new-worktree-shell`, and the
[agent-shell README](https://github.com/xenodium/agent-shell#related-projects)
lists other ways to manage sessions.

## Layout

```
~/dev/.worktrees/            the stash of bare clones
├── homebase.git
└── myproject.git

~/dev/me/                    a group: each subdirectory of ~/dev is one
├── homebase-main            worktree "main"       → perspective homebase/main
└── myproject-fix-auth       worktree "fix-auth"   → perspective myproject/fix-auth
~/dev/ref/                   another group
└── myproject-v2             worktree "v2"         → perspective myproject/v2
```

A perspective is named after its worktree's directory, not its branch, so an
agent that switches or creates branches inside a worktree doesn't break the
mapping. The dashboard shows the current branch next to the name when the two
differ.

## The dashboard

`M-x agent-shell-perspectives-dashboard` toggles it in a side window. It
lists:

- each group, with its worktrees grouped by project. A worktree is *active*
  when it has an open perspective, uncommitted changes, unpushed commits or a
  running agent; the others are dormant and hidden until you ask for them.
  The dot shows git status: green is clean, yellow is dirty, blue is ahead of
  its upstream, red means the directory is gone.
- the agents running in each worktree, with their status (`ready`, `busy`,
  `blocked` on a permission request). Status changes arrive as agent-shell
  events, so they show up right away.
- **sessions**: agent-shell sessions running outside any worktree, by
  directory, so nothing goes missing.
- **bare**: every project in the stash.

| Key   | Action                                                      |
|-------|-------------------------------------------------------------|
| `RET` | Go to the worktree's perspective, or the agent's buffer      |
| `TAB` | Show or hide the dormant worktrees of this group             |
| `D`   | Show or hide dormant worktrees in every group                |
| `C`   | Clone a repository into the stash                            |
| `c`   | Create a worktree on a new branch                            |
| `o`   | Check out an existing branch as a worktree                   |
| `a`   | Start an agent in the worktree at point                      |
| `m`   | Magit status for the worktree, in its perspective            |
| `d`   | Dispose of the worktree, its perspective and its agents      |
| `i`   | Create worktrees with agents for GitHub issues (needs forge) |
| `S`   | Kill perspectives whose worktree is gone                     |
| `g`   | Refresh                                                      |

## From issue to agent

With magit's [forge](https://github.com/magit/forge) package set up for a
repository, `i` on a project (or `M-x agent-shell-perspectives-issues`) asks
for one or more open issues. For each one it creates a worktree on the
branch `issue/<number>`, starts an agent there, and puts the issue's title,
body and comments in the agent's prompt, ready for you to edit and send.

## Install

It needs Emacs 29.1 or later, magit, persp-mode and agent-shell.
[nerd-icons](https://github.com/rainstormstudio/nerd-icons.el) is used for
icons when it is installed.

With `use-package` on Emacs 30 or later:

```elisp
(use-package agent-shell-perspectives
  :vc (:url "https://github.com/farra/agent-shell-perspectives")
  :after (agent-shell persp-mode)
  :config
  (agent-shell-perspectives-setup)
  (keymap-global-set "C-c w" 'agent-shell-perspectives-command-map))
```

With Doom Emacs, in `packages.el`:

```elisp
(package! agent-shell-perspectives
  :recipe (:host github :repo "farra/agent-shell-perspectives"))
```

and in `config.el`:

```elisp
(use-package! agent-shell-perspectives
  :after agent-shell
  :config
  (agent-shell-perspectives-setup)
  (map! "C-c w" #'agent-shell-perspectives-command-map))
```

`agent-shell-perspectives-setup` makes agent sessions report their status to
the dashboard and keeps the dashboard out of every perspective's buffer list.
The package binds no global keys itself; `agent-shell-perspectives-command-map`
holds the commands under these keys:

| Key | Command                                     |
|-----|---------------------------------------------|
| `w` | `agent-shell-perspectives-dashboard`        |
| `c` | `agent-shell-perspectives-create`           |
| `o` | `agent-shell-perspectives-checkout`         |
| `C` | `agent-shell-perspectives-clone`            |
| `s` | `agent-shell-perspectives-switch`           |
| `d` | `agent-shell-perspectives-dispose`          |
| `a` | `agent-shell-perspectives-new-agent`        |
| `i` | `agent-shell-perspectives-issues`           |

## Customization

`M-x customize-group RET agent-shell-perspectives`. The ones you are most
likely to change:

| Variable                                     | Default               |
|----------------------------------------------|-----------------------|
| `agent-shell-perspectives-bare-dir`          | `~/dev/.worktrees`    |
| `agent-shell-perspectives-base-dir`          | `~/dev`               |
| `agent-shell-perspectives-extra-groups`      | groups outside the base directory |
| `agent-shell-perspectives-default-group`     | the first group       |
| `agent-shell-perspectives-workspace-format`  | `"%p/%s"` (project/slug) |
| `agent-shell-perspectives-open-functions`    | visit the README      |
| `agent-shell-perspectives-dashboard-side`    | `right`               |
| `agent-shell-perspectives-issue-agent-config`| prompt for the agent  |

`agent-shell-perspectives-open-functions` runs with the worktree path after a
new perspective opens; add a function there to show treemacs, start a
terminal, or anything else you want in a fresh worktree.

## Development

```sh
just test   # ERT tests; real git in a temp directory, agent-shell stubbed
just lint   # byte-compile with warnings as errors, checkdoc, package-lint
```

The first run installs magit, persp-mode and package-lint from MELPA into
`.deps/`, leaving your own Emacs packages alone.

## License

Apache License 2.0. See [LICENSE](LICENSE).
