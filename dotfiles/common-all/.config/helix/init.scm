;; Steel plugin config, run by the plugin-enabled Helix fork after helix.scm.
;; The fork creates this file (and an empty helix.scm) on first run if absent.
;;
;; Cogs are resolved from $STEEL_HOME/cogs; they're git submodules under steel-cogs/
;; symlinked into place by sync.py.

;; forest.hx's README omits this, but `keymap` is a *macro* — without the require it
;; parses as a plain function call and `(global)` blows up with a FreeIdentifier error.
(require "helix/keymaps.scm")
(require "forest/forest.scm")

(forest-configure! 'left #:ignore (list ".git" "target" "__pycache__" "node_modules" "result"))
(forest-set-style! 'snacks)

(keymap (global)
        (normal (space (e ":forest-open"))))
