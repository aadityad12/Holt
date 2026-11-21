# Holt

A safe home base for your coding agents.

Holt runs on your own always-on Linux box. It keeps your project folders, runs
long-lived coding-agent sessions (Claude Code, Codex, or any terminal agent),
and sends you a notification when an agent needs you. Your laptop and phone are
just screens for it: start a session on the laptop, close the lid, and carry on
from your phone. The work keeps running at home.

Safety comes first. Agents run under their own locked-down account with no
GitHub write access, nothing is posted without your explicit approval, and
every action is recorded in an audit log.

The first built-in feature connects to
[OSS Scout](https://github.com/aadityad12/oss-scout), which finds open source
issues worth working on each night.

Devices reach Holt over Tailscale today. The server only listens locally, so
the network in front of it can be replaced later.

## Status

Early planning. See the [issues](https://github.com/aadityad12/Holt/issues)
and [milestones](https://github.com/aadityad12/Holt/milestones) for the plan.

## License

[MIT](LICENSE)
