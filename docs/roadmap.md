# Roadmap

## What Holt is

Holt is a self-hosted home base for coding agents. It runs on one always-on Ubuntu mini PC. Your laptop and phone are only screens: you start an agent session, close the lid, and the work keeps going. You can watch, answer and approve from any of your devices.

Its first use is OSS Scout. The scout finds and prepares open source contributions every night, and Holt takes a pick from "found" to "working on it" with Claude Code or Codex running on the mini PC.

Safety comes before features. The server and every secret belong to one Unix user, `holt`. The agents run as a second user, `agent`, which has no GitHub write login. A guard hook blocks GitHub writes and pushes from agent sessions. Every action is written to an append-only audit log. The server listens only on a local Unix socket, and Tailscale sits in front of it. Holt is open source under the MIT license.

## Milestones

- **0 Setup, 2026-11-30.** The repository, the mini PC with the two Unix users and the guard hook, and a one-page threat model.
- **1 MVP, 2027-01-15.** Scout picks in the app, "Work on it" starting a session, the terminal in the app, phone alerts, the audit log, and the web app installed on a Mac and a phone.
- **2 Portfolio, 2027-02-28.** The chat view, approving from the phone, the publish button, measured speed numbers, a usage and cost meter, a subscription limit tracker, usage import from your other machines, evaluations of agent setups on real outcomes, and the finished README.
- **3 Hardening, 2027-04-30.** Per-session containers, install by other people, a model gateway, context management, project memory, and a public launch.
- **Future, no date.** Our own private network, retiring the old phone dashboard once Holt has proven it can replace it, and a C++ terminal core only if measurements ask for it.

## Ideas we are not doing now, and why

Each entry says what the idea is, why we are not doing it now, and what would change that.

### Kubernetes
- **What it is:** software that schedules and runs programs across many machines.
- **Why not now:** Holt runs on one machine for one owner. Kubernetes would add a cluster to install, update and secure, to solve a scheduling problem we do not have. systemd already starts and restarts Holt's services.
- **What would change it:** Holt having to run across several machines, and systemd units on each no longer being enough to manage them.

