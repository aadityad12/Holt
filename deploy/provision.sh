#!/usr/bin/env bash
# Set up the Holt mini PC. Run as root on Ubuntu 24.04 or newer:
#
#     sudo deploy/provision.sh
#
# Safe to run again: every step checks first and changes only what is missing
# or wrong. Each step prints "changed", "unchanged" or "skipped". The manual
# steps (Tailscale login, model logins) are in deploy/README.md.
set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FILES_DIR=$SCRIPT_DIR/files
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Node.js major version: read from .nvmrc so system Node matches Holt's engines.
NODE_MAJOR=22
if [[ -f $REPO_ROOT/.nvmrc ]]; then
  NODE_MAJOR=$(tr -d '[:space:]' <"$REPO_ROOT/.nvmrc")
fi
[[ $NODE_MAJOR =~ ^[0-9]+$ ]] || {
  echo "provision: invalid Node major version in .nvmrc: $NODE_MAJOR" >&2
  exit 1
}

# Pinned agent CLI versions (Claude Code >= 2.1.295 is required for hook onFailure: block).
CLAUDE_CODE_VERSION=2.1.332
CLAUDE_CODE_MIN_VERSION=2.1.295
CODEX_VERSION=0.172.0
AGENT_CLI_PREFIX=/opt/holt/agent-cli

# Pinned GPG key fingerprints for third-party apt repositories.
NODESOURCE_KEY_FPR=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
NTFY_KEY_FPR=55BA774A6F5EE67431E4B6B7CFDB962D4F1EC4AF

# The guard hook from aadityad12/oss-scout, pinned to one commit and checked
# by hash, so a change upstream never reaches this box without a review here.
GUARD_REPO=aadityad12/oss-scout
GUARD_COMMIT=dce9fb70e77f3963356f555344d4e4b1a2c96b23
declare -A GUARD_SHA256=(
  [guard.py]=6e8b551d6a3d904fda49890b0e836cbab21e5ea55e2d3f3e4f5d38216fb7e0a0
  [settings.agent.json]=855fe2c0dc73d24c7a2ce348bee979ed849b626dc5fcb18106e518a55d06331b
)
GUARD_DIR=/usr/local/lib/holt/guard
GUARD_RUNNER=$GUARD_DIR/run-guard
MANAGED_SETTINGS_DIR=/etc/claude-code/managed-settings.d
MANAGED_SETTINGS_FILE=$MANAGED_SETTINGS_DIR/50-holt-guard.json

NTFY_PORT=2586
NTFY_SERVE_PORT=8443

# The owner's own login user, who joins group contrib to share the clones.
OWNER=${HOLT_OWNER:-${SUDO_USER:-}}

export DEBIAN_FRONTEND=noninteractive

STATUS=unchanged
NEED_APT_UPDATE=0
APT_UPDATED_ONCE=0
WARNINGS=()
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

die() {
  echo "provision: $*" >&2
  exit 1
}
changed() { [[ $STATUS == skipped ]] || STATUS=changed; }
skipped() {
  STATUS=skipped
  WARNINGS+=("$1")
}

step() {
  local name=$1
  shift
  STATUS=unchanged
  "$@"
  printf '%-22s %s\n' "$name" "$STATUS"
}

refuse_symlink() {
  local path=$1
  [[ ! -L $path ]] || die "refusing to modify symlink: $path"
}

# ensure_dir PATH OWNER GROUP MODE (MODE as stat prints it, e.g. 750 or 2775)
ensure_dir() {
  local path=$1 owner=$2 group=$3 mode=$4
  refuse_symlink "$path"
  if [[ ! -d $path ]]; then
    mkdir -p "$path"
    changed
  fi
  refuse_symlink "$path"
  if [[ $(stat -c '%U:%G' "$path") != "$owner:$group" ]]; then
    chown -h "$owner:$group" "$path"
    changed
  fi
  if [[ $(stat -c '%a' "$path") != "$mode" ]]; then
    chmod "$mode" "$path"
    changed
  fi
}

