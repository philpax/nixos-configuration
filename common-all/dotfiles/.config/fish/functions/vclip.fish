function vclip --description 'Cut, transcode, and downscale a video clip for social media'

    argparse -n vclip --min-args 0 --max-args 2 \
        h/help \
        start= end= duration= \
        crf= preset= max-height= suffix= \
        force dry-run -- $argv
    or return 1

    if set -q _flag_help
        printf '%s\n' \
            'Usage: vclip --start <time> (--end <time> | --duration <time>) [options] <input> [output]' \
            '' \
            'Cut a video and re-encode it as a social-media-ready H.264/AAC MP4: yuv420p,' \
            'High profile, a two-second keyframe interval, faststart, and audio downmixed to' \
            'stereo AAC at 48 kHz. The video is downscaled to --max-height but never upscaled,' \
            'and metadata and chapters are dropped.' \
            '' \
            'Times accept [HH:]MM:SS[.fff] or plain seconds.' \
            '' \
            'Required:' \
            '  --start <time>       Start of the clip.' \
            '  --end <time>         End of the clip (mutually exclusive with --duration).' \
            '  --duration <time>    Length of the clip.' \
            '' \
            'Options:' \
            '  --crf <0-51>         x264 quality; lower is better (default: 23).' \
            '  --preset <name>      x264 speed/quality preset (default: slow).' \
            '  --max-height <px>    Maximum output height; 0 disables scaling (default: 1080).' \
            '  --suffix <name>      Suffix for the derived output name (default: clip).' \
            '  --force              Overwrite an existing output file.' \
            '  --dry-run            Print the ffmpeg command without running it.' \
            '  -h, --help           Show this help.' \
            '' \
            'Arguments:' \
            '  <input>              Source file.' \
            '  <output>             Destination file (default: <input>-<suffix>.mp4).'
        return 0
    end

    if test (count $argv) -lt 1
        echo 'vclip: missing <input>; see --help' >&2
        return 1
    end

    for tool in ffmpeg ffprobe
        if not command -q $tool
            echo "vclip: $tool is not on PATH" >&2
            return 1
        end
    end

    set -l input $argv[1]
    set -l output $argv[2]

    if not test -r "$input"
        echo "vclip: cannot read input '$input'" >&2
        return 1
    end

    if not set -q _flag_start
        echo 'vclip: --start is required' >&2
        return 1
    end
    if set -q _flag_end; and set -q _flag_duration
        echo 'vclip: --end and --duration are mutually exclusive' >&2
        return 1
    end
    if not set -q _flag_end; and not set -q _flag_duration
        echo 'vclip: one of --end or --duration is required' >&2
        return 1
    end

    set -l start (_vclip_seconds "$_flag_start")
    if test -z "$start"
        echo "vclip: invalid --start '$_flag_start' (expected [HH:]MM:SS[.fff] or seconds)" >&2
        return 1
    end

    set -l duration
    if set -q _flag_duration
        set duration (_vclip_seconds "$_flag_duration")
        if test -z "$duration"
            echo "vclip: invalid --duration '$_flag_duration' (expected [HH:]MM:SS[.fff] or seconds)" >&2
            return 1
        end
    else
        set -l end (_vclip_seconds "$_flag_end")
        if test -z "$end"
            echo "vclip: invalid --end '$_flag_end' (expected [HH:]MM:SS[.fff] or seconds)" >&2
            return 1
        end
        set duration (math "$end - $start")
    end
    if test (math "$duration") -le 0
        echo 'vclip: the clip is empty; the end must be after the start' >&2
        return 1
    end

    set -l crf 23
    if set -q _flag_crf
        set crf $_flag_crf
        if not string match -qr '^[0-9]{1,2}$' -- "$crf"; or test $crf -gt 51
            echo 'vclip: --crf must be an integer from 0 to 51' >&2
            return 1
        end
    end

    set -l preset slow
    set -q _flag_preset; and set preset $_flag_preset
    if not contains -- $preset ultrafast superfast veryfast faster fast medium slow slower veryslow placebo
        echo "vclip: unknown --preset '$preset'" >&2
        return 1
    end

    set -l max_height 1080
    if set -q _flag_max_height
        set max_height $_flag_max_height
        if not string match -qr '^[0-9]+$' -- "$max_height"
            echo 'vclip: --max-height must be a non-negative integer' >&2
            return 1
        end
    end

    if test -z "$output"
        set -l suffix clip
        set -q _flag_suffix; and set suffix $_flag_suffix
        set suffix (string replace -ra '[^A-Za-z0-9._-]' '_' -- "$suffix")
        if test -z "$suffix"
            echo 'vclip: --suffix must contain at least one filename-safe character' >&2
            return 1
        end
        set -l dir (path dirname -- "$input")
        set -l stem (string replace -r '\.[^.]*$' '' -- (path basename -- "$input"))
        set output "$dir/$stem-$suffix.mp4"
    end

    if test -e "$output"; and not set -q _flag_force
        echo "vclip: '$output' already exists; pass --force to overwrite" >&2
        return 1
    end

    # A two-second keyframe interval keeps seeking, cuts, and platform re-uploads predictable.
    set -l gop 120
    set -l rate (ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 -- "$input")
    if string match -qr '^[0-9]+(/[0-9]+)?$' -- "$rate"
        set -l g (math "round($rate * 2)")
        test $g -gt 0; and set gop $g
    end

    # Without scaling, crop the odd pixel off a non-standard source so x264 accepts it.
    set -l vf "crop=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1,format=yuv420p"
    if test $max_height -gt 0
        set vf "scale=w=-2:h='min($max_height,ih)':flags=lanczos,setsar=1,format=yuv420p"
    end

    set -l cmd ffmpeg -hide_banner -nostdin -loglevel warning -stats \
        -ss $start -i "$input" -t $duration \
        -map 0:v:0 -map '0:a:0?' \
        -c:v libx264 -preset $preset -crf $crf -profile:v high -g $gop \
        -vf $vf \
        -c:a aac -b:a 192k -ar 48000 -ac 2 \
        -sn -dn -map_metadata -1 -map_chapters -1 \
        -movflags +faststart
    if set -q _flag_force
        set -a cmd -y
    else
        set -a cmd -n
    end
    set -a cmd "$output"

    if set -q _flag_dry_run
        printf '%s\n' (string escape -- $cmd | string join ' ')
        return 0
    end

    printf 'Clip: %ss at %ss, crf %s, preset %s -> %s\n' "$duration" "$start" "$crf" "$preset" "$output"
    $cmd
end
