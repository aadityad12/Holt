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

# Node.js major version for the agent CLIs (the current LTS line).
NODE_MAJOR=26

# The guard hook from aadityad12/oss-scout, pinned to one commit and checked
# by hash, so a change upstream never reaches this box without a review here.
GUARD_REPO=aadityad12/oss-scout
GUARD_COMMIT=dce9fb70e77f3963356f555344d4e4b1a2c96b23
declare -A GUARD_SHA256=(
  [guard.py]=6e8b551d6a3d904fda49890b0e836cbab21e5ea55e2d3f3e4f5d38216fb7e0a0
  [settings.agent.json]=855fe2c0dc73d24c7a2ce348bee979ed849b626dc5fcb18106e518a55d06331b
)
GUARD_DIR=/usr/local/lib/holt/guard

NTFY_PORT=2586
NTFY_SERVE_PORT=8443

# The owner's own login user, who joins group contrib to share the clones.
OWNER=${HOLT_OWNER:-${SUDO_USER:-}}

export DEBIAN_FRONTEND=noninteractive

STATUS=unchanged
NEED_APT_UPDATE=0
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

# ensure_dir PATH OWNER GROUP MODE (MODE as stat prints it, e.g. 750 or 2775)
ensure_dir() {
  local path=$1 owner=$2 group=$3 mode=$4
  if [[ ! -d $path ]]; then
    mkdir -p "$path"
    changed
  fi
  if [[ $(stat -c '%U:%G' "$path") != "$owner:$group" ]]; then
    chown "$owner:$group" "$path"
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
  if ! cmp -s "$src" "$dest"; then
    install -o "$owner" -g "$group" -m "$mode" "$src" "$dest"
    changed
    return
  fi
  if [[ $(stat -c '%U:%G' "$dest") != "$owner:$group" ]]; then
    chown "$owner:$group" "$dest"
    changed
  fi
  if [[ $(stat -c '%a' "$dest") != "${mode#0}" ]]; then
    chmod "$mode" "$dest"
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

is_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_update_if_needed() {
  if ((NEED_APT_UPDATE)); then
    apt-get update -qq
    NEED_APT_UPDATE=0
  fi
}

apt_install() {
  local missing=() pkg
  for pkg in "$@"; do
    is_installed "$pkg" || missing+=("$pkg")
  done
  if ((${#missing[@]})); then
    NEED_APT_UPDATE=1
    apt_update_if_needed
    apt-get install -y -qq "${missing[@]}"
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
  [[ -n $candidate && $candidate != "(none)" ]] || die "apt has no candidate for $pkg"
  if [[ $installed != "$candidate" ]]; then
    apt-get install -y -qq "$pkg"
    changed
  fi
}

# ensure_apt_repo NAME KEY_URL ARMORED(yes|no) SOURCE_LINE [PIN_ORIGIN PIN_PACKAGE]
ensure_apt_repo() {
  local name=$1 key_url=$2 armored=$3 line=$4 pin_origin=${5:-} pin_pkg=${6:-}
  local keyring=/etc/apt/keyrings/$name.gpg list=/etc/apt/sources.list.d/$name.list
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -s $keyring ]]; then
    curl -fsSL "$key_url" -o "$TMP_DIR/$name.key"
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
    [[ $(tailscale status --json 2>/dev/null | jq -r '.BackendState') == Running ]]
}

tailscale_dns_name() {
  tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//'
}

random_hex() {
  od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# --- steps -----------------------------------------------------------------

step_packages() {
  apt_install ca-certificates curl gnupg git tmux build-essential python3 jq \
    sqlite3 ufw unattended-upgrades acl
  local tmux_version
  tmux_version=$(tmux -V | awk '{print $2}' | tr -d '[:lower:]')
  dpkg --compare-versions "$tmux_version" ge 3.2 || die "tmux $tmux_version is older than 3.2"
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
    useradd --system --user-group --home-dir /var/lib/holt --create-home \
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
    if ! id -nG "$OWNER" | tr ' ' '\n' | grep -qx contrib; then
      usermod -aG contrib "$OWNER"
      changed
    fi
  else
    skipped "no owner user found (set HOLT_OWNER=<your login>), nobody was added to group contrib"
  fi
  # agent must never have sudo
  local group
  for group in sudo admin wheel; do
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
  ensure_dir /home/agent/oss-contrib agent contrib 2775
  if ! grep -qx 'export OSS_CONTRIB_DIR=/home/agent/oss-contrib' /home/agent/.profile 2>/dev/null; then
    echo 'export OSS_CONTRIB_DIR=/home/agent/oss-contrib' >>/home/agent/.profile
    chown agent:agent /home/agent/.profile
    changed
  fi
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
  if [[ $(tailscale debug prefs 2>/dev/null | jq -r '.OperatorUser // empty') != holt ]]; then
    tailscale set --operator=holt
    changed
  fi
  tailscale_running || skipped "Tailscale is not logged in: run 'sudo tailscale up', then run this script again"
}

step_firewall() {
  if ! tailscale_running || ! ip link show tailscale0 >/dev/null 2>&1; then
    skipped "firewall not turned on because Tailscale is not up (it would lock you out)"
    return
  fi
  local st
  st=$(ufw status verbose)
  if ! grep -q '^Status: active' <<<"$st" ||
    ! grep -q 'Default: deny (incoming)' <<<"$st" ||
    ! grep -qE 'on tailscale0 +ALLOW IN' <<<"$st"; then
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
  visudo -cqf "$FILES_DIR/holt-agentctl.sudoers" || die "the sudoers file did not pass visudo"
  ensure_file "$FILES_DIR/holt-agentctl.sudoers" /etc/sudoers.d/holt-agentctl root root 0440
  visudo -cq || die "sudoers no longer passes visudo, fix it before logging out"
}

step_guard() {
  ensure_dir /usr/local/lib/holt root root 755
  ensure_dir "$GUARD_DIR" root root 755
  local file dest
  for file in "${!GUARD_SHA256[@]}"; do
    dest=$GUARD_DIR/$file
    if [[ -f $dest ]] && sha256sum "$dest" | grep -q "^${GUARD_SHA256[$file]} "; then
      ensure_file "$dest" "$dest" root root 0644
      continue
    fi
    curl -fsSL "https://raw.githubusercontent.com/$GUARD_REPO/$GUARD_COMMIT/guard/$file" \
      -o "$TMP_DIR/$file"
    sha256sum "$TMP_DIR/$file" | grep -q "^${GUARD_SHA256[$file]} " ||
      die "guard file $file does not match its pinned hash"
    ensure_file "$TMP_DIR/$file" "$dest" root root 0644
  done
  [[ $(python3 "$GUARD_DIR/guard.py" --version) == "guard 1" ]] || die "unexpected guard version"
}

step_claude_settings() {
  local dest=/etc/claude-code/managed-settings.json
  ensure_dir /etc/claude-code root root 755
  jq -e . "$GUARD_DIR/settings.agent.json" >/dev/null || die "guard settings are not valid JSON"
  if [[ -f $dest ]] && ! cmp -s "$GUARD_DIR/settings.agent.json" "$dest"; then
    cp -p "$dest" "$dest.bak-$(date +%Y%m%d%H%M%S)"
  fi
  ensure_file "$GUARD_DIR/settings.agent.json" "$dest" root root 0644
}

step_agent_clis() {
  local pkg bin
  for pkg in @anthropic-ai/claude-code:claude @openai/codex:codex; do
    bin=${pkg##*:}
    pkg=${pkg%:*}
    if [[ ! -x /home/agent/.local/bin/$bin ]]; then
      (cd /home/agent && sudo -u agent -H /usr/bin/npm install -g --prefix /home/agent/.local \
        --no-fund --no-audit --loglevel=error "$pkg")
      changed
    fi
  done
}

step_tmux_conf() {
  ensure_file "$FILES_DIR/agent.tmux.conf" /home/agent/.tmux.conf agent agent 0644
}

step_ntfy() {
  local arch
  arch=$(dpkg --print-architecture)
  ensure_apt_repo ntfy https://archive.ntfy.sh/apt/keyring.gpg no \
    "deb [arch=$arch signed-by=/etc/apt/keyrings/ntfy.gpg] https://archive.ntfy.sh/apt stable main" \
    archive.ntfy.sh ntfy
  apt_install_candidate ntfy

  local dns base_url=""
  dns=$(tailscale_dns_name || true)
  [[ -n $dns ]] && base_url="base-url: \"https://$dns:$NTFY_SERVE_PORT\""
  local before=$STATUS
  STATUS=unchanged
  ensure_content /etc/ntfy/server.yml root root 0644 <<EOF
# Managed by Holt deploy/provision.sh. Changes here are overwritten.
${base_url}
listen-http: "127.0.0.1:$NTFY_PORT"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
behind-proxy: true
EOF
  local config_changed=$STATUS
  STATUS=$before
  [[ $config_changed == changed ]] && changed

  ensure_dir /var/lib/ntfy ntfy ntfy 750
  if ! systemctl is-enabled --quiet ntfy; then
    systemctl enable ntfy >/dev/null 2>&1
    changed
  fi
  if [[ $config_changed == changed ]] || ! systemctl is-active --quiet ntfy; then
    systemctl restart ntfy
    changed
  fi

  local ntfy=(runuser -u ntfy -- ntfy)
  local topic_file=/etc/holt/ntfy-topic token_file=/etc/holt/credentials/ntfy-token
  local phone_file=/etc/holt/credentials/ntfy-phone-password
  local topic
  if [[ ! -s $topic_file ]]; then
    printf 'holt-%s\n' "$(random_hex 8)" >"$TMP_DIR/topic"
    ensure_file "$TMP_DIR/topic" "$topic_file" root holt 0640
  fi
  topic=$(<"$topic_file")

  local users
  users=$("${ntfy[@]}" user list 2>&1 || true)
  if ! grep -qE '^user holtpub ' <<<"$users"; then
    NTFY_PASSWORD=$(random_hex 24) "${ntfy[@]}" user add --role=user holtpub >/dev/null
    changed
  fi
  if ! grep -qE '^user phone ' <<<"$users"; then
    local pw
    pw=$(random_hex 12)
    NTFY_PASSWORD=$pw "${ntfy[@]}" user add --role=user phone >/dev/null
    (umask 077 && printf '%s\n' "$pw" >"$phone_file")
    changed
  elif [[ ! -s $phone_file ]]; then
    local pw
    pw=$(random_hex 12)
    NTFY_PASSWORD=$pw "${ntfy[@]}" user change-pass phone >/dev/null
    (umask 077 && printf '%s\n' "$pw" >"$phone_file")
    changed
  fi
  chown root:root "$phone_file" && chmod 0600 "$phone_file"

  # access rules are cheap to set again; compare first so reruns stay quiet
  local access
  access=$("${ntfy[@]}" access 2>&1 || true)
  if ! grep -A3 '^user holtpub ' <<<"$access" | grep -q "write-only access to topic $topic"; then
    "${ntfy[@]}" access holtpub "$topic" write-only >/dev/null
    changed
  fi
  if ! grep -A3 '^user phone ' <<<"$access" | grep -q "read-only access to topic $topic"; then
    "${ntfy[@]}" access phone "$topic" read-only >/dev/null
    changed
  fi

  if [[ ! -s $token_file ]]; then
    local out token
    out=$("${ntfy[@]}" token add --label=holt holtpub)
    token=$(grep -oE 'tk_[A-Za-z0-9]+' <<<"$out" | head -n1)
    [[ -n $token ]] || die "could not create the ntfy token"
    (umask 077 && printf '%s\n' "$token" >"$token_file")
    changed
  fi
  chown root:root "$token_file" && chmod 0600 "$token_file"
}

step_ntfy_serve() {
  if ! tailscale_running; then
    skipped "ntfy is not on the tailnet yet: log in to Tailscale and run this script again"
    return
  fi
  if tailscale serve status --json 2>/dev/null |
    jq -e --arg p "$NTFY_SERVE_PORT" --arg u "http://127.0.0.1:$NTFY_PORT" \
      '(.TCP[$p].HTTPS == true) and ([.. | .Proxy? // empty] | index($u) != null)' >/dev/null; then
    return
  fi
  if timeout 60 tailscale serve --bg --https="$NTFY_SERVE_PORT" "http://127.0.0.1:$NTFY_PORT" >/dev/null; then
    changed
  else
    skipped "tailscale serve failed: turn on HTTPS certificates in the Tailscale admin page, then run this script again"
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
