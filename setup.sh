#!/bin/bash
set -euo pipefail

# =============================================================================
# Fedora Cosmic Atomic — Fresh Laptop Bootstrap
#
# This script installs the host OS packages and integrations.
# Dotfiles are applied by chezmoi from a separate private repo.
# Project-specific tooling belongs in each project's own repo and devcontainer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | GITHUB_USER=your-github-user bash
#   curl -fsSL https://raw.githubusercontent.com/danylomikula/fedora-setup/main/setup.sh | GITHUB_USER=your-github-user DOTFILES_REPO=fedora-dotfiles bash
# =============================================================================

GITHUB_USER="${GITHUB_USER:-danylomikula}"
DOTFILES_REPO="${DOTFILES_REPO:-fedora-dotfiles}"

echo "=== Fedora Cosmic Atomic Bootstrap ==="

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

if [[ -z "$GITHUB_USER" ]]; then
  if [[ -r /dev/tty ]]; then
    read -r -p "GitHub username for git@github.com:<user>/${DOTFILES_REPO}.git: " GITHUB_USER </dev/tty
  fi
  [[ -n "$GITHUB_USER" ]] || { echo "GITHUB_USER is required. Re-run the script and enter it when prompted, or pass GITHUB_USER=your-github-user to bash." >&2; exit 1; }
fi

DOTFILES_SSH_URL="git@github.com:${GITHUB_USER}/${DOTFILES_REPO}.git"

# -----------------------------------------------------------------------------
# 1. Base OS + host packages (rpm-ostree)
# -----------------------------------------------------------------------------
echo "--- [1/8] Base OS + host packages (rpm-ostree) ---"

NETBIRD_REPO_FILE="/etc/yum.repos.d/netbird.repo"
RPM_OSTREE_VERSION="$(rpm-ostree --version | awk -F"'" '/Version:/ {print $2}')"
NETBIRD_MIN_FIXED_RPM_OSTREE_VERSION="2025.12"
NEEDS_REBOOT=false
NETBIRD_DEFERRED=false

echo "  Current rpm-ostree version: ${RPM_OSTREE_VERSION}"

upgrade_rc=0
if sudo rpm-ostree upgrade --unchanged-exit-77; then
  NEEDS_REBOOT=true
else
  upgrade_rc=$?
  if [[ "$upgrade_rc" -eq 77 ]]; then
    echo "  Base system already up to date."
  else
    exit "$upgrade_rc"
  fi
fi

if ! version_ge "$RPM_OSTREE_VERSION" "$NETBIRD_MIN_FIXED_RPM_OSTREE_VERSION"; then
  NETBIRD_DEFERRED=true
  echo "  Deferring NetBird install until after reboot because rpm-ostree ${RPM_OSTREE_VERSION} is older than ${NETBIRD_MIN_FIXED_RPM_OSTREE_VERSION}."
fi

LAYERED_PACKAGES=(
  git                    # required for private dotfiles repo access over SSH
  zsh                    # login shell
  tmux                   # terminal multiplexer
  alacritty              # terminal emulator
  cascadia-mono-nf-fonts # package-managed Nerd Font used by Alacritty
  wl-clipboard           # Wayland clipboard for tmux / neovim yank
  gh                     # GitHub CLI
  fzf                    # fuzzy finder
  jq                     # JSON processor
  yq                     # YAML/JSON/TOML processor
  zoxide                 # smarter cd
  bat                    # cat replacement
  eza                    # ls replacement
  podman-docker          # /usr/bin/docker symlink → podman
  gnupg2-scdaemon        # YubiKey GPG smartcard for signed commits
  opensc                 # PKCS#11 for YubiKey SSH
  yubikey-manager        # ykman CLI
  chezmoi                # dotfiles manager
)

if [[ "$NETBIRD_DEFERRED" == false ]]; then
  sudo tee "$NETBIRD_REPO_FILE" >/dev/null <<'EOF'
[netbird]
name=netbird
baseurl=https://pkgs.netbird.io/yum/
enabled=1
gpgcheck=0
gpgkey=https://pkgs.netbird.io/yum/repodata/repomd.xml.key
repo_gpgcheck=1
EOF
  LAYERED_PACKAGES+=(netbird) # VPN client
else
  sudo rm -f "$NETBIRD_REPO_FILE"
fi

NEEDED=()
for pkg in "${LAYERED_PACKAGES[@]}"; do
  rpm -q "$pkg" &>/dev/null || NEEDED+=("$pkg")
done

