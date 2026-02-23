# Based on the default fish prompt, with nix-shell indicator added
# Original author: Lily Ballard

function fish_prompt --description 'Write out the prompt'
    set -l last_pipestatus $pipestatus
    set -lx __fish_last_status $status # Export for __fish_print_pipestatus.
    set -l normal (set_color normal)

    # Nix shell indicator
    set -l nix_shell_info
    if test -n "$IN_NIX_SHELL"
        set nix_shell_info (set_color brmagenta)"(nix) "$normal
    end

    # Per-hostname color, derived from hashing the hostname into an HSV hue
    set -l host_hash (printf "%d" 0x(printf "%s" (prompt_hostname) | md5sum | string sub -l 8))
    set -l host_hue (math "$host_hash % 360")
    # HSV to hex with S=0.7, V=0.9 for bright, readable colors
    set -l c (math "0.9 * 0.7")
    set -l x (math "$c * (1 - abs(($host_hue / 60) % 2 - 1))")
    set -l m (math "0.9 - $c")
    set -l r 0; set -l g 0; set -l b 0
    if test $host_hue -lt 60
        set r $c; set g $x
    else if test $host_hue -lt 120
        set r $x; set g $c
    else if test $host_hue -lt 180
        set g $c; set b $x
    else if test $host_hue -lt 240
        set g $x; set b $c
    else if test $host_hue -lt 300
        set r $x; set b $c
    else
        set r $c; set b $x
    end
    set -l host_color (printf "%02x%02x%02x" (math "round(($r + $m) * 255)") (math "round(($g + $m) * 255)") (math "round(($b + $m) * 255)"))

    # Color the prompt differently when we're root
    set -l color_cwd $fish_color_cwd
    set -l suffix '>'
    if functions -q fish_is_root_user; and fish_is_root_user
        if set -q fish_color_cwd_root
            set color_cwd $fish_color_cwd_root
        end
        set suffix '#'
    end

    # Write pipestatus
    # If the status was carried over (if no command is issued or if `set` leaves the status untouched), don't bold it.
    set -l bold_flag --bold
    set -q __fish_prompt_status_generation; or set -g __fish_prompt_status_generation $status_generation
    if test $__fish_prompt_status_generation = $status_generation
        set bold_flag
    end
    set __fish_prompt_status_generation $status_generation
    set -l status_color (set_color $fish_color_status)
    set -l statusb_color (set_color $bold_flag $fish_color_status)
    set -l prompt_status (__fish_print_pipestatus "[" "]" "|" "$status_color" "$statusb_color" $last_pipestatus)

    echo -n -s $nix_shell_info (set_color $fish_color_user) $USER $normal @ (set_color $host_color) (prompt_hostname) $normal ' ' (set_color $color_cwd) (prompt_pwd) $normal (fish_vcs_prompt) $normal " "$prompt_status $suffix " "
end
