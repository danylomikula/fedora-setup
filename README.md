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

`setup.sh` is intended to be safe to rerun.

It currently:

- upgrades the base `rpm-ostree` deployment
- installs host packages with `rpm-ostree`
- installs GUI apps with Flatpak
- enables the rootless Podman socket
- installs `starship` and `devpod` in `~/.local/bin`
- bootstraps `chezmoi`
- pulls `fedora-dotfiles` over SSH
- applies your dotfiles with `chezmoi --force` so the git source of truth wins during bootstrap
- runs the optional AI toolbox bootstrap script explicitly from the `fedora-dotfiles` source directory resolved by `chezmoi source-path`

If the currently booted `rpm-ostree` is older than the build that fixes the known Fedora subkeys bug, `setup.sh` defers NetBird until after reboot and asks you to run the script again.

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

- run `setup.sh` again when you change host packages or other host bootstrap logic
- run `chezmoi update` when you change `fedora-dotfiles`
- update project-specific tooling in the project repo, not here
