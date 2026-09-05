#!/usr/bin/env bash
# Type a line of text into a Proxmox VM's console, one key at a time.
#
# ⚠️ THIS IS THE PATH THAT NEEDS NOTHING INSIDE THE GUEST. Before SSH exists, the
# QEMU monitor is the only way in - it works at the keyboard, before boot, and
# when the network is broken. It is slow and it is unkillable, which is exactly
# the trade a bootstrap wants.
#
#   sendtext.sh <vmid> "text to type"
set -euo pipefail
VM="${1:?vmid}"
TEXT="${2:?text}"

declare -A K=(
  [' ']=spc ['-']=minus ['=']=equal ['[']=bracket_left [']']=bracket_right
  [';']=semicolon ["'"]=apostrophe [',']=comma ['.']=dot ['/']=slash
  ['\']=backslash ['`']=grave_accent
)
# ⚠️ The shifted characters have to be named as shift-<base>, because the
# monitor sends scancodes, not characters. A colon typed as "colon" is silently
# ignored and the command that arrives is not the one that was sent.
declare -A S=(
  [':']=semicolon ['"']=apostrophe ['<']=comma ['>']=dot ['?']=slash
  ['_']=minus ['+']=equal ['{']=bracket_left ['}']=bracket_right
  ['|']=backslash ['~']=grave_accent ['!']='1' ['@']='2' ['#']='3' ['$']='4'
  ['%']='5' ['^']='6' ['&']='7' ['*']='8' ['(']='9' [')']='0'
)

keys=()
for (( i=0; i<${#TEXT}; i++ )); do
  c="${TEXT:i:1}"
  if [[ -n "${K[$c]:-}" ]]; then keys+=("${K[$c]}")
  elif [[ -n "${S[$c]:-}" ]]; then keys+=("shift-${S[$c]}")
  elif [[ "$c" =~ [a-z0-9] ]]; then keys+=("$c")
  elif [[ "$c" =~ [A-Z] ]]; then keys+=("shift-$(tr '[:upper:]' '[:lower:]' <<<"$c")")
  else echo "no key name for '$c'" >&2; exit 1
  fi
done

# ⚠️ ONE CONNECTION, BUT PACED. Two failures bracket this line. A separate ssh
# per key made 25 characters take 25 seconds, and Windows raised the Start menu
# in the middle of a password - the text went somewhere else entirely. Dumping
# all 25 sendkeys in at once then dropped the whole string on the floor: the
# emulated PS/2 keyboard has a buffer and the monitor does not wait for it. So:
# one connection held open, keys fed down it at 20/sec. Neither slow nor blind.
{ for k in "${keys[@]}"; do echo "sendkey $k"; sleep 0.05; done; } \
  | ssh pve "qm monitor $VM" >/dev/null 2>&1
