#!/usr/bin/env bash
# Check that the walls between the holt and agent users hold. Run as your own
# login user (it calls sudo):
#
#     deploy/verify-boundary.sh
#
# Prints PASS or FAIL for each check and exits non-zero if anything failed.
set -uo pipefail
shopt -s nullglob

GUARD_DIR=/usr/local/lib/holt/guard
GUARD=$GUARD_DIR/guard.py
GUARD_RUNNER=$GUARD_DIR/run-guard
MANAGED_SETTINGS=/etc/claude-code/managed-settings.d/50-holt-guard.json
AGENT_CLI_PREFIX=/opt/holt/agent-cli
CLAUDE_CODE_MIN_VERSION=2.1.295
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

# Run the exact hook command configured in managed settings under agent's login environment
guard_hook_exit() {
  local cmd=$1 hook_cmd event
  hook_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$MANAGED_SETTINGS" 2>/dev/null)
  if [[ -z $hook_cmd ]]; then
    echo 127
    return
  fi
  event=$(jq -cn --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  sudo -n -u agent -i bash -c "$hook_cmd" <<<"$event" >/dev/null 2>&1
  echo $?
}

sudo -v || {
  echo "verify-boundary: needs sudo" >&2
  exit 1
}

# --- agent cannot reach holt's or owner's secrets ---------------------------
expect_ok "/var/lib/holt exists" sudo test -d /var/lib/holt
expect_ok "/etc/holt exists" sudo test -d /etc/holt
expect_ok "ntfy token exists" sudo test -s /etc/holt/credentials/ntfy-token
expect_fail "agent cannot read the ntfy token" as_agent cat /etc/holt/credentials/ntfy-token
expect_fail "agent cannot list /var/lib/holt" as_agent ls /var/lib/holt
expect_fail "agent cannot list /etc/holt" as_agent ls /etc/holt
expect_fail "agent cannot list owner home ($HOME)" as_agent ls "$HOME"
readable=$(as_agent find /etc -name '*token*' -readable -type f 2>/dev/null)
if [[ -z $readable ]]; then
  pass "agent cannot read any *token* file under /etc"
else
  fail "agent can read token files: $(tr '\n' ' ' <<<"$readable")"
fi
expect_fail "holt cannot write to /home/agent" as_holt test -w /home/agent

# --- agent has no GitHub login, SSH keys, or sudo ---------------------------
expect_fail "agent has no gh hosts.yml" as_agent test -s /home/agent/.config/gh/hosts.yml
expect_fail "agent has no .git-credentials" as_agent test -s /home/agent/.git-credentials
if [[ -z $(as_agent git config --global --get credential.helper 2>/dev/null) ]]; then
  pass "agent has no git credential.helper"
else
  fail "agent has a git credential.helper configured"
fi
if as_agent bash -lc 'command -v gh' >/dev/null 2>&1; then
  expect_fail "agent has no gh login" as_agent bash -lc 'gh auth status'
else
  pass "agent has no gh login (gh not installed)"
fi
# Check for any private key file under ~/.ssh, regardless of filename
if [[ -z $(as_agent grep -rls "PRIVATE KEY" /home/agent/.ssh 2>/dev/null) ]]; then
  pass "agent has no SSH private keys"
else
  fail "agent has SSH private keys under /home/agent/.ssh"
fi
expect_fail "agent has no sudo" as_agent sudo -n true
if ! sudo -l -U agent 2>/dev/null | grep -qE '^\s*\('; then
  pass "sudo -l -U agent lists no allowed commands"
else
  fail "sudo -l -U agent lists allowed commands"
fi

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

# --- the guard hook and pinned CLIs -----------------------------------------
if [[ $(/usr/bin/python3 -I "$GUARD" --version 2>/dev/null) == "guard 1" ]]; then
  pass "guard version is 1"
else
  fail "guard version is 1"
fi
if jq -e --arg r "$GUARD_RUNNER" '
  .hooks.PreToolUse[].hooks[]
  | select(.command == $r and .onFailure == "block")
' "$MANAGED_SETTINGS" >/dev/null 2>&1; then
  pass "Claude Code managed settings run the guard with onFailure: block"
else
  fail "Claude Code managed settings run the guard with onFailure: block"
fi
# Positive controls (must block) and negative control (must allow) through the real hook
for cmd in "gh pr create --title x --body y" "git push origin main"; do
  code=$(guard_hook_exit "$cmd")
  if [[ $code == 2 ]]; then pass "guard hook blocks: $cmd"; else fail "guard hook blocks: $cmd (exit $code)"; fi
done
code=$(guard_hook_exit "ls")
if [[ $code == 0 ]]; then
  pass "guard hook allows safe command: ls"
else
  fail "guard hook allows safe command: ls (exit $code)"
fi

guard_files=("$GUARD_DIR" "$GUARD_DIR"/*)
if ((${#guard_files[@]} < 3)); then
  fail "guard directory is missing files: $GUARD_DIR"
else
  all_root=1
  for f in "${guard_files[@]}"; do
    if [[ $(stat -c '%U' "$f" 2>/dev/null) != root ]]; then
      fail "guard file is owned by root: $f"
      all_root=0
    fi
    expect_fail "agent cannot touch $f" as_agent touch "$f"
  done
  ((all_root)) && pass "all guard files are owned by root"
  expect_fail "agent cannot create files in $GUARD_DIR" as_agent touch "$GUARD_DIR/.verify-probe"
fi

claude_bin=$AGENT_CLI_PREFIX/bin/claude
claude_ver=$(as_agent "$claude_bin" --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')
if [[ -n $claude_ver ]] && dpkg --compare-versions "$claude_ver" ge "$CLAUDE_CODE_MIN_VERSION"; then
  pass "agent Claude Code is $claude_ver (>= $CLAUDE_CODE_MIN_VERSION)"
else
  fail "agent Claude Code is >= $CLAUDE_CODE_MIN_VERSION (got ${claude_ver:-missing})"
fi
expect_fail "agent cannot modify $AGENT_CLI_PREFIX" as_agent touch "$AGENT_CLI_PREFIX/.verify-probe"

# --- tmux -------------------------------------------------------------------
tmux_version=$(tmux -V 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')
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
if [[ $(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') == Running ]]; then
  pass "tailscale is online"
else
  fail "tailscale is online"
fi
if tailscale serve status --json 2>/dev/null | jq -e '((.AllowFunnel // {}) | length) == 0' >/dev/null 2>&1; then
  pass "tailscale Funnel is off"
else
  fail "tailscale Funnel is off"
fi
ufw_status=$(sudo ufw status verbose 2>/dev/null)
if grep -q '^Status: active' <<<"$ufw_status" &&
  grep -q 'Default: deny (incoming)' <<<"$ufw_status" &&
  grep -qE '^Anywhere on tailscale0 +ALLOW IN +Anywhere' <<<"$ufw_status"; then
  pass "ufw is on, denies incoming by default, and allows tailscale0"
else
  fail "ufw is on, denies incoming by default, and allows tailscale0"
fi
if grep -E 'ALLOW IN' <<<"$ufw_status" | grep -qv 'on tailscale0'; then
  fail "ufw has non-tailscale0 ALLOW IN rules"
else
  pass "ufw has no non-tailscale0 ALLOW IN rules"
fi
expect_ok "tailscaled starts at boot" systemctl is-enabled --quiet tailscaled
expect_ok "ntfy starts at boot" systemctl is-enabled --quiet ntfy
topic=$(sudo cat /etc/holt/ntfy-topic 2>/dev/null)
if [[ -z $topic ]]; then
  fail "ntfy topic file exists and is non-empty"
else
  pass "ntfy topic file exists"
  code=$(curl -s -o /dev/null -w '%{http_code}' -d test "http://127.0.0.1:2586/$topic")
  if [[ $code == 401 || $code == 403 ]]; then
    pass "ntfy refuses a message without the token ($code)"
  else
    fail "ntfy refuses a message without the token (got $code)"
  fi
fi

echo
if ((FAILED)); then
  echo "Some checks FAILED."
  exit 1
fi
echo "All checks passed."
