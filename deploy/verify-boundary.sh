#!/usr/bin/env bash
# Check that the walls between the holt and agent users hold. Run as your own
# login user (it calls sudo):
#
#     deploy/verify-boundary.sh
#
# Prints PASS or FAIL for each check and exits non-zero if anything failed.
set -uo pipefail

GUARD=/usr/local/lib/holt/guard/guard.py
AGENTCTL=/usr/local/libexec/holt/agentctl
SUDOERS=/etc/sudoers.d/holt-agentctl
FAILED=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  FAILED=1
}

# expect_ok NAME CMD...    passes when CMD succeeds
expect_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# expect_fail NAME CMD...  passes when CMD fails
expect_fail() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi
}

as_agent() { sudo -n -u agent -H "$@"; }
as_holt() { sudo -n -u holt "$@"; }

# exit code of the guard for one Bash command, run as agent
guard_exit() {
  local event
  event=$(jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
  as_agent python3 "$GUARD" --profile agent <<<"$event" >/dev/null 2>&1
  echo $?
}

sudo -v || {
  echo "verify-boundary: needs sudo" >&2
  exit 1
}

# --- agent cannot reach holt's secrets --------------------------------------
expect_ok "ntfy token exists" sudo test -s /etc/holt/credentials/ntfy-token
expect_fail "agent cannot read the ntfy token" as_agent cat /etc/holt/credentials/ntfy-token
expect_fail "agent cannot list /var/lib/holt" as_agent ls /var/lib/holt
expect_fail "agent cannot list /etc/holt" as_agent ls /etc/holt
readable=$(as_agent find /etc -name '*token*' -readable -type f 2>/dev/null)
if [[ -z $readable ]]; then
  pass "agent cannot read any *token* file under /etc"
else
  fail "agent can read token files: $(tr '\n' ' ' <<<"$readable")"
fi
expect_fail "holt cannot write to /home/agent" as_holt test -w /home/agent

# --- agent has no GitHub login and no sudo ----------------------------------
if as_agent bash -c 'command -v gh' >/dev/null 2>&1; then
  expect_fail "agent has no gh login" as_agent gh auth status
else
  pass "agent has no gh login (gh not installed)"
fi
# shellcheck disable=SC2016 # $HOME must expand in agent's shell, not here
expect_fail "agent has no SSH keys" as_agent bash -c 'compgen -G "$HOME/.ssh/id_*"'
expect_fail "agent has no sudo" as_agent sudo -n true

# --- the holt-to-agent bridge is exactly one program ------------------------
if [[ $(as_holt sudo -n -u agent "$AGENTCTL" ping 2>/dev/null) == agent ]]; then
  pass "holt can run agentctl ping as agent"
else
  fail "holt can run agentctl ping as agent"
fi
expect_fail "holt cannot run anything else as agent" as_holt sudo -n -u agent id
if [[ $(sudo stat -c '%a %U:%G' "$SUDOERS" 2>/dev/null) == "440 root:root" ]]; then
  pass "sudoers drop-in is 0440 root:root"
else
  fail "sudoers drop-in is 0440 root:root"
fi
expect_ok "sudoers drop-in passes visudo" sudo visudo -cqf "$SUDOERS"
rules=$(sudo grep -vE '^[[:space:]]*(#|$)' "$SUDOERS" 2>/dev/null)
if [[ $rules == "holt ALL=(agent) NOPASSWD: $AGENTCTL *" ]]; then
  pass "sudoers drop-in contains only the agentctl rule"
else
  fail "sudoers drop-in contains only the agentctl rule"
fi

# --- the guard hook ---------------------------------------------------------
if [[ $(python3 "$GUARD" --version 2>/dev/null) == "guard 1" ]]; then
  pass "guard version is 1"
else
  fail "guard version is 1"
fi
for cmd in "gh pr create --title x --body y" "git push origin main"; do
  code=$(guard_exit "$cmd")
  if [[ $code == 2 ]]; then pass "guard blocks: $cmd"; else fail "guard blocks: $cmd (exit $code)"; fi
done
for f in /usr/local/lib/holt/guard /usr/local/lib/holt/guard/*; do
  if [[ $(stat -c '%U' "$f") != root ]]; then
    fail "guard file is owned by root: $f"
  fi
  expect_fail "agent cannot touch $f" as_agent touch "$f"
done
if jq -e --arg g "$GUARD" '[.hooks.PreToolUse[].hooks[].command] | any(contains($g))' \
  /etc/claude-code/managed-settings.json >/dev/null 2>&1; then
  pass "Claude Code managed settings run the guard"
else
  fail "Claude Code managed settings run the guard"
fi

# --- tmux -------------------------------------------------------------------
tmux_version=$(tmux -V 2>/dev/null | awk '{print $2}' | tr -d '[:lower:]')
if [[ -n $tmux_version ]] && dpkg --compare-versions "$tmux_version" ge 3.2; then
  pass "tmux is 3.2 or newer ($tmux_version)"
else
  fail "tmux is 3.2 or newer"
fi
if as_agent tmux new -d -s holt-verify >/dev/null 2>&1 &&
  as_agent tmux ls 2>/dev/null | grep -q '^holt-verify:'; then
  pass "agent can start a tmux session"
else
  fail "agent can start a tmux session"
fi
as_agent tmux kill-session -t holt-verify >/dev/null 2>&1

# --- network ----------------------------------------------------------------
if [[ $(tailscale status --json 2>/dev/null | jq -r '.BackendState') == Running ]]; then
  pass "tailscale is online"
else
  fail "tailscale is online"
fi
ufw_status=$(sudo ufw status verbose 2>/dev/null)
if grep -q '^Status: active' <<<"$ufw_status" && grep -q 'Default: deny (incoming)' <<<"$ufw_status"; then
  pass "ufw is on and denies incoming by default"
else
  fail "ufw is on and denies incoming by default"
fi
expect_ok "tailscaled starts at boot" systemctl is-enabled --quiet tailscaled
expect_ok "ntfy starts at boot" systemctl is-enabled --quiet ntfy
topic=$(sudo cat /etc/holt/ntfy-topic 2>/dev/null)
code=$(curl -s -o /dev/null -w '%{http_code}' -d test "http://127.0.0.1:2586/${topic:-missing}")
if [[ $code == 401 || $code == 403 ]]; then
  pass "ntfy refuses a message without the token ($code)"
else
  fail "ntfy refuses a message without the token (got $code)"
fi

echo
if ((FAILED)); then
  echo "Some checks FAILED."
  exit 1
fi
echo "All checks passed."
