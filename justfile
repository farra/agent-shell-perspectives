emacs := env_var_or_default("EMACS", "emacs")
batch := emacs + " -Q --batch -L . -L test -l test/deps.el"

# Run the ERT tests
test:
    {{batch}} -l agent-shell-perspectives-test -f ert-run-tests-batch-and-exit

# Byte-compile with warnings as errors, then checkdoc and package-lint
lint:
    {{batch}} --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile agent-shell-perspectives.el
    rm -f agent-shell-perspectives.elc
    {{batch}} --eval '(checkdoc-file "agent-shell-perspectives.el")'
    {{batch}} -l package-lint --eval '(setq package-lint-main-file "agent-shell-perspectives.el")' -f package-lint-batch-and-exit agent-shell-perspectives.el

# Remove installed test dependencies
clean:
    rm -rf .deps *.elc test/*.elc
