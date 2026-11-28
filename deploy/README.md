# Setting up the mini PC

These scripts turn an Ubuntu 24.04 (or newer) box into a Holt host. They install
the tools, create the two users that keep the agent away from your keys, and set
up phone notifications.

- `provision.sh` sets everything up. Run it as root. It is safe to run again:
  each step prints `changed`, `unchanged` or `skipped`.
- `verify-boundary.sh` checks the result and prints PASS or FAIL per check.
- `files/` holds the files that `provision.sh` installs.

## The two users

| User    | Holds                                                                     | Cannot                                              |
| ------- | ------------------------------------------------------------------------- | --------------------------------------------------- |
| `holt`  | the Holt server and every token, in `/etc/holt` and `/var/lib/holt`       | write to `/home/agent`                              |
| `agent` | the Claude Code and Codex logins, the clones in `/home/agent/oss-contrib` | read anything of `holt`'s, use sudo, push to GitHub |

`holt` can do exactly one thing as `agent`: run
`/usr/local/libexec/holt/agentctl`, through the rule in
`/etc/sudoers.d/holt-agentctl`. Today that program only has `ping`.

Your own login user joins group `contrib`, so you can work in the same clones.
Log out and back in once for that to take effect.

## Before you start

1. Make sure you can reach the box over Tailscale (for example
   `ssh minipc` from your laptop with Tailscale on). The firewall step blocks
   every connection that does not come through Tailscale, so an SSH session over
   your home network stops working for new connections. A keyboard and screen on
   the box also work as a fallback. (Note: `ufw`'s default `before.rules` still
   permits mDNS on UDP 5353 on the LAN; everything else is denied by default.)
2. In the [Tailscale admin page](https://login.tailscale.com/admin/dns), turn on
   **MagicDNS** and **HTTPS Certificates**. The ntfy step needs both.

## Steps

### On a box where Tailscale is already logged in

```bash
# 1. Set everything up
sudo deploy/provision.sh

# 2. Confirm idempotency (every step should print "unchanged")
sudo deploy/provision.sh

# 3. Log the agent CLIs in, once each, as the agent user
sudo -u agent -i
claude    # follow the login prompts, then /exit
codex     # follow the login prompts, then exit
exit

# 4. Check the walls
deploy/verify-boundary.sh
```

### On a fresh box (Tailscale not installed yet)

```bash
# 1. First pass installs Tailscale and everything else it can before login
sudo deploy/provision.sh

# 2. Log in to Tailscale (keep --operator=holt)
sudo tailscale up --operator=holt

# 3. Second pass turns on the firewall and exposes ntfy over Tailscale HTTPS
sudo deploy/provision.sh

# 4. Confirm idempotency (every step should print "unchanged")
sudo deploy/provision.sh
```

Then continue with steps 3 and 4 above (log in `claude` and `codex` as `agent`,
and run `deploy/verify-boundary.sh`).

If `provision.sh` lists anything under "Needs your attention", fix it and run it
again.

## Phone notifications (ntfy)

ntfy runs on the box on `127.0.0.1:2586` and is reachable only over Tailscale at
`https://<box>.<tailnet>.ts.net:8443`. Nobody can read or post without logging
in.

- Topic name: `sudo cat /etc/holt/ntfy-topic`
- Phone login: user `phone`, password from
  `sudo cat /etc/holt/credentials/ntfy-phone-password`. This user can only read.
- Holt posts with the `holtpub` user's token in
  `/etc/holt/credentials/ntfy-token`. That user can only write.

On Android, install the ntfy app, add your server
`https://<box>.<tailnet>.ts.net:8443`, log in as `phone`, and subscribe to the
topic. (On iOS, background delivery requires setting
`upstream-base-url: "https://ntfy.sh"` in `/etc/ntfy/server.yml`, which sends
hashed poll requests through `ntfy.sh` to wake APNs.) Then send a test message
from the box:

```bash
topic=$(sudo cat /etc/holt/ntfy-topic)
curl -H "Authorization: Bearer $(sudo cat /etc/holt/credentials/ntfy-token)" \
  -d test "https://$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")'):8443/$topic"
```

The same request without the `Authorization` header must get 401 or 403.

## The guard hook and agent CLIs

`provision.sh` installs the guard from
[oss-scout](https://github.com/aadityad12/oss-scout/tree/main/guard) to
`/usr/local/lib/holt/guard/`, pinned to one commit and checked by hash. The files
belong to root, so `agent` cannot change them.

It is registered via a drop-in at
`/etc/claude-code/managed-settings.d/50-holt-guard.json` (which user and project
settings cannot override, and which leaves any existing `managed-settings.json`
alone). The hook runs `/usr/local/lib/holt/guard/run-guard`, a root-owned
Python `-I` wrapper that enforces `guard.py --profile agent` **only** when the
effective user is `agent`, so your own Claude Code sessions on the same machine
are unaffected.

The guard is defense in depth for Claude Code (it blocks `git push`, GitHub
writes, `sudo`, and Holt paths, though shell-level hooks have inherent limits;
the Unix user split and lack of GitHub credentials are the primary barrier). To
update the guard, change `GUARD_COMMIT` and the hashes at the top of
`provision.sh`.

Claude Code and Codex are installed at pinned versions under
`/opt/holt/agent-cli` (`root:agent`, mode `0750`) so `agent` can execute them
but cannot patch or downgrade them.

**Codex has no guard hook here.** For Codex sessions, the user split is the only
barrier until #29 (a container per session).

## Optional: a read-only GitHub token for agent

Without a login, `gh` and `git` as `agent` hit GitHub's rate limit for
unauthenticated requests sooner. If that becomes a problem, you can give `agent`
a fine-grained token with read-only access to public repositories only, in
`/home/agent/.config/gh/hosts.yml`. Never give it a token that can write. With
such a token, the `gh` checks in `verify-boundary.sh` show FAIL; verify by hand
that the token has no write permissions.

## Fallback: reaching a session from a phone terminal

Over OpenSSH through Tailscale: `ssh <box>`, then `sudo -u agent tmux attach`.

## Maintenance notes

- **Ubuntu updates vs third-party repos:** `unattended-upgrades` handles Ubuntu
  security updates automatically, but does not upgrade packages from the
  NodeSource or ntfy repositories (or the pinned npm CLIs). Re-run
  `sudo deploy/provision.sh` periodically to pick up newer versions.
- **Desktop login screen (GDM):** On Ubuntu Desktop, `agent` may appear on the
  graphical login screen. To hide it, create
  `/var/lib/AccountsService/users/agent` containing `[User]` and
  `SystemAccount=true`.
- **sudoers on Ubuntu 24.04 vs 26.04:** Ubuntu 26.04 ships `sudo-rs`, which
  supports the trailing `*` wildcard in `holt-agentctl.sudoers` from 0.2.13 on.

## After a reboot

ntfy and tailscaled start by themselves. Run `deploy/verify-boundary.sh` again
to confirm everything still passes.
