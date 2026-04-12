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

- installs host packages with `rpm-ostree`
- installs GUI apps with Flatpak
- enables the rootless Podman socket
- installs `starship` and `devpod` in `~/.local/bin`
- bootstraps `chezmoi`
- pulls `fedora-dotfiles` over SSH
- applies your dotfiles
- syncs the optional AI toolbox through the post-apply `chezmoi` hook

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | bash
```

Or with explicit repo/user values:

```bash
curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | \
  GITHUB_USER=your-github-user DOTFILES_REPO=fedora-dotfiles bash
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
