#!/bin/sh
# Entry point for the Inline ChatGPT Dots container.
#   setup   sign in to Inline and ChatGPT, then create the bot (interactive)
#   run     relay until stopped (default)
#   status  show the bridge status
#   logs    print recent bridge logs
#   any other arguments run `inline` directly
set -eu

find_config() {
    find "${INLINE_DATA_DIR}/bridge/accounts" -mindepth 2 -maxdepth 2 -name config.json 2>/dev/null | head -n 1
}

case "${1:-run}" in
    setup)
        shift
        inline auth me >/dev/null 2>&1 || inline auth login
        codex login status >/dev/null 2>&1 || codex login --device-auth
        exec inline setup dots --no-service "$@"
        ;;
    run)
        config="$(find_config)"
        if [ -z "${config}" ]; then
            echo "No bridge is configured yet. Run: docker compose run --rm dots setup" >&2
            exit 78
        fi
        exec inline bridge run --config "${config}"
        ;;
    status)
        exec inline bridge status
        ;;
    logs)
        exec inline bridge logs
        ;;
    *)
        exec inline "$@"
        ;;
esac
