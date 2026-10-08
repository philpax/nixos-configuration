# Sourced only by the managed user startup blocks.
case $- in
    *i*) ;;
    *) return ;;
esac
if [ -z "${BASH_VERSION-}" ] || [ ! -t 0 ] || [ ! -t 1 ] ||
   [ "${FRAME_CLI_NO_AUTO-}" = 1 ] || [ "${FRAME_CLI_ACTIVE+x}" = x ]; then
    return
fi
if [ -x @WRAPPER_PATH@ ] && $wrapper ready --quiet >/dev/null 2>&1; then
    exec $wrapper enter
else
    printf '%s\n' 'frame-cli: automatic entry unavailable; run frame-cli status or set FRAME_CLI_NO_AUTO=1.' >&2
fi
