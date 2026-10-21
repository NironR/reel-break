# Reel Break

You send Claude a prompt, open reels "for a sec", and twenty minutes later you remember Claude finished ages ago.

Reel Break leans into it: reels open when you send a prompt and get killed (or paused) the moment Claude is done or needs your permission.

## Install (Claude Code, Windows)

In a terminal:

```
claude plugin marketplace add NironR/reel-break
claude plugin install reel-break@reel-break
```

Then start a new Claude Code session (terminal or the desktop app's Code tab).

## Use

| Command | Effect |
|---|---|
| `/reels kill` | Reels open on every prompt and **close** when Claude finishes |
| `/reels pause` | Reels open once and **pause** when Claude finishes, resuming on your next prompt |
| `/reels off` | Off (default) |
| `/reels youtube` / `instagram` / `tiktok` | Pick the feed (combine: `/reels pause tiktok`) |

After `/reels`, Claude replies with a one-line status (a tiny turn, a few hundred tokens). Reels don't open for that turn.

Reels run in a separate Edge window with its own profile, so your normal browser is never touched. To log in to Instagram/TikTok: `/reels pause instagram`, send any prompt, log in in the window that opens (pause mode keeps it open), then `/reels kill`. The login is remembered.

## Good to know

- Windows + Microsoft Edge only (Edge is preinstalled).
- Pause mode opens a DevTools port on `127.0.0.1` for the reels window, so other programs on your PC (including a Claude session with shell access) could read that window's cookies and take over the accounts logged in there. Websites can't reach it and your normal browser is never touched. Kill mode doesn't open the port. If that matters to you, stick to kill mode, or use pause mode only with feeds you're not logged in to.
- Settings and the reels browser profile live in `~\.claude\reel-break`. Delete that folder to reset or log out.
