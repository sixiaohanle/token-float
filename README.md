# Token Float (Token 悬浮球)

English · [简体中文](README.zh-CN.md)

Token Float is a macOS utility for tracking how fast **Codex** and **Claude Code** generate output and how much token usage they record over time. Keep the combined rate in a small floating widget, in the menu bar, or in both places. Expand either view to see individual conversations, or open Usage Statistics to review your history.

[Download the latest release](https://github.com/sixiaohanle/token-float/releases/latest)

## What you can see

- **Live output rates.** See combined and per-provider rates in tokens per second (`T/s`). The expanded view shows recent conversations, their latest recorded model and output time when available, and an average rate for completed conversations.
- **Today's usage and history.** View today's total and browse daily, weekly, and cumulative activity. Filter the statistics to Codex, Claude Code, or both. Hover over a day or week to see its date range and token count, or scroll the timeline left to view earlier months.
- **Display options.** Choose a floating widget, the menu bar, or both. Turn the animated cat on or off, configure launch at login, and choose full numbers or Chinese units such as `万` (10,000) and `亿` (100 million). The number format also applies to daily, weekly, and cumulative chart details.

## Install

1. Download the Apple silicon ZIP from [GitHub Releases](https://github.com/sixiaohanle/token-float/releases/latest).
2. Unzip the download and move `Token 悬浮球.app` to **Applications**.
3. Open the app. It discovers supported local logs and backfills available history in the background.

The downloadable build requires **Apple silicon and macOS 13 or later**. Release builds use ad hoc signing, so macOS may block the first launch. You can also build the app locally using the steps below.

## Find your way around

The app interface is in Simplified Chinese. These are the labels you'll see in Settings.

| Page | What to do there |
| --- | --- |
| General (`常规`) | Set the display location, cat animation, number format, and launch at login. |
| Data Sources (`数据来源`) | Enable Codex or Claude Code, choose a custom log directory, or select **Rescan** (`重新扫描`). |
| Usage Statistics (`用量统计`) | Browse totals and charts. Use `总共` for both sources and `每日`, `每周`, or `累计` to change the chart view. |
| About (`关于`) | See the installed version, check for updates, and open the GitHub repository. |

## Data sources and accounting

| Provider | Default local sources |
| --- | --- |
| Codex | `~/.codex/sessions` and `~/.codex/archived_sessions` |
| Claude Code | `~/.claude/projects` |

Token Float can use `CODEX_HOME` and `CLAUDE_CONFIG_DIR` when those environment variables are available to the app. You can also choose directories in **Data Sources**. Reading compressed Codex archives (`.jsonl.zst`) requires `zstd` at `/opt/homebrew/bin/zstd`, `/usr/local/bin/zstd`, or `/usr/bin/zstd`.

Live rates estimate **output** tokens per second from the timing of local log entries. The display updates as the tools write new usage records. Historical totals use the recorded token counts and group dated usage by the Mac's local calendar.

- **Codex** uses per-response usage records when available and takes increments from older cumulative records. Matching copies and identifiable inherited history are deduplicated.
- **Claude Code** adds the reported input, cache-creation input, cache-read input, and output counts. Repeated updates for the same response are combined.

After an initial backfill, Token Float continues saving newly observed usage. The local ledger retains previously recorded totals if the original logs are later removed. When a Codex archive has only a cumulative counter in the local state database, that counter contributes to the overall total. It may include inherited fork usage. Daily and weekly charts use dated records, and a restored original log replaces its corresponding fallback amount.

## Local storage and updates

Usage is saved in `~/Library/Application Support/Token Float/usage.sqlite3`. The database keeps usage counts and hashed identifiers for deduplication. Conversation text stays in the source logs on your Mac.

Token Float checks public GitHub Releases at startup and every 24 hours while running. To check manually, open **Settings → About** and click **Check for Updates** (`检测更新`). The update notice links to the release page, where you can download the new version and replace the app.

## Build from source

Use Xcode Command Line Tools with Swift 5.9 or later. Run the build script from the repository root.

```sh
./work/build-token-float.sh
```

The script builds for the architecture of your Mac and creates `outputs/Token 悬浮球.app`.

## License

[MIT](LICENSE)
