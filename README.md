# anakinls.github.io

| Path | What it is |
| --- | --- |
| `index.html` | Site for **Roblox Event Watcher** |
| `watcher/RobloxEventWatcher.swift` | The watcher itself (single-file Swift script) |

The **Grumble Rumble** site used to live in this repository. It now has its own:
[anakinls/grumble-rumble](https://github.com/anakinls/grumble-rumble), published at
<https://anakinls.github.io/grumble-rumble/> — the same URL as before.

## Running the watcher

```sh
export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
swift watcher/RobloxEventWatcher.swift
```

Requires macOS 13+ and Screen Recording permission for your terminal.
The Discord webhook is read from the environment and must never be committed.
