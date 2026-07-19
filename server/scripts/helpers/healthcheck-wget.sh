#!/bin/sh

exec /usr/bin/wget --inet4-only --timeout=5 "$@"
