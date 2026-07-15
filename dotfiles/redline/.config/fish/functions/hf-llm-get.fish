function hf-llm-get --description 'Download a Hugging Face repo/subfolder/file from its URL into /mnt/ssd0/ai/llm/<org>/<repo>'
    if test (count $argv) -lt 1
        echo "usage: hf-llm-get <huggingface-url> [extra `hf download` args...]" >&2
        echo "  e.g. hf-llm-get https://huggingface.co/unsloth/GLM-5.2-GGUF/tree/main/UD-IQ1_S" >&2
        return 1
    end

    set -l url $argv[1]
    set -l rest $argv[2..]

    # Strip scheme + host, then any ?query / #fragment, then trailing slashes.
    set -l path (string replace -r '^https?://huggingface\.co/' '' -- $url)
    set path (string replace -r '[?#].*$' '' -- $path)
    set path (string trim -r -c / -- $path)

    set -l parts (string split / -- $path)
    if test (count $parts) -lt 2
        echo "hf-llm-get: could not parse <org>/<repo> from: $url" >&2
        return 1
    end

    set -l org $parts[1]
    set -l repo $parts[2]
    set -l repo_id "$org/$repo"
    set -l local_dir "/mnt/ssd0/ai/llm/$org/$repo"

    # A HF web URL for anything below the repo root looks like
    # <org>/<repo>/(tree|blob|resolve)/<ref>/<subpath...>. Translate that into
    # a --revision (when not main) plus an --include filter, so a subfolder or
    # single file lands under the repo dir at the same relative path HF uses.
    set -l args
    if test (count $parts) -ge 4
        set -l kind $parts[3]
        set -l ref $parts[4]
        set -l sub (string join / -- $parts[5..])

        if test "$ref" != main
            set args $args --revision $ref
        end

        switch $kind
            case tree
                # A subfolder: grab everything beneath it.
                test -n "$sub"; and set args $args --include "$sub/*"
            case blob resolve
                # A single file.
                test -n "$sub"; and set args $args --include "$sub"
        end
    end

    set_color cyan
    echo "hf download $repo_id --local-dir $local_dir $args $rest"
    set_color normal
    hf download $repo_id --local-dir $local_dir $args $rest
end
