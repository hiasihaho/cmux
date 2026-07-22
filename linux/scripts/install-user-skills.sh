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

REPO_SKILLS="$(cd "$(dirname "$0")/../../skills" && pwd)"
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
    if [ -L "$target" ]; then
        # Ours (any path into the repo skills dir): refresh silently.
        case "$(readlink -f "$target" 2>/dev/null)" in
            "$REPO_SKILLS"/*) ln -sfn "$dir" "$target"; linked=$((linked + 1)); continue ;;
        esac
        echo "SKIP $name: foreign symlink ($(readlink "$target"))"; skipped=$((skipped + 1)); continue
    elif [ -e "$target" ]; then
        echo "SKIP $name: real file/directory exists"; skipped=$((skipped + 1)); continue
    fi
    ln -s "$dir" "$target"
    linked=$((linked + 1))
done
echo "linked $linked skill(s) into $USER_SKILLS ($skipped skipped)"
echo "New sessions anywhere now list the cmux skills; running sessions pick them up on restart."