# ensure_file SRC DEST OWNER GROUP MODE
ensure_file() {
  local src=$1 dest=$2 owner=$3 group=$4 mode=$5
  refuse_symlink "$dest"
  if ! cmp -s "$src" "$dest"; then
    install -o "$owner" -g "$group" -m "$mode" "$src" "$dest"
    changed
    return
  fi
  if [[ $(stat -c '%U:%G' "$dest") != "$owner:$group" ]]; then
    chown -h "$owner:$group" "$dest"
    changed
  fi
  if [[ $(stat -c '%a' "$dest") != "${mode#0}" ]]; then
    chmod "$mode" "$dest"
    changed
  fi
}

# ensure_mode PATH OWNER GROUP MODE (for existing secret files managed elsewhere)
ensure_mode() {
  local path=$1 owner=$2 group=$3 mode=$4
  refuse_symlink "$path"
  if [[ $(stat -c '%U:%G' "$path") != "$owner:$group" ]]; then
    chown -h "$owner:$group" "$path"
    changed
  fi
  if [[ $(stat -c '%a' "$path") != "${mode#0}" ]]; then
    chmod "$mode" "$path"
    changed
  fi
}

# ensure_content DEST OWNER GROUP MODE, with the content on stdin
ensure_content() {
  local tmp
  tmp=$(mktemp -p "$TMP_DIR")
  cat >"$tmp"
  ensure_file "$tmp" "$@"
}

# ensure_agent_line FILE LINE: append LINE to a file inside /home/agent as agent
ensure_agent_line() {
  local path=$1 line=$2
  refuse_symlink "$path"
  if ! runuser -u agent -- grep -Fqx -- "$line" "$path" 2>/dev/null; then
    # shellcheck disable=SC2016 # $1/$2/$path/$line expand inside sh -c, not here
    runuser -u agent -- sh -c '
      path=$1
      line=$2
      [ ! -L "$path" ] || exit 1
      printf "%s\n" "$line" >>"$path"
    ' _ "$path" "$line"
    changed
  fi
}

# ensure_agent_file SRC DEST MODE: copy SRC to DEST inside /home/agent as agent
ensure_agent_file() {
  local src=$1 dest=$2 mode=$3
  refuse_symlink "$dest"
  if [[ -f $dest ]] && cmp -s "$src" "$dest" &&
    [[ $(stat -c '%U:%G' "$dest") == "agent:agent" ]] &&
    [[ $(stat -c '%a' "$dest") == "${mode#0}" ]]; then
    return
  fi
  # shellcheck disable=SC2016 # variables expand inside sh -c, not here
  runuser -u agent -- sh -c '
    dest=$1
    mode=$2
    [ ! -L "$dest" ] || exit 1
    dir=$(dirname "$dest")
    tmp=$(mktemp "$dir/.provision.XXXXXX")
    trap '\''rm -f "$tmp"'\'' EXIT
    cat >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
    trap - EXIT
  ' _ "$dest" "$mode" <"$src"
  changed
}

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_update_if_needed() {
  if ((NEED_APT_UPDATE)); then
    apt-get update -qq
    NEED_APT_UPDATE=0
    APT_UPDATED_ONCE=1
  fi
}

apt_get_install() {
  apt-get install -y -qq \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

apt_install() {
  local missing=() pkg
  for pkg in "$@"; do
    is_installed "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    NEED_APT_UPDATE=1
    apt_update_if_needed
    apt_get_install "${missing[@]}"
    changed
  fi
}

# Install PKG, or upgrade it when the installed version is not the one apt
# would pick (used for packages that come from an added repository).
apt_install_candidate() {
  local pkg=$1 installed candidate
  apt_update_if_needed
  installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
  candidate=$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2}')
  # If a previous run wrote the repo file before apt-get update succeeded, refresh once.
  if [[ (-z $candidate || $candidate == "(none)") && $APT_UPDATED_ONCE -eq 0 ]]; then
    NEED_APT_UPDATE=1
    apt_update_if_needed
    candidate=$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2}')
  fi
  [[ -n $candidate && $candidate != "(none)" ]] || die "apt has no candidate for $pkg"
  if [[ $installed != "$candidate" ]]; then
    apt_get_install "$pkg"
    changed
  fi
}

