# CC-HP

> Claude Code Hit Points — know your quota before it's gone.

A tiny macOS menu bar app that shows your Claude Code usage at a glance. Terminal-native dark UI, real-time countdown timers, one-click status line setup.

---

**CC-HP** 是一个 macOS 菜单栏小工具，让你随时查看 Claude Code 的配额用量。终端风格暗色界面，实时倒计时，一键开启 status line。

## Features

- **Account info** — plan, org, tier, subscription status via Anthropic OAuth API
- **Current Session** — 5-hour window usage % with live countdown to reset
- **Current Week** — 7-day window usage % with reset date
- **Status Line toggle** — enable/disable CC's terminal status line from the app
- **Auto-sync** — watches for usage file updates from active CC sessions
- **Zero setup** — reads your existing Claude Code credentials from Keychain

## Install

Download the latest `.dmg` from [Releases](../../releases), drag `CC-HP.app` to Applications.

Or build from source:

```bash
git clone https://github.com/KasparChen/CC-HP.git
cd CC-HP
chmod +x build.sh && ./build.sh
open CC-HP.app
```

## Requirements

- macOS 13+
- Claude Code installed and logged in (`claude auth login`)
- `jq` installed (`brew install jq`) — needed for the status line hook

## How it works

1. Reads your Claude Code OAuth token from macOS Keychain
2. Fetches account/org profile from `api.anthropic.com/api/oauth/profile`
3. Installs a `statusLine` hook that captures rate limit data from active CC sessions to `~/.claude/cc-check-usage.json`
4. Watches that file for real-time updates

## License

MIT
