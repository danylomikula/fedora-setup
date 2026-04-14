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
GITHUB_SSH_KEY="${GITHUB_SSH_KEY:-}"
DEFAULT_GITHUB_SSH_KEY="$HOME/.ssh/id_ed25519_sk_rk_git-personal"

echo "=== Fedora Cosmic Atomic Bootstrap ==="

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

run_chezmoi() {
  if [[ -r /dev/tty ]]; then
    GIT_SSH_COMMAND="$GIT_SSH_COMMAND_BASE" chezmoi --force "$@" </dev/tty
  else
    GIT_SSH_COMMAND="$GIT_SSH_COMMAND_BASE" chezmoi --force "$@"
  fi
}

sync_zsh_plugin() {
  local name url dir

  name="$1"
  url="$2"
  dir="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins/$name"

  mkdir -p "$(dirname "$dir")"

  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" remote set-url origin "$url"
    if git -C "$dir" pull --ff-only --quiet; then
      echo "  Updated $name"
    else
      echo "  Failed to update $name; leaving the existing checkout in place." >&2
    fi
    return 0
  fi

  if [[ -e "$dir" ]]; then
    echo "  Skipping $name because $dir exists and is not a git checkout." >&2
    return 0
  fi

  git clone --depth 1 "$url" "$dir" >/dev/null
  echo "  Installed $name"
}

