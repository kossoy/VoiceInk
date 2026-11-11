# Live-call capture for Teams speaker attribution

Run on the Mac during a Teams desktop call with 2+ people (not the browser client). The
terminal running it needs Accessibility (System Settings > Privacy & Security > Accessibility).

```bash
cd ~/Developer/personal/VoiceInk-worktrees/teams-ax && swift build --product meeting-probe
P=$(swift build --product meeting-probe --show-bin-path)/meeting-probe
D=~/work/qa-evidence/teams-ax-$(date +%Y%m%d-%H%M); mkdir -p "$D"
"$P" --wake --dump-tree "$D/tree-start.json"     # the only write: AX flags on Teams processes
"$P" --watch 300 > "$D/watch.jsonl"               # 5 min, 4 Hz JSONL
"$P" --dump-tree "$D/tree-end.json"
```

During `--watch`: let each person speak in turn, open the People pane once, share the screen
for ~30 s (compact view), stop sharing. Files stay local and contain real names; add `--redact`
before sharing them. Selectors to confirm or fix: `TeamsAXSelectors` in
`VoiceInk/OKLabs/MeetingSystem/TeamsSpeakerObserver.swift`; recorded labels become fixtures in
`Tests/MeetingSystemTests/TeamsSpeakerObserverTests.swift`.
