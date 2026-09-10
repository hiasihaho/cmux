#!/usr/bin/env bash
# Installs the polkit action cmux uses to verify a human before signing a
# passkey assertion. ONE-TIME, needs root, and it is the ONLY way to reach
# the password rung.
#
# WHY A FILE IS REQUIRED (measured 2026-09-10, not assumed): polkit has no
# implicit default for an unregistered action — it errors outright.
#
#   $ pkcheck --action-id com.manaflow.cmux.webauthn.verify --process $$
#   Error checking for authorization ...: Action ... is not registered
#
# So this is not a fallback for when some default fails; without it the
# password rung does not exist and cmux degrades honestly to UV=0.
#
# NOT needed for the fingerprint rung: fprintd registers its own action
# (net.reactivated.fprint.device.verify, allow_active), which an active
# session may already drive. The sudo below buys the FLOOR, not the top.
#
#   sudo linux/scripts/install-polkit-policy.sh          # install
#   sudo linux/scripts/install-polkit-policy.sh --remove # undo
set -euo pipefail

ACTION="com.manaflow.cmux.webauthn.verify"
DEST="/usr/share/polkit-1/actions/${ACTION}.policy"

if [ "${1:-}" = "--remove" ]; then
    rm -f "$DEST" && echo "removed $DEST"
    exit 0
fi

[ "$(id -u)" = "0" ] || { echo "error: needs root — re-run with sudo" >&2; exit 1; }

# auth_self, not auth_admin: we are verifying THE USER at the keyboard,
# not authorising an administrative act. Asking for an admin password
# would be a different (and wrong) question, and would train people to
# type admin credentials at a web page's prompting.
#
# allow_inactive=no: a locked or background session cannot verify anyone.
cat > "$DEST" <<'POLICY'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1.0/policyconfig.dtd">
<policyconfig>
  <vendor>cmux</vendor>
  <vendor_url>https://github.com/manaflow-ai/cmux</vendor_url>
  <action id="com.manaflow.cmux.webauthn.verify">
    <!-- The message a person actually reads at the prompt. A bare action
         id would tell them nothing about what they are approving. -->
    <description>Verify your identity to use a passkey</description>
    <message>Authentication is required to sign in with a passkey stored by cmux.</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>auth_self</allow_active>
    </defaults>
  </action>
</policyconfig>
POLICY

chmod 644 "$DEST"
echo "installed $DEST"
if pkaction --action-id "$ACTION" >/dev/null 2>&1; then
    echo "verified: polkit now knows $ACTION"
    echo "cmux will pick up the password rung on its next start (CMUX_WEBAUTHN_UV_BACKEND=auto)."
else
    echo "WARNING: polkit still does not report the action — it was written but is not registered" >&2
    exit 1
fi