# ensure_apt_repo NAME KEY_URL ARMORED(yes|no) KEY_FPR SOURCE_LINE [PIN_ORIGIN PIN_PACKAGE]
ensure_apt_repo() {
  local name=$1 key_url=$2 armored=$3 key_fpr=$4 line=$5 pin_origin=${6:-} pin_pkg=${7:-}
  local keyring=/etc/apt/keyrings/$name.gpg list=/etc/apt/sources.list.d/$name.list
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -s $keyring ]]; then
    curl -fsSL "$key_url" -o "$TMP_DIR/$name.key"
    local got_fpr
    got_fpr=$(gpg --show-keys --with-colons "$TMP_DIR/$name.key" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')
    [[ $got_fpr == "$key_fpr" ]] ||
      die "GPG key fingerprint mismatch for $name: got '${got_fpr:-none}', expected '$key_fpr'"
    if [[ $armored == yes ]]; then
      gpg --dearmor <"$TMP_DIR/$name.key" >"$TMP_DIR/$name.gpg"
    else
      mv "$TMP_DIR/$name.key" "$TMP_DIR/$name.gpg"
    fi
    install -m 0644 "$TMP_DIR/$name.gpg" "$keyring"
    NEED_APT_UPDATE=1
    changed
  fi
  if [[ "$(cat "$list" 2>/dev/null)" != "$line" ]]; then
    printf '%s\n' "$line" >"$list"
    chmod 0644 "$list"
    NEED_APT_UPDATE=1
    changed
  fi
  if [[ -n $pin_origin ]]; then
    local pref=/etc/apt/preferences.d/$name
    local want
    want=$(printf 'Package: %s\nPin: origin %s\nPin-Priority: 600' "$pin_pkg" "$pin_origin")
    if [[ "$(cat "$pref" 2>/dev/null)" != "$want" ]]; then
      printf '%s\n' "$want" >"$pref"
      chmod 0644 "$pref"
      NEED_APT_UPDATE=1
      changed
    fi
  fi
}

