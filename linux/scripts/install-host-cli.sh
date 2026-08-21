#!/usr/bin/env bash
# Install a HOST-side `cmux` command for a Flatpak install.
#
#   install-host-cli.sh            # write ~/.local/bin/cmux
#   install-host-cli.sh --remove   # remove it (only if we wrote it)
#
# Why this is needed at all: pane shells run on the HOST through the
# portal, so /app/bin/cmux — the CLI shipped inside the flatpak — is
# invisible to exactly the shells that want it (`cmux: command not
# found` in a pane, 2026-08-21). The flatpak's files are on the host
# filesystem though, and the binary runs directly against the runtime
# libraries shipped beside it, so a two-line wrapper is enough.
#
# Why a wrapper and not `flatpak run --command=cmux`: that spawns a
# sandbox per invocation AND sanitizes the environment, which drops the
# pane identity (CMUX_SURFACE_ID / CMUX_WORKSPACE_ID) that bare `cmux`
# commands rely on to target their own pane.
set -uo pipefail

# Inside a flatpak $HOME is <real-home>/.var/app/<id>; everything here
# must land on the REAL home, which --filesystem=home makes visible at
# its own path.
if [ -n "${FLATPAK_ID:-}" ]; then
    case "$HOME" in
        */.var/app/*) HOME="${HOME%%/.var/app/*}" ;;
    esac
fi

APP_ID="${FLATPAK_ID:-com.manaflow.cmux}"
FILES="$HOME/.local/share/flatpak/app/$APP_ID/current/active/files"
BIN_DIR="$HOME/.local/bin"
WRAPPER="$BIN_DIR/cmux"
MARK="# installed by cmux install-host-cli.sh"

if [ "${1:-}" = "--remove" ]; then
    if [ -f "$WRAPPER" ] && grep -q "$MARK" "$WRAPPER" 2>/dev/null; then
        rm -f "$WRAPPER"
        echo "removed $WRAPPER"
    else
        echo "nothing to remove ($WRAPPER is absent or not ours)"
    fi
    exit 0
fi

mkdir -p "$BIN_DIR"
if [ -e "$WRAPPER" ] && ! grep -q "$MARK" "$WRAPPER" 2>/dev/null; then
    echo "install-host-cli: $WRAPPER exists and is NOT ours — leaving it alone" >&2
    echo "  (a checkout build or a distro package? remove it first if you want the flatpak CLI)" >&2
    exit 1
fi

cat > "$WRAPPER" <<EOF
#!/bin/sh
$MARK
# The cmux CLI from the Flatpak install, for HOST shells (pane shells run
# on the host and cannot see /app). Resolves through current/active, so it
# follows flatpak updates.
F="\$HOME/.local/share/flatpak/app/$APP_ID/current/active/files"
if [ ! -x "\$F/bin/cmux" ]; then
    echo "cmux: flatpak install not found at \$F" >&2
    exit 127
fi
# Outside a pane there is no inherited socket path; default to this
# flatpak's socket when it exists, else let the CLI resolve its own.
if [ -z "\${CMUX_SOCKET_PATH:-}" ]; then
    _sock="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}/app/$APP_ID/cmux.sock"
    [ -S "\$_sock" ] && CMUX_SOCKET_PATH="\$_sock" && export CMUX_SOCKET_PATH
fi
exec env LD_LIBRARY_PATH="\$F/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "\$F/bin/cmux" "\$@"
EOF
chmod +x "$WRAPPER"
echo "installed $WRAPPER -> $FILES/bin/cmux"

# PATH check only makes sense on the host: inside the sandbox $PATH is
# the runtime's (/app/bin:/usr/bin), so this warned every flatpak-only
# user about a host PATH it cannot see (observed 2026-08-21 — the very
# next command worked fine from the host shell).
if [ -z "${FLATPAK_ID:-}" ]; then
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "NOTE: $BIN_DIR is not on your PATH — add it, or the command stays invisible" ;;
    esac
else
    echo "NOTE: check on the HOST that $BIN_DIR is on your PATH (it usually is)."
fi
if [ ! -x "$FILES/bin/cmux" ]; then
    echo "NOTE: $FILES/bin/cmux is not readable from here (expected when running"
    echo "      INSIDE the sandbox: flatpak masks ~/.local/share/flatpak). The wrapper"
    echo "      resolves it at call time from a host shell, where it does exist."
fi
