function _vclip_seconds --description 'Convert [HH:]MM:SS[.fff] or seconds to seconds, or fail quietly'
    set -l ts $argv[1]
    if not string match -qr '^[0-9]+(:[0-9]+){0,2}(\.[0-9]+)?$' -- "$ts"
        return 1
    end
    set -l parts (string split : -- "$ts")
    switch (count $parts)
        case 1
            math "$parts[1]"
        case 2
            math "$parts[1] * 60 + $parts[2]"
        case 3
            math "$parts[1] * 3600 + $parts[2] * 60 + $parts[3]"
        case '*'
            return 1
    end
end
