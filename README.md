# T3Bar

A clean, native macOS menu bar monitor for **[T3 Code](https://t3.codes)** agents — built with SwiftUI and Apple Liquid Glass, inspired by CodexBar and Sleepless.

Keep track of all running T3 Code threads and nested subagents right from your menu bar, without Electron or Tauri overhead.

## Features

- **Native macOS SwiftUI (`~15–25 MB RAM`)** — lightweight menu bar accessory app with Apple Liquid Glass floating panel (macOS 26 `.glassEffect` + graceful fallback on macOS 14/15).
- **Official T3 Code MCP API** — connects via T3 Code's `/mcp` endpoint using OAuth 2.1 + PKCE (RFC 9728) or an optional manual Bearer token. Credentials are stored securely in macOS Keychain.
- **Live Agent & Subagent Tree** — displays active threads with nested subagents, project badges, model names, live elapsed timer, and latest tool/activity step.
- **Top-Edge Hover-to-Open** — slide your cursor all the way to the top edge of the screen over the icon to open (toggleable in Settings).
- **T3 Code Color Themes** — switch between all 6 T3 Code themes (**T3 Code**, **T3 Chat**, **Grove**, **Ocean**, **Ember**, **Iris**), System/Light/Dark appearance, and Liquid Glass tint intensity.
- **Inline Question Replies & Approval Jump** — answer pending agent questions (single-choice, multi-select, or custom replies) directly inside T3Bar via `t3_pending_request`, and jump straight to T3 Code with a 1-click **Approve in T3 Code** button when a permission gate is waiting.
- **1-Click Jump & Stop** — click any row to jump directly to that thread in T3 Code (`t3-thread://`), or stop running agents directly from the popover *(requires control scope)*.
- **Native macOS Notifications** — optional alerts when an agent finishes, fails, or needs your input.

## Requirements

- **macOS 14.0+** (Apple Liquid Glass effect on **macOS 26+**)
- **Swift 6 / Xcode Command Line Tools** (`xcode-select --install`)
- **T3 Code** with MCP enabled

## Build & Install

```bash
git clone https://github.com/rOjulius/T3Bar.git
cd T3Bar
bash scripts/build-app.sh
open "/Applications/T3Bar.app"
```

## Connecting to T3 Code

1. Open **T3 Code** → **Settings → Sharing & access → `Use in another app (MCP)`** (or **Settings → Environments**) and copy your `/mcp` URL.
2. Click **T3Bar** in your menu bar → **Settings → Connection** → paste the `/mcp` URL → click **Sign in with T3 Code**.
3. Approve access in your browser and return to T3Bar.

> **Note on Permission Approvals:** T3 Code intentionally restricts permission/file-change approvals over MCP for security. T3Bar surfaces waiting agents immediately and jumps straight to the exact thread in T3 Code on click.

## License

MIT — see [LICENSE](LICENSE).
