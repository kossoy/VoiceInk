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
  while the main call window is not in front; in silence it reads "Nobody is speaking"
  (the probe's third "name" was this). Compact view was up 15.5 s: a participant named 11.5 s
  (74%), "Nobody" 3.3 s, empty 0.7 s. That gives 3 cues for 2 people, 10.6 s, 1.8% of the call.
- The main call window never carries a speaking label. Tiles are AXMenuItem labels
  "Last, First, [video is on,] Has control of production tools, [muted,] Context menu is
  available"; the own tile starts with "Myself video". One AXEmptyGroup with DOM class
  `vdi-frame-occlusion` sits in the gallery without a tile ancestor, so its owner is unknown.
- Event counts were low because events fire only on change, and the signal appeared only in
  the two compact-view stretches.

## Findings, call of 2026-11-11 16:01 (main call window in front, 3 participants incl. the user)

- The speaking border is an AXEmptyGroup with `vdi-frame-occlusion`, one level below the
  speaker's AXMenuItem tile (depth 22 under 21). `speaking` equalled the `tileFrame` owners in
  73 of 73 changes; compact view never appeared, so every name came from the main window.
- 600.2 s watch: a participant framed 570.8 s (95.1%), two at once 40.1 s (6.7%), nobody
  29.4 s (4.9%). Border stretches: median 2.5 s / 8.9 s for the two speakers, shortest 0.8 s;
  changes land within one 0.25 s poll. 23 cues, cue union 582.9 s (97.1%).
- The user's own tile ("Myself video, ..., Unmuted, video is on, Fit to frame, ...") never
  got the border; the probe would report it as `(self)`, the observer excludes it.

Coverage by capture: compact-view only 1.8% of the call; main window in front 97.1%.
The observer uses both signals; the main-window border is the primary one.
