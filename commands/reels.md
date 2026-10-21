---
description: Toggle reels while Claude thinks (kill|pause|off|login, youtube|instagram|tiktok)
argument-hint: kill|pause|off|login [youtube|instagram|tiktok]
---
reels-args: $ARGUMENTS

Reply with only the text after "Reel Break status: " from the hook context, verbatim, and nothing else. If there is no such line, say in one line that the reel-break hook didn't run (it needs Windows with PowerShell and Edge).
