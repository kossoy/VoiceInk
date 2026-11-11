# Live-call capture for Teams speaker attribution

Run on the Mac during a Teams desktop call with 2+ people (not the browser client). The
terminal running it needs Accessibility (System Settings > Privacy & Security > Accessibility).

```bash
cd ~/Developer/personal/VoiceInk-worktrees/teams-ax && swift build --product meeting-probe
P=$(swift build --product meeting-probe --show-bin-path)/meeting-probe
D=~/work/qa-evidence/teams-ax-$(date +%Y%m%d-%H%M); mkdir -p "$D"
"$P" --dump-tree "$D/tree-start.json"
"$P" --watch 300 > "$D/watch.jsonl"               # 5 min, 4 Hz JSONL
"$P" --dump-tree "$D/tree-end.json"
```

`--wake` is not needed: Teams 2 rejects both wake attributes (-25205 attributeUnsupported,
-25208 notImplemented) and exposes its web tree anyway. Files contain real names; add
`--redact` before sharing them.

## Findings, call of 2026-11-11 (Teams 26289.204, 3+ participants, 600 s watch)

- "<Name> is speaking" exists only in the **Meeting compact view** window, which Teams shows
  while the main call window is not in front. Compact view was up 15.5 s; a name was shown
  95% of that time (14.8 s), giving 6 cues for 3 people (13.4 s, 2.2% of the call).
- The main call window never carries a speaking label. Tiles are AXMenuItem labels
  "Last, First, [video is on,] Has control of production tools, [muted,] Context menu is
  available"; the own tile starts with "Myself video". One AXEmptyGroup with DOM class
  `vdi-frame-occlusion` sits in the gallery without a tile ancestor, so its owner is unknown.
- Event counts were low because events fire only on change, and the signal appeared only in
  the two compact-view stretches.

Practical consequence: with the observer on, names come while another app is in front of
Teams (compact view up). Next capture to extend coverage: keep the main call window in front
while people talk; `--watch` now reports `tileFrame` (owner of the frame, via the new `tile`
and `depth` fields) and `unmuted` changes, which tells whether the frame follows the speaker.
