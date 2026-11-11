# baldr: upstream conflict auto-resolver

Installed copies of what runs on baldr (Ubuntu builder, user `god`, linger on). The repo copy
is the reference; install with:

```bash
scp .oklabs/baldr/voiceink-oklabs-autoresolve baldr:.local/bin/
scp .oklabs/baldr/voiceink-oklabs-autoresolve.{service,timer} baldr:.config/systemd/user/
ssh baldr 'systemctl --user daemon-reload && systemctl --user enable --now voiceink-oklabs-autoresolve.timer'
```

Needs on baldr: `~/.local/bin/oklabs-agent` (Claude Code headless through CLIProxyAPI on
maestro, key from Infisical `services:/forgejo/CLIPROXY_FORGEJO_CI_KEY`, shared with the
voxtype pipeline), `~/.local/bin/secret` (Infisical), the deploy key `~/.ssh/voiceink_autoresolve`
behind the ssh alias `github-voiceink`. Behaviour: `.oklabs/README.md`, Sync, «Auto-resolve».
