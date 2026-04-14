# fedora-setup

Bootstrap repo for a fresh Fedora Atomic host.

This repo owns host bootstrap only:

- `rpm-ostree` packages
- Flatpak apps and overrides
- Podman socket setup
- NetBird install
- `chezmoi` bootstrap
- `devpod` install
- host-global CLIs that should exist directly on the machine

Persistent user config does not live here. It lives in a separate private `chezmoi` repo named `fedora-dotfiles`.

## Repo split

- `fedora-setup`: host bootstrap
- `fedora-dotfiles`: persistent user config in `$HOME`
- project repos: project toolchains, `.devcontainer/`, `AGENTS.md`, `CLAUDE.md`, and any project-specific config

The rule is simple:

- change `setup.sh` when you want to change the host itself
- change `fedora-dotfiles` when you want to change your user environment
- change a project repo when you want to change a project toolchain

## What `setup.sh` does

`setup.sh` is intended to be safe to rerun. It runs ten numbered steps:

1. **Base OS + host packages (`rpm-ostree`)** — upgrades the deployment and layers everything in `LAYERED_PACKAGES`.
2. **Flatpak apps** — installs everything in `FLATPAK_APPS` from Flathub and applies the VS Code sandbox overrides.
3. **Podman socket** — enables the rootless Podman socket and writes `~/.config/containers/containers.conf` with `pids_limit = 0` so heavy workloads (npm, node-gyp, toolbox dnf) don't hit `pthread_create: EAGAIN`.
4. **Host CLIs + Chezmoi** — installs `starship` into `~/.local/bin`, bootstraps `chezmoi`, pulls `fedora-dotfiles` over SSH, and applies it with `chezmoi --force` so the git source of truth wins during bootstrap. If no SSH key can reach GitHub, `setup.sh` runs `ssh-keygen -K` to restore resident FIDO keys from the YubiKey, and if several keys are present it shows an interactive picker so you can choose which one to use for the clone.
5. **Zsh plugins** — installs and updates the plugin checkouts under `~/.local/share/zsh/plugins` listed in `ZSH_PLUGINS`.
6. **DevPod CLI** — installs `devpod` into `~/.local/bin` and selects the `docker` provider.
7. **YubiKey GPG public key** (best-effort) — detects the card and fetches the owner's public key from the URL on the card. Retries with `gpgconf --kill scdaemon` up to five times to recover from stuck scdaemon after prior FIDO/SSH-SK use. This step is wrapped so any failure (no YubiKey, pinentry timeout, unreachable keyserver) is logged and skipped — the rest of the script still runs.
8. **Default shell → zsh**
9. **AI toolbox** — runs the `bootstrap-ai-toolbox.sh` helper from the `fedora-dotfiles` repo root. When `.chezmoiroot = home`, `chezmoi source-path` resolves to `home/`, so the helper is taken from its parent repo directory. If an existing `ai` toolbox was created before `containers.conf` got `pids_limit = 0`, it is recreated so the new limit applies. The bootstrap is retried up to three times with `toolbox rm -f ai` in between to recover from conmon exit-file timeouts, and a final failure is reported without aborting the script.
10. **Done** — prints a next-steps checklist, including a reboot reminder when packages were layered.

If the currently booted `rpm-ostree` is older than the build that fixes the known Fedora subkeys bug, `setup.sh` defers NetBird until after reboot and asks you to run the script again.

### Arrays are the source of truth

Three top-level arrays drive what ends up on the host, and the script treats each of them as declarative state. Anything present on the host but missing from the array is removed on the next run.

- `LAYERED_PACKAGES` — every layered `rpm-ostree` package. The script diffs this against the deployment's `requested-packages` and runs `rpm-ostree uninstall` for extras. `netbird` is preserved when its install is deferred this run so an older `rpm-ostree` never accidentally drops it.
- `FLATPAK_APPS` — every Flathub-origin Flatpak. The script diffs it against installed apps whose origin is `flathub` and uninstalls extras. Apps from other remotes (Fedora, vendor flatpak repos) are left alone.
- `ZSH_PLUGINS` — every managed zsh plugin checkout under `~/.local/share/zsh/plugins`. Any git checkout in that directory whose name is not in the array is removed.

Add or remove an entry in the array and rerun `setup.sh` — the host will match.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | bash
```

Or with explicit repo/user values:

```bash
curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | \
  GITHUB_USER=your-github-user DOTFILES_REPO=fedora-dotfiles bash
```

If the private dotfiles repo requires an explicit SSH key selection for bootstrap, pass it only for this run:

```bash
curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | \
  GITHUB_SSH_KEY="$HOME/.ssh/id_ed25519_sk_rk_git-personal" bash
```

If you need to clone this repo with an explicit SSH key and persist that choice locally:

```bash
GIT_SSH_COMMAND='ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_sk_rk_git-personal' \
git clone git@github.com:danylomikula/fedora-setup.git && \
git -C fedora-setup config core.sshCommand 'ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_sk_rk_git-personal'
```

Local run with full trace and a saved log:

```bash
bash -x ./setup.sh 2>&1 | tee /tmp/fedora-setup.log
```

## Private dotfiles repo

`setup.sh` expects the dotfiles repo over SSH:

```text
git@github.com:<github-user>/fedora-dotfiles.git
```

If the repo is private and not reachable yet, `setup.sh` will try a best-effort:

```bash
cd ~/.ssh && ssh-keygen -K
```

That is intended for resident SSH keys stored on a YubiKey.

## Day-to-day

- edit `LAYERED_PACKAGES`, `FLATPAK_APPS`, or `ZSH_PLUGINS` in `setup.sh` and rerun it to add or remove anything host-global
- run `setup.sh` again when you change any other host bootstrap logic or want to pull plugin updates
- run `chezmoi update` when you change `fedora-dotfiles`
- update project-specific tooling in the project repo, not here