tailscale_running() {
  command -v tailscale >/dev/null &&
    [[ $(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty') == Running ]]
}

tailscale_dns_name() {
  tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//'
}

tailscale_has_certs() {
  tailscale status --json 2>/dev/null | jq -e '(.CertDomains // []) | length > 0' >/dev/null 2>&1
}

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# Check whether an ntfy access output block for USER contains PATTERN
ntfy_user_has_access() {
  local access_out=$1 user=$2 pattern=$3
  awk -v u="user $user " -v p="$pattern" '
    index($0, u) == 1 { in_user = 1; next }
    /^user / { in_user = 0 }
    in_user && index($0, p) > 0 { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' <<<"$access_out"
}

# --- steps -----------------------------------------------------------------

step_packages() {
  apt_install ca-certificates curl gnupg git tmux build-essential python3 jq \
    sqlite3 ufw unattended-upgrades acl
  local tmux_version
  tmux_version=$(tmux -V | sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')
  if [[ -z $tmux_version ]] || ! dpkg --compare-versions "$tmux_version" ge 3.2; then
    die "tmux ${tmux_version:-unknown} is older than 3.2"
  fi
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' ||
    die "python3 is older than 3.11"
}

step_unattended_upgrades() {
  ensure_content /etc/apt/apt.conf.d/20auto-upgrades root root 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

step_node() {
  local arch
  arch=$(dpkg --print-architecture)
  ensure_apt_repo nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key yes \
    "$NODESOURCE_KEY_FPR" \
    "deb [arch=$arch signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    deb.nodesource.com nodejs
  apt_install_candidate nodejs
  local major
  major=$(/usr/bin/node --version | sed -E 's/^v([0-9]+).*/\1/')
  [[ $major == "$NODE_MAJOR" ]] || die "/usr/bin/node is v$major, expected v$NODE_MAJOR"
}

step_users() {
  if ! getent group contrib >/dev/null; then
    groupadd contrib
    changed
  fi
  if ! id holt >/dev/null 2>&1; then
    useradd --system --user-group --home-dir /var/lib/holt --no-create-home \
      --shell /usr/sbin/nologin holt
    changed
  fi
  if ! id agent >/dev/null 2>&1; then
    useradd --create-home --user-group --home-dir /home/agent --shell /bin/bash agent
    changed
  fi
  if ! id -nG agent | tr ' ' '\n' | grep -qx contrib; then
    usermod -aG contrib agent
    changed
  fi
  if [[ -n $OWNER && $OWNER != root ]]; then
    id "$OWNER" >/dev/null 2>&1 || die "owner user '$OWNER' does not exist"
    if ! id -nG "$OWNER" | tr ' ' '\n' | grep -qx contrib; then
      usermod -aG contrib "$OWNER"
      changed
    fi
  else
    WARNINGS+=("no non-root owner user found (run with sudo as your login user or set HOLT_OWNER=<login>); nobody was added to group contrib")
  fi
  # agent must never hold any privileged group membership
  local group
  for group in sudo admin wheel docker lxd adm disk shadow; do
    if id -nG agent | tr ' ' '\n' | grep -qx "$group"; then
      gpasswd -d agent "$group" >/dev/null
      changed
    fi
  done
}

step_folders() {
  ensure_dir /var/lib/holt holt holt 700
  ensure_dir /etc/holt root holt 750
  ensure_dir /etc/holt/credentials root root 700
  ensure_dir /home/agent agent agent 750
  # group contrib may pass through /home/agent (not list it) to reach the clones
  if ! getfacl -cp /home/agent 2>/dev/null | grep -qx 'group:contrib:--x'; then
    setfacl -m g:contrib:--x /home/agent
    changed
  fi

  # Everything inside /home/agent is modified strictly as agent to prevent
  # symlink attacks against root.
  local clones=/home/agent/oss-contrib
  refuse_symlink "$clones"
  if [[ ! -d $clones ]]; then
    runuser -u agent -- install -d -m 2775 -g contrib "$clones"
    changed
  else
    if [[ $(stat -c '%U:%G' "$clones") != "agent:contrib" ]]; then
      runuser -u agent -- chgrp -h contrib "$clones"
      changed
    fi
    if [[ $(stat -c '%a' "$clones") != "2775" ]]; then
      runuser -u agent -- chmod 2775 "$clones"
      changed
    fi
  fi
  # Default ACL so files created by agent or owner stay group-writable by contrib
  if ! getfacl -dcp "$clones" 2>/dev/null | grep -qx 'group:contrib:rwx'; then
    runuser -u agent -- setfacl -d -m g:contrib:rwx,m:rwx "$clones"
    changed
  fi

  local rc
  for rc in /home/agent/.profile /home/agent/.bashrc; do
    ensure_agent_line "$rc" 'export OSS_CONTRIB_DIR=/home/agent/oss-contrib'
    ensure_agent_line "$rc" "export PATH=\"$AGENT_CLI_PREFIX/bin:\$PATH\""
    ensure_agent_line "$rc" 'export DISABLE_AUTOUPDATER=1'
  done

  ensure_dir /srv/holt root root 755
  ensure_dir /srv/holt/briefings holt agent 750
}

step_tailscale() {
  if ! command -v tailscale >/dev/null; then
    local codename=$VERSION_CODENAME # from /etc/os-release, read at the start
    # same file names as Tailscale's own installer, so the two never clash
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$codename.tailscale-keyring.list" \
      -o /etc/apt/sources.list.d/tailscale.list
    NEED_APT_UPDATE=1
    apt_install tailscale
    changed
  fi
  if ! systemctl is-enabled --quiet tailscaled || ! systemctl is-active --quiet tailscaled; then
    systemctl enable --now tailscaled
    changed
  fi
  # Wait briefly for tailscaled's local API socket after first start
  local i
  for ((i = 0; i < 15; i++)); do
    tailscale debug prefs >/dev/null 2>&1 && break
    sleep 1
  done
  if [[ $(tailscale debug prefs 2>/dev/null | jq -r '.OperatorUser // empty') != holt ]]; then
    tailscale set --operator=holt
    changed
  fi
  tailscale_running || skipped "Tailscale is not logged in: run 'sudo tailscale up --operator=holt', then run this script again"
}

step_firewall() {
  if ! tailscale_running || ! ip link show tailscale0 >/dev/null 2>&1; then
    skipped "firewall not turned on because Tailscale is not up (it would lock you out)"
    return
  fi
  if [[ -n ${SSH_CONNECTION:-} ]]; then
    local ssh_src
    ssh_src=$(awk '{print $1}' <<<"$SSH_CONNECTION")
    if [[ ! $ssh_src =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]; then
      WARNINGS+=("SSH session is from $ssh_src (not Tailscale); new non-Tailscale connections will be blocked by ufw")
    fi
  fi
  local st
  st=$(ufw status verbose)
  if ! grep -q '^Status: active' <<<"$st" ||
    ! grep -q 'Default: deny (incoming)' <<<"$st" ||
    ! grep -qE '^Anywhere on tailscale0 +ALLOW IN +Anywhere' <<<"$st"; then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow in on tailscale0 >/dev/null
    ufw --force enable >/dev/null
    changed
    st=$(ufw status verbose)
  fi
  if grep -E 'ALLOW IN' <<<"$st" | grep -qv 'on tailscale0'; then
    WARNINGS+=("ufw has other ALLOW rules besides tailscale0; check 'sudo ufw status' and remove them so nothing listens on the LAN")
  fi
}

step_bridge() {
  ensure_dir /usr/local/libexec/holt root root 755
  ensure_file "$FILES_DIR/agentctl" /usr/local/libexec/holt/agentctl root root 0755
  visudo -cqf "$FILES_DIR/holt-agentctl.sudoers" >/dev/null ||
    die "the sudoers file did not pass visudo"
  ensure_file "$FILES_DIR/holt-agentctl.sudoers" /etc/sudoers.d/holt-agentctl root root 0440
  visudo -cq >/dev/null || die "sudoers no longer passes visudo, fix it before logging out"
}

step_guard() {
  ensure_dir /usr/local/lib/holt root root 755
  ensure_dir "$GUARD_DIR" root root 755
  local file dest
  for file in "${!GUARD_SHA256[@]}"; do
    dest=$GUARD_DIR/$file
    refuse_symlink "$dest"
    if [[ -f $dest ]] && sha256sum "$dest" | grep -q "^${GUARD_SHA256[$file]} "; then
      ensure_mode "$dest" root root 0644
      continue
    fi
    curl -fsSL "https://raw.githubusercontent.com/$GUARD_REPO/$GUARD_COMMIT/guard/$file" \
      -o "$TMP_DIR/$file"
    sha256sum "$TMP_DIR/$file" | grep -q "^${GUARD_SHA256[$file]} " ||
      die "guard file $file does not match its pinned hash"
    ensure_file "$TMP_DIR/$file" "$dest" root root 0644
  done
  ensure_file "$FILES_DIR/holt-guard-hook" "$GUARD_RUNNER" root root 0755
  [[ $(/usr/bin/python3 -I "$GUARD_DIR/guard.py" --version) == "guard 1" ]] ||
    die "unexpected guard version"
}

step_claude_settings() {
  ensure_dir /etc/claude-code root root 755
  ensure_dir "$MANAGED_SETTINGS_DIR" root root 755
  jq -e . "$GUARD_DIR/settings.agent.json" >/dev/null || die "guard settings are not valid JSON"
  # Rewrite the hook command to the root-owned isolated wrapper (scoped to agent UID)
  # and omit machine-wide permissions.deny so the owner's own Claude Code on this box
  # keeps working while agent is strictly enforced by guard.py --profile agent.
  jq --arg runner "$GUARD_RUNNER" '
    del(.permissions)
    | .hooks.PreToolUse |= map(.hooks |= map(
        if (.command // "") | contains("guard.py")
        then .command = $runner | .onFailure = "block"
        else .
        end
      ))
  ' "$GUARD_DIR/settings.agent.json" >"$TMP_DIR/managed-guard.json"
  ensure_file "$TMP_DIR/managed-guard.json" "$MANAGED_SETTINGS_FILE" root root 0644
}

installed_npm_pkg_version() {
  local pkg_json=$AGENT_CLI_PREFIX/lib/node_modules/$1/package.json
  [[ -f $pkg_json ]] || return 0
  jq -r '.version // empty' "$pkg_json" 2>/dev/null || true
}

step_agent_clis() {
  ensure_dir /opt/holt root root 755
  ensure_dir "$AGENT_CLI_PREFIX" root agent 750
  local spec pkg bin want have
  for spec in "@anthropic-ai/claude-code:claude:$CLAUDE_CODE_VERSION" "@openai/codex:codex:$CODEX_VERSION"; do
    pkg=${spec%%:*}
    local rest=${spec#*:}
    bin=${rest%%:*}
    want=${rest#*:}
    have=$(installed_npm_pkg_version "$pkg")
    if [[ $have != "$want" || ! -x $AGENT_CLI_PREFIX/bin/$bin ]]; then
      /usr/bin/npm install -g --prefix "$AGENT_CLI_PREFIX" \
        --no-fund --no-audit --loglevel=error "$pkg@$want"
      chown -R root:agent "$AGENT_CLI_PREFIX"
      chmod 0750 "$AGENT_CLI_PREFIX"
      chmod -R go-w "$AGENT_CLI_PREFIX"
      changed
    fi
  done
  local claude_ver
  claude_ver=$(runuser -u agent -- "$AGENT_CLI_PREFIX/bin/claude" --version 2>/dev/null |
    sed -E 's/^[^0-9]*([0-9]+(\.[0-9]+)*).*/\1/')
  if [[ -z $claude_ver ]] || ! dpkg --compare-versions "$claude_ver" ge "$CLAUDE_CODE_MIN_VERSION"; then
    die "Claude Code ${claude_ver:-unknown} is older than $CLAUDE_CODE_MIN_VERSION (needed for hook onFailure: block)"
  fi
}

step_tmux_conf() {
  ensure_agent_file "$FILES_DIR/agent.tmux.conf" /home/agent/.tmux.conf 0644
}

step_ntfy() {
  local arch
  arch=$(dpkg --print-architecture)
  ensure_apt_repo ntfy https://archive.ntfy.sh/apt/keyring.gpg no \
    "$NTFY_KEY_FPR" \
    "deb [arch=$arch signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main" \
    archive.ntfy.sh ntfy
  apt_install_candidate ntfy

  local dns
  dns=$(tailscale_dns_name || true)
  local before=$STATUS
  STATUS=unchanged
  {
    echo "# Managed by Holt deploy/provision.sh. Changes here are overwritten."
    if [[ -n $dns ]]; then
      printf 'base-url: "https://%s:%s"\n' "$dns" "$NTFY_SERVE_PORT"
    fi
    cat <<EOF
listen-http: "127.0.0.1:$NTFY_PORT"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
behind-proxy: true
EOF
  } | ensure_content /etc/ntfy/server.yml root root 0644
  local config_changed=$STATUS
  STATUS=$before
  [[ $config_changed == changed ]] && changed

  ensure_dir /var/lib/ntfy ntfy ntfy 700
  if ! systemctl is-enabled --quiet ntfy; then
    systemctl enable ntfy >/dev/null 2>&1
    changed
  fi
  if [[ $config_changed == changed ]] || ! systemctl is-active --quiet ntfy; then
    systemctl restart ntfy
    changed
  fi

  # Wait for ntfy to become healthy and initialize /var/lib/ntfy/user.db
  local i ready=0
  for ((i = 0; i < 15; i++)); do
    if [[ -f /var/lib/ntfy/user.db ]] && curl -fsS "http://127.0.0.1:$NTFY_PORT/v1/health" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if ((!ready)); then
    journalctl -u ntfy -n 20 --no-pager >&2 || true
    die "ntfy did not become ready with /var/lib/ntfy/user.db within 15s"
  fi

  local ntfy=(runuser -u ntfy -- ntfy)
  local topic_file=/etc/holt/ntfy-topic token_file=/etc/holt/credentials/ntfy-token
  local phone_file=/etc/holt/credentials/ntfy-phone-password
  local topic
  if [[ ! -s $topic_file ]]; then
    printf 'holt-%s\n' "$(random_hex 8)" >"$TMP_DIR/topic"
    ensure_file "$TMP_DIR/topic" "$topic_file" root holt 0640
  else
    ensure_mode "$topic_file" root holt 0640
  fi
  topic=$(<"$topic_file")

  local users
  users=$("${ntfy[@]}" user list 2>&1) || die "ntfy user list failed: $users"
  if ! grep -qE '^user holtpub ' <<<"$users"; then
    NTFY_PASSWORD=$(random_hex 24) "${ntfy[@]}" user add --role=user holtpub >/dev/null
    changed
  fi
  if ! grep -qE '^user phone ' <<<"$users"; then
    local pw
    pw=$(random_hex 12)
    NTFY_PASSWORD=$pw "${ntfy[@]}" user add --role=user phone >/dev/null
    printf '%s\n' "$pw" >"$TMP_DIR/phone-pw"
    ensure_file "$TMP_DIR/phone-pw" "$phone_file" root root 0600
    changed
  elif [[ ! -s $phone_file ]]; then
    local pw
    pw=$(random_hex 12)
    NTFY_PASSWORD=$pw "${ntfy[@]}" user change-pass phone >/dev/null
    printf '%s\n' "$pw" >"$TMP_DIR/phone-pw"
    ensure_file "$TMP_DIR/phone-pw" "$phone_file" root root 0600
    changed
  else
    ensure_mode "$phone_file" root root 0600
  fi

  local access
  access=$("${ntfy[@]}" access 2>&1) || die "ntfy access failed: $access"
  if ! ntfy_user_has_access "$access" holtpub "write-only access to topic $topic"; then
    "${ntfy[@]}" access holtpub "$topic" write-only >/dev/null
    changed
  fi
  if ! ntfy_user_has_access "$access" phone "read-only access to topic $topic"; then
    "${ntfy[@]}" access phone "$topic" read-only >/dev/null
    changed
  fi

  if [[ ! -s $token_file ]]; then
    local out token
    out=$("${ntfy[@]}" token add --label=holt holtpub)
    token=$(grep -oE 'tk_[A-Za-z0-9]+' <<<"$out" | head -n1)
    [[ -n $token ]] || die "could not create the ntfy token"
    printf '%s\n' "$token" >"$TMP_DIR/ntfy-token"
    ensure_file "$TMP_DIR/ntfy-token" "$token_file" root root 0600
    changed
  else
    ensure_mode "$token_file" root root 0600
  fi
}

step_ntfy_serve() {
  if ! tailscale_running; then
    skipped "ntfy is not on the tailnet yet: log in to Tailscale and run this script again"
    return
  fi
  if ! tailscale_has_certs; then
    skipped "Tailscale HTTPS certificates are off: enable MagicDNS and HTTPS Certificates in the Tailscale admin page, then run this script again"
    return
  fi
  if tailscale serve status --json 2>/dev/null |
    jq -e --arg p "$NTFY_SERVE_PORT" --arg u "http://127.0.0.1:$NTFY_PORT" '
      (.TCP[$p].HTTPS == true) and
      ((.Web // {}) | to_entries | any((.key | endswith(":" + $p)) and (.value.Handlers["/"].Proxy == $u)))
    ' >/dev/null; then
    return
  fi
  local serve_err
  if serve_err=$(timeout 60 tailscale serve --bg --https="$NTFY_SERVE_PORT" "http://127.0.0.1:$NTFY_PORT" 2>&1); then
    changed
  else
    skipped "tailscale serve failed (${serve_err:-timed out}): check MagicDNS and HTTPS certificates in the Tailscale admin page, then run this script again"
  fi
}

# --- main ------------------------------------------------------------------

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"
# shellcheck disable=SC1091
. /etc/os-release
[[ $ID == ubuntu ]] || die "this script is for Ubuntu, found $ID"
dpkg --compare-versions "$VERSION_ID" ge 24.04 || die "needs Ubuntu 24.04 or newer, found $VERSION_ID"

step packages step_packages
step unattended-upgrades step_unattended_upgrades
step node step_node
step users step_users
step folders step_folders
step tailscale step_tailscale
step firewall step_firewall
step agentctl-bridge step_bridge
step guard step_guard
step claude-settings step_claude_settings
step agent-clis step_agent_clis
step tmux-conf step_tmux_conf
step ntfy step_ntfy
step ntfy-serve step_ntfy_serve

if ((${#WARNINGS[@]})); then
  echo
  echo "Needs your attention:"
  printf '  - %s\n' "${WARNINGS[@]}"
fi
echo
echo "Done. Manual steps and checks: deploy/README.md, then run deploy/verify-boundary.sh."