discover_ssh_private_keys() {
  local key name
  shopt -s nullglob
  for key in "$HOME/.ssh"/*; do
    [[ -f "$key" ]] || continue
    name="$(basename "$key")"
    case "$name" in
      *.pub|known_hosts|known_hosts.old|config|authorized_keys|authorized_keys2|environment) continue ;;
    esac
    if head -n1 "$key" 2>/dev/null | grep -qE '^-----BEGIN '; then
      printf '%s\n' "$key"
    fi
  done
  shopt -u nullglob
}

select_github_ssh_key() {
  local -a keys=()
  local key default_idx=0 i prompt choice

  while IFS= read -r key; do
    keys+=("$key")
  done < <(discover_ssh_private_keys)

  (( ${#keys[@]} == 0 )) && return 1

  if (( ${#keys[@]} == 1 )); then
    printf '%s\n' "${keys[0]}"
    return 0
  fi

  if [[ ! -r /dev/tty ]]; then
    for key in "${keys[@]}"; do
      [[ "$key" == "$DEFAULT_GITHUB_SSH_KEY" ]] && { printf '%s\n' "$key"; return 0; }
    done
    return 1
  fi

  {
    echo "Multiple SSH keys found in ~/.ssh — select one for GitHub:"
    i=1
    for key in "${keys[@]}"; do
      if [[ "$key" == "$DEFAULT_GITHUB_SSH_KEY" ]]; then
        printf '  %d) %s (default)\n' "$i" "$(basename "$key")"
        default_idx="$i"
      else
        printf '  %d) %s\n' "$i" "$(basename "$key")"
      fi
      ((i++))
    done
  } >&2

  (( default_idx == 0 )) && default_idx=1
  prompt="Enter number [$default_idx]: "
  read -r -p "$prompt" choice </dev/tty
  choice="${choice:-$default_idx}"
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
    printf '%s\n' "${keys[choice-1]}"
    return 0
  fi
  return 1
}

sync_zsh_plugins() {
  sync_zsh_plugin zsh-autosuggestions https://github.com/zsh-users/zsh-autosuggestions.git
  sync_zsh_plugin zsh-history-substring-search https://github.com/zsh-users/zsh-history-substring-search.git
  sync_zsh_plugin zsh-completions https://github.com/zsh-users/zsh-completions.git
  sync_zsh_plugin fast-syntax-highlighting https://github.com/zdharma-continuum/fast-syntax-highlighting.git
  sync_zsh_plugin zsh-autocomplete https://github.com/marlonrichert/zsh-autocomplete.git
  sync_zsh_plugin zsh-you-should-use https://github.com/MichaelAquilina/zsh-you-should-use.git
}

run_ai_toolbox_bootstrap() {
  local source_dir repo_dir script nested_script

  source_dir="${CHEZMOI_SOURCE_DIR:-}"
  if [[ -z "$source_dir" ]] && command -v chezmoi &>/dev/null; then
    source_dir="$(chezmoi source-path 2>/dev/null || true)"
  fi
  source_dir="${source_dir:-$HOME/.local/share/chezmoi}"
  repo_dir="$source_dir"
  script="$repo_dir/bootstrap-ai-toolbox.sh"

  # With `.chezmoiroot = home`, `chezmoi source-path` resolves to the source
  # root (`.../home`), while helper scripts such as bootstrap-ai-toolbox.sh
  # remain at the repo root one level above it.
  if [[ ! -f "$script" && -f "$repo_dir/.chezmoi.toml.tmpl" ]]; then
    if [[ -f "$(dirname "$repo_dir")/.chezmoiroot" && -f "$(dirname "$repo_dir")/bootstrap-ai-toolbox.sh" ]]; then
      repo_dir="$(dirname "$repo_dir")"
      script="$repo_dir/bootstrap-ai-toolbox.sh"
    fi
  fi

  if ! command -v toolbox &>/dev/null; then
    echo "  toolbox command not found. Skipping AI toolbox bootstrap."
    return 0
  fi

  if [[ ! -f "$script" ]]; then
    nested_script="$(find "$repo_dir" -mindepth 2 -maxdepth 5 -name bootstrap-ai-toolbox.sh -print -quit 2>/dev/null || true)"
    if [[ -n "$nested_script" ]]; then
      echo "  Expected AI toolbox bootstrap script at $script, but found a nested copy at $nested_script." >&2
      echo "  Your local chezmoi source tree looks corrupted from an older recursive layout." >&2
      echo "  Fix it with: rm -rf ~/.local/share/chezmoi && re-run setup.sh" >&2
    else
      echo "  AI toolbox bootstrap script not found at $script." >&2
      echo "  Ensure the latest fedora-dotfiles repo has been pushed and then re-run setup.sh." >&2
    fi
    return 1
  fi

  bash "$script"
}

DOTFILES_SSH_URL="git@github.com:${GITHUB_USER}/${DOTFILES_REPO}.git"
GIT_SSH_COMMAND_BASE='ssh -o StrictHostKeyChecking=accept-new'

if [[ -z "$GITHUB_SSH_KEY" && -f "$DEFAULT_GITHUB_SSH_KEY" ]]; then
  GITHUB_SSH_KEY="$DEFAULT_GITHUB_SSH_KEY"
fi

if [[ -n "$GITHUB_SSH_KEY" ]]; then
  GIT_SSH_COMMAND_BASE="$GIT_SSH_COMMAND_BASE -o IdentityAgent=none -o IdentitiesOnly=yes -i $GITHUB_SSH_KEY"
fi

# -----------------------------------------------------------------------------
# 1. Base OS + host packages (rpm-ostree)
# -----------------------------------------------------------------------------
echo "--- [1/10] Base OS + host packages (rpm-ostree) ---"

NETBIRD_REPO_FILE="/etc/yum.repos.d/netbird.repo"
RPM_OSTREE_VERSION="$(rpm-ostree --version | awk -F"'" '/Version:/ {print $2}')"
NETBIRD_MIN_FIXED_RPM_OSTREE_VERSION="2025.12"
NEEDS_REBOOT=false
NETBIRD_DEFERRED=false
CHEZMOI_DEFERRED=false

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
  openssh-askpass        # GUI prompts/notifications for SSH FIDO key use
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
  sudo rpm-ostree install --idempotent --allow-inactive "${NEEDED[@]}"
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
echo "--- [2/10] Flatpak apps ---"

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

flatpak_failures=()
for app in "${FLATPAK_APPS[@]}"; do
  if ! flatpak install -y --noninteractive flathub "$app"; then
    flatpak_failures+=("$app")
    echo "  Failed to install $app" >&2
  fi
done
if [[ ${#flatpak_failures[@]} -gt 0 ]]; then
  echo "  ${#flatpak_failures[@]} Flatpak app(s) failed to install: ${flatpak_failures[*]}" >&2
fi

# VS Code Flatpak needs access to the home directory and rootless Podman socket
flatpak override --user com.visualstudio.code \
  --filesystem=home \
  --filesystem=xdg-run/podman \
  --filesystem=/tmp \
  --env=DOCKER_HOST="unix:///run/user/$(id -u)/podman/podman.sock"

# -----------------------------------------------------------------------------
# 3. Podman socket (Docker-compatible API for VS Code + DevPod)
# -----------------------------------------------------------------------------
echo "--- [3/10] Podman socket ---"

systemctl --user enable --now podman.socket
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"

# -----------------------------------------------------------------------------
# 4. Host CLIs + Chezmoi
# -----------------------------------------------------------------------------
echo "--- [4/10] Host CLIs + Chezmoi ---"

mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"

if ! command -v chezmoi &>/dev/null; then
  CHEZMOI_DEFERRED=true
  echo "  chezmoi is not available in the current deployment yet. Reboot and re-run setup.sh to apply fedora-dotfiles."
else
  if [[ ! -d "$HOME/.local/share/chezmoi" ]]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if ! GIT_SSH_COMMAND="$GIT_SSH_COMMAND_BASE" git ls-remote "$DOTFILES_SSH_URL" &>/dev/null; then
      if command -v ssh-keygen &>/dev/null && [[ -r /dev/tty ]]; then
        echo "  Restoring resident SSH keys from YubiKey into ~/.ssh"
        (
          cd "$HOME/.ssh"
          ssh-keygen -K </dev/tty
        ) || true

        if [[ -z "$GITHUB_SSH_KEY" ]]; then
          GITHUB_SSH_KEY="$(select_github_ssh_key || true)"
        fi

        if [[ -n "$GITHUB_SSH_KEY" ]]; then
          echo "  Using SSH key: $GITHUB_SSH_KEY"
          GIT_SSH_COMMAND_BASE="ssh -o StrictHostKeyChecking=accept-new -o IdentityAgent=none -o IdentitiesOnly=yes -i $GITHUB_SSH_KEY"
        fi
      fi
    fi

    if ! GIT_SSH_COMMAND="$GIT_SSH_COMMAND_BASE" git ls-remote "$DOTFILES_SSH_URL" &>/dev/null; then
      echo "Unable to access $DOTFILES_SSH_URL over SSH." >&2
      echo "Ensure your GitHub SSH key is already added to GitHub and available on this machine." >&2
      echo "If you use a resident FIDO/YubiKey SSH key, insert the key and run: cd ~/.ssh && ssh-keygen -K" >&2
      echo "If your GitHub key needs to be selected explicitly, re-run with GITHUB_SSH_KEY=/path/to/private-key bash" >&2
      exit 1
    fi
  fi

  if [[ -d "$HOME/.local/share/chezmoi" ]]; then
    run_chezmoi update
  else
    run_chezmoi init --apply --guess-repo-url=false "$DOTFILES_SSH_URL"
  fi
fi

# -----------------------------------------------------------------------------
# 5. Zsh plugins
# -----------------------------------------------------------------------------
echo "--- [5/10] Zsh plugins ---"

sync_zsh_plugins

# -----------------------------------------------------------------------------
# 6. DevPod CLI
# -----------------------------------------------------------------------------
echo "--- [6/10] DevPod ---"

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
# 7. YubiKey GPG public key (best-effort)
# -----------------------------------------------------------------------------
echo "--- [7/10] YubiKey GPG public key ---"

if command -v gpg &>/dev/null; then
  # scdaemon/pcscd can race after prior FIDO use (e.g., SSH-SK clone) or hold
  # a stale USB lock, making the first gpg call return "No such device".
  # Retry up to 5 times, killing scdaemon between attempts so gpg-agent
  # respawns it fresh, and giving pcscd a moment to see the reader again.
  # `timeout` also prevents indefinite hangs if pinentry tries to open a GUI.
  card_output=""
  card_rc=1
  for attempt in 1 2 3 4 5; do
    gpgconf --kill scdaemon &>/dev/null || true
    sleep 1
    card_output="$(LC_ALL=C timeout 10 gpg --card-status 2>&1)"
    card_rc=$?
    (( card_rc == 0 )) && break
  done

  if (( card_rc == 0 )); then
    card_status="$card_output"
    public_key_url="$(printf '%s\n' "$card_status" | sed -n 's/^URL of public key[[:space:]]*:[[:space:]]*//p' | head -n1)"
    if [[ -n "$public_key_url" ]]; then
      if timeout 30 gpg --fetch-keys "$public_key_url" &>/dev/null; then
        echo "  Public key fetched from card URL: $public_key_url"
      else
        echo "  YubiKey detected and public key URL found, but fetch did not succeed: $public_key_url"
      fi
    else
      echo "  YubiKey detected, but no public key URL is set on the card."
    fi
  elif (( card_rc == 124 )); then
    echo "  gpg --card-status timed out. Skipping." >&2
    echo "  Retry manually: gpgconf --kill scdaemon && gpg --card-status" >&2
  else
    echo "  No YubiKey detected. Skipping." >&2
    printf '%s\n' "$card_output" | sed 's/^/    /' >&2
  fi
else
  echo "  GPG smartcard tools are not available yet. Skipping."
fi

# -----------------------------------------------------------------------------
# 8. Default shell → zsh
# -----------------------------------------------------------------------------
echo "--- [8/10] Default shell ---"

if command -v zsh &>/dev/null && [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
  sudo usermod -s "$(command -v zsh)" "$USER"
fi

# -----------------------------------------------------------------------------
# 9. AI toolbox
# -----------------------------------------------------------------------------
echo "--- [9/10] AI toolbox ---"

if [[ "$CHEZMOI_DEFERRED" == false ]]; then
  run_ai_toolbox_bootstrap
else
  echo "  Chezmoi was deferred. Re-run setup.sh after reboot before bootstrapping AI tools."
fi

# -----------------------------------------------------------------------------
# 10. Done
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
if [[ "$CHEZMOI_DEFERRED" == true ]]; then
  echo "  3. Re-run setup.sh after reboot to apply fedora-dotfiles"
elif [[ "$NETBIRD_DEFERRED" == true ]]; then
  echo "  3. Re-run setup.sh after reboot to install NetBird"
else
  echo "  3. sudo systemctl enable --now netbird"
fi
echo "  4. netbird up --management-url https://your-netbird-management-url"
echo "  5. If GPG key fetch was skipped above, plug in your YubiKey and run: gpg --card-status"
echo "  6. If the public key was not fetched above, try manually: gpg --card-edit  # then run: fetch"
echo "  7. Or fetch directly from the card URL shown by gpg --card-status: gpg --fetch-keys <url>"
echo "  8. If that still fails, import it manually: gpg --import /path/to/public-key.asc"
echo "  9. flatpak run --command=bw com.bitwarden.desktop login   # one-time Bitwarden CLI login"
echo " 10. bwu                                                # unlocks Bitwarden for this shell"
echo " 11. chezmoi apply          # applies configs with secrets"
echo " 12. cd /path/to/project && devpod up ."