### Building our own private network before April 2027
- **What it is:** replacing Tailscale, the private network that links the owner's devices, with a network we run ourselves.
- **Why not now:** a private network is a product by itself. It needs key distribution (devices learning and trusting each other's keys), a way through home routers so two devices can reach each other directly, and relay servers for when a direct path fails. That is months of work during the Summer 2027 recruiting season. The server listens only locally, so the swap later replaces what sits in front of it and not the server. The design is logged as Holt #33 and it stays a design until then.
- **What would change it:** the recruiting season ending (about April 2027) and the design in Holt #33 showing an option that fits in a fixed time box, or Tailscale becoming unavailable or unacceptable for Holt's use.

### A native Android app before the web app falls short
- **What it is:** a separate Android app, written in Kotlin, instead of the installable web app.
- **Why not now:** the web app has every feature on every device and needs no extra tools. A native app needs the Android SDK, app signing and a second code base. Whether the web app actually falls short on a phone is not known yet. This is Holt #32.
- **What would change it:** at least four weeks of daily use with dated notes showing a problem a wrapper would fix, such as the soft keyboard dropping characters in the web terminal more than once a day or the connection being lost every time the screen locks.

### Wrapping the apps in Tauri first
- **What it is:** Tauri is a toolkit that packages a web app as a desktop or Android app.
- **Why not now:** the installable web app already gets its own Dock icon on the Mac and a home screen icon on Android. Tauri adds a Rust toolchain and signing, and its Android side was judged costly for the gain. It would come after the same evidence as above (Holt #32), not before it.
- **What would change it:** the evidence rule above showing that a desktop shell fixes something the web app cannot.

### Firebase or UnifiedPush push notifications
- **What it is:** two ways for a server to push alerts to an Android app. Firebase is Google's service. UnifiedPush is an open standard that needs a separate distributor app.
- **Why not now:** Holt uses ntfy, a small notification service we host ourselves, and the stock ntfy Android app. It needs no Google project and no custom app. Its known limit is that alerts can be late when Tailscale is off or the phone saves battery, and we document that.
- **What would change it:** measured late or missed alerts that setting the app to unrestricted battery use does not fix, or a native app existing for other reasons.

### Embedding Tailscale inside the server (tsnet)
- **What it is:** tsnet is a library that lets a program join the Tailscale network as its own device.
- **Why not now:** it would make the server itself a network node and tie it to Tailscale's code, which makes replacing Tailscale harder. Today `tailscale serve` and a local identity lookup do the same job from outside the server, and only one small file in Holt knows about Tailscale.
- **What would change it:** `tailscale serve` losing a feature Holt needs, with no other way to get HTTPS and the caller's identity.

### Generated API clients (OpenAPI codegen)
- **What it is:** writing the server's API as a specification file and generating client code from it.
- **Why not now:** there is one server and one client in the same repository. A small hand-written typed client that shares its schemas with the server is less to maintain than a specification and a generator.
- **What would change it:** a second client in another language, or other people building against the API.

### A plugin interface
- **What it is:** a stable way for outsiders to add providers or features to Holt without changing its code.
- **Why not now:** there is one owner and two providers, and a short config list is enough. A plugin interface is a promise to keep an API stable, and it is a place where untrusted code could enter. A single narrow contract, such as the context transform the gateway calls, is chosen by name from a fixed list and is not a plugin system.
- **What would change it:** after launch, several outside contributors asking for the same extension point.

### Chasing a user-count target
- **What it is:** setting a goal for installs, stars or users.
- **Why not now:** the product has to be solid first. Holt has no telemetry, so it could not count users honestly anyway, and a number to chase pushes features ahead of security and reliability.
- **What would change it:** nothing on a date. We revisit it only after another person has installed Holt from the docs on a fresh machine, the README is accurate, and the launch is done.

### Writing the server in Go
- **What it is:** building the server in Go instead of TypeScript on Node.
- **Why not now:** the owner reviews TypeScript, Python, C++ and Kotlin well and does not yet review Go. The one special reason for Go, embedding Tailscale, is gone. Node has the standard PTY library, and the Claude Agent SDK ships for TypeScript.
- **What would change it:** a measured speed problem that cheaper TypeScript fixes cannot close, in which case the planned answer is a small C++ process for that one path, or the owner becoming fluent in Go and a concrete benefit showing up.

### Moving the nightly scan onto the mini PC
- **What it is:** running the scout's nightly scan on the mini PC instead of in GitHub Actions.
- **Why not now:** Holt holds only two narrow GitHub tokens, and the posting token stays in the data repository's Actions secrets so that the agent box cannot post. The scan writes the data branch, so running it on the mini PC would put a write token on the box. The scan also keeps running when the home internet or power is down.
- **What would change it:** GitHub Actions limits or terms making the scan unreliable. Even then it would run as its own unprivileged user with its own token, never with Holt's.

### Retiring the existing phone dashboard before Holt has proven parity
- **What it is:** turning off the current dashboard page and its tap-to-act routes at me.aadityad.dev.
- **Why not now:** it works today, including on a phone. Holt has to do the same job first. The gate is written down in oss-scout #16: a completed parity checklist, 28 days in a row of daily use with no need for the old page, matching explanations for failed sends, and a tested way to roll back. The emails and the public page stay either way.
- **What would change it:** all four parts of that gate passing.

### The rule "no feature we cannot measure"
- **What it is:** a principle, not a project. A feature that claims to save money, time or effort is kept only if we also build the measurement that shows it does. Examples are the speed numbers, the usage and cost meter, and the evaluations of agent setups.
- **Why we hold it:** it keeps claims honest and stops features from staying because they feel useful. It also gives the project numbers it can show.
- **What would change it:** it applies to claims about benefit. Security controls are not measured but tested, with tests that prove a blocked action stays blocked, so they are outside this rule. We would drop the rule for a feature only if measuring it cost more than the feature.
