#!/usr/bin/env bash
# Make the repo's cmux* skills available to EVERY Claude Code session of
# this user — not just sessions whose cwd is inside the checkout. Symlinks
# ~/.claude/skills/<name> → this repo's skills/<name>, so dev-instance
# panes, scratch workspaces, and sessions in other directories can invoke
# /cmux, /cmux-testing, etc. Symlinks track the repo: a git pull updates
# the skills everywhere, nothing to re-run.
#
#   linux/scripts/install-user-skills.sh          # install/refresh links
#   linux/scripts/install-user-skills.sh --remove # remove OUR links only
#
# Safe: only touches ~/.claude/skills entries that are symlinks into this
# repo's skills/ directory; real directories or foreign links are left
# alone and reported.
set -uo pipefail

# Inside a flatpak, $HOME is <real-home>/.var/app/<id>. Both what this
# script WRITES (~/.claude/skills) and what it links TO must live on the
# REAL home: pane shells run on the HOST (portal), so they cannot see
# /app at all — a link into /app would dangle for every agent that
# matters. --filesystem=home makes the real home visible at its own path,
# so recovering it is a prefix strip.
if [ -n "${FLATPAK_ID:-}" ]; then
    case "$HOME" in
        */.var/app/*) HOME="${HOME%%/.var/app/*}" ;;
    esac
fi

# Skills source: this checkout normally, but a FLATPAK-only install has
# no checkout — the flatpak ships them at /app/share/cmux/skills, whose
# host-side path is the app's files dir. Linking there also tracks
# updates, since `current/active` moves when the flatpak is updated.
# CMUX_SKILLS_DIR overrides both (tests, unusual layouts).
FLATPAK_SKILLS="$HOME/.local/share/flatpak/app/${FLATPAK_ID:-com.manaflow.cmux}/current/active/files/share/cmux/skills"
# LINK_BASE is what the symlinks POINT AT; REPO_SKILLS is what we ENUMERATE.
# They differ in exactly one case: running INSIDE the sandbox, where
# flatpak masks ~/.local/share/flatpak even under --filesystem=home (apps
# must not touch the flatpak installation), so the host path we must link
# to is unreadable from here — while /app/share/cmux/skills is readable
# and has the same names. Enumerate one, point at the other.
LINK_BASE=""
if [ -n "${CMUX_SKILLS_DIR:-}" ]; then
    REPO_SKILLS="$CMUX_SKILLS_DIR"
elif [ -n "${FLATPAK_ID:-}" ] && [ -d /app/share/cmux/skills ]; then
    REPO_SKILLS=/app/share/cmux/skills
    LINK_BASE="$FLATPAK_SKILLS"
    echo "note: running inside the flatpak; linking to the host-visible path"
    echo "      $LINK_BASE"
elif [ -d "$(dirname "$0")/../../skills" ]; then
    REPO_SKILLS="$(cd "$(dirname "$0")/../../skills" && pwd)"
elif [ -d "$FLATPAK_SKILLS" ]; then
    REPO_SKILLS="$FLATPAK_SKILLS"
    echo "note: linking skills from the flatpak install (no checkout found)"
else
    echo "install-user-skills: no skills found (checkout or flatpak)" >&2
    exit 1
fi
[ -n "$LINK_BASE" ] || LINK_BASE="$REPO_SKILLS"
USER_SKILLS="$HOME/.claude/skills"
mkdir -p "$USER_SKILLS"

if [ "${1:-}" = "--remove" ]; then
    removed=0
    for link in "$USER_SKILLS"/*; do
        [ -L "$link" ] || continue
        case "$(readlink -f "$link" 2>/dev/null)" in
            "$REPO_SKILLS"/*) rm "$link"; removed=$((removed + 1)) ;;
        esac
    done
    echo "removed $removed link(s) into $REPO_SKILLS"
    exit 0
fi

linked=0; skipped=0
for dir in "$REPO_SKILLS"/*/; do
    name="$(basename "$dir")"
    target="$USER_SKILLS/$name"
    link_to="$LINK_BASE/$name"
    if [ -L "$target" ]; then
        # Ours (a link into either skills base — checkout or flatpak):
        # refresh silently, which is also how a checkout link repoints at
        # the flatpak after a machine goes checkout-free.
        case "$(readlink "$target" 2>/dev/null):$(readlink -f "$target" 2>/dev/null)" in
            "$LINK_BASE"/*|*:"$REPO_SKILLS"/*)
                ln -sfn "$link_to" "$target"; linked=$((linked + 1)); continue ;;
        esac
        echo "SKIP $name: foreign symlink ($(readlink "$target"))"; skipped=$((skipped + 1)); continue
    elif [ -e "$target" ]; then
        echo "SKIP $name: real file/directory exists"; skipped=$((skipped + 1)); continue
    fi
    ln -s "$link_to" "$target"
    linked=$((linked + 1))
done
echo "linked $linked skill(s) into $USER_SKILLS ($skipped skipped)"
echo "New sessions anywhere now list the cmux skills; running sessions pick them up on restart."