if [[ ${#NEEDED[@]} -gt 0 ]]; then
  sudo rpm-ostree install --idempotent "${NEEDED[@]}"
  NEEDS_REBOOT=true
else
  echo "  All packages already installed."
fi

# The service is only available after reboot if netbird was newly layered.
if [[ "$NETBIRD_DEFERRED" == false ]] && systemctl cat netbird &>/dev/null; then
  sudo systemctl enable --now netbird
fi

# -----------------------------------------------------------------------------
# 2. Flatpak GUI apps
# -----------------------------------------------------------------------------
echo "--- [2/8] Flatpak apps ---"

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

FLATPAK_APPS=(
  app.zen_browser.zen             # browser
  com.visualstudio.code           # editor
  org.telegram.desktop            # messaging
  md.obsidian.Obsidian            # notes
  com.discordapp.Discord          # messaging
  org.videolan.VLC                # media player
  com.bitwarden.desktop           # password manager
  org.filezillaproject.Filezilla  # FTP client
  org.signal.Signal               # messaging
)

for app in "${FLATPAK_APPS[@]}"; do
  flatpak install -y --noninteractive flathub "$app" 2>/dev/null || true
done

# VS Code Flatpak needs access to the home directory and rootless Podman socket
flatpak override --user com.visualstudio.code \
  --filesystem=home \
  --filesystem=xdg-run/podman \
  --filesystem=/tmp \
  --env=DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"

# -----------------------------------------------------------------------------
# 3. Podman socket (Docker-compatible API for VS Code + DevPod)
# -----------------------------------------------------------------------------
echo "--- [3/8] Podman socket ---"

systemctl --user enable --now podman.socket
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"

# -----------------------------------------------------------------------------
# 4. Host CLIs + Chezmoi
# -----------------------------------------------------------------------------
echo "--- [4/8] Host CLIs + Chezmoi ---"

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

if [[ ! -d "$HOME/.local/share/chezmoi" ]]; then
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if ! GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git ls-remote "$DOTFILES_SSH_URL" &>/dev/null; then
    if command -v ssh-keygen &>/dev/null && [[ -r /dev/tty ]]; then
      echo "  Restoring resident SSH keys from YubiKey into ~/.ssh"
      (
        cd "$HOME/.ssh"
        ssh-keygen -K </dev/tty
      ) || true
    fi
  fi

  if ! GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git ls-remote "$DOTFILES_SSH_URL" &>/dev/null; then
    echo "Unable to access $DOTFILES_SSH_URL over SSH." >&2
    echo "Ensure your GitHub SSH key is already added to GitHub and available on this machine." >&2
    echo "If you use a resident FIDO/YubiKey SSH key, insert the key and run: cd ~/.ssh && ssh-keygen -K" >&2
    exit 1
  fi
fi

if [[ -d "$HOME/.local/share/chezmoi" ]]; then
  chezmoi update
else
  chezmoi init --apply --ssh "$GITHUB_USER/$DOTFILES_REPO"
fi

# -----------------------------------------------------------------------------
# 5. DevPod CLI
# -----------------------------------------------------------------------------
echo "--- [5/8] DevPod ---"

if ! command -v devpod &>/dev/null; then
  mkdir -p "$HOME/.local/bin"
  ARCH="$(uname -m)"
  [[ "$ARCH" == "x86_64" ]] && ARCH="amd64"
  [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && ARCH="arm64"
  [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || { echo "Unsupported architecture for DevPod CLI: $ARCH" >&2; exit 1; }
  curl -fsSL -o /tmp/devpod \
    "https://github.com/loft-sh/devpod/releases/latest/download/devpod-linux-${ARCH}"
  install -m 0755 /tmp/devpod "$HOME/.local/bin/devpod"
  rm -f /tmp/devpod
fi

devpod provider add docker &>/dev/null || true
devpod provider use docker &>/dev/null || { echo "Failed to select the DevPod docker provider" >&2; exit 1; }

devpod context set-options default \
  -o DOTFILES_URL="$DOTFILES_SSH_URL" \
  -o TELEMETRY=false

# -----------------------------------------------------------------------------
# 6. YubiKey GPG public key (best-effort)
# -----------------------------------------------------------------------------
echo "--- [6/8] YubiKey GPG public key ---"

if command -v gpg &>/dev/null && command -v gpg-card &>/dev/null; then
  if gpg --card-status &>/dev/null; then
    if gpg-card -- fetch &>/dev/null; then
      echo "  Public key fetched from card metadata / keyserver."
    else
      echo "  YubiKey detected, but public key fetch did not succeed."
    fi
  else
    echo "  No YubiKey detected. Skipping."
  fi
else
  echo "  GPG smartcard tools are not available yet. Skipping."
fi

# -----------------------------------------------------------------------------
# 7. Default shell → zsh
# -----------------------------------------------------------------------------
echo "--- [7/8] Default shell ---"

if command -v zsh &>/dev/null && [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
  sudo usermod -s "$(command -v zsh)" "$USER"
fi

# -----------------------------------------------------------------------------
# 8. Done
# -----------------------------------------------------------------------------
echo ""
echo "=== Bootstrap complete ==="
echo ""

if [[ "$NEEDS_REBOOT" == true ]]; then
  echo "⚠  rpm-ostree packages were installed — REBOOT REQUIRED"
  echo "   Run: systemctl reboot"
  echo ""
fi

echo "Next steps:"
echo "  1. Reboot if prompted above"
echo "  2. Open Alacritty"
if [[ "$NETBIRD_DEFERRED" == true ]]; then
  echo "  3. Re-run setup.sh after reboot to install NetBird"
  echo "  4. If GPG key fetch was skipped above, plug in your YubiKey and run: gpg --card-status"
  echo "  5. If the public key was not fetched above, try manually: gpg-card -- fetch"
  echo "  6. If that still fails, import it manually: gpg --import /path/to/public-key.asc"
  echo "  7. flatpak run --command=bw com.bitwarden.desktop login   # one-time Bitwarden CLI login"
  echo "  8. bwu                                                # unlocks Bitwarden for this shell"
  echo "  9. chezmoi apply          # applies configs with secrets"
  echo " 10. cd /path/to/project && devpod up ."
else
  echo "  3. sudo systemctl enable --now netbird"
  echo "  4. netbird up --management-url https://your-netbird-management-url"
  echo "  5. If GPG key fetch was skipped above, plug in your YubiKey and run: gpg --card-status"
  echo "  6. If the public key was not fetched above, try manually: gpg-card -- fetch"
  echo "  7. If that still fails, import it manually: gpg --import /path/to/public-key.asc"
  echo "  8. flatpak run --command=bw com.bitwarden.desktop login   # one-time Bitwarden CLI login"
  echo "  9. bwu                                                # unlocks Bitwarden for this shell"
  echo " 10. chezmoi apply          # applies configs with secrets"
  echo " 11. cd /path/to/project && devpod up ."
fi
