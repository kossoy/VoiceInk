# baldr: upstream conflict auto-resolver

Installed copies of what runs on baldr (Ubuntu builder, user `god`, linger on). The repo copy
is the reference; install with:

```bash
scp .oklabs/baldr/voiceink-oklabs-autoresolve .oklabs/baldr/gh-app-token .oklabs/baldr/gh-app-askpass baldr:.local/bin/
scp .oklabs/baldr/voiceink-oklabs-autoresolve.{service,timer} baldr:.config/systemd/user/
ssh baldr 'systemctl --user daemon-reload && systemctl --user enable --now voiceink-oklabs-autoresolve.timer'
```

Needs on baldr: `~/.local/bin/oklabs-agent` (Claude Code headless through CLIProxyAPI on
maestro, key from Infisical `services:/forgejo/CLIPROXY_FORGEJO_CI_KEY`, shared with the
voxtype pipeline), `~/.local/bin/secret` (Infisical), and the GitHub App key
`~/.config/voiceink-autoresolve/app.pem` (0600; restore from Infisical
`services:/voiceink-autoresolve/GITHUB_APP_PRIVATE_KEY_B64` with `base64 -d`). `gh-app-token`
mints the installation token, `gh-app-askpass` hands it to git. Fetches are anonymous HTTPS
(public repo). Behaviour: `.oklabs/README.md`, Sync, «Auto-resolve».
