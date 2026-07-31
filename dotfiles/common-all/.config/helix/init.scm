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

;; forest-set-style! takes a symbol, but Steel hands command arguments over as
;; strings, so `:forest-set-style! 'mini` silently does nothing. These wrappers are
;; callable as `:forest-mini!` / `:forest-snacks!` to switch style without a restart;
;; close the panel first, since the style is only read when it opens.
(define (forest-mini!) (forest-set-style! 'mini))
(define (forest-snacks!) (forest-set-style! 'snacks))

(keymap (global)
        (normal (space (e ":forest-open"))))
