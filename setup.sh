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

# antidote (zsh plugin manager) — installed via git clone at ~/.antidote.
# The plugin list itself is owned by fedora-dotfiles (~/.zsh_plugins.txt);
# this repo only guarantees antidote is present and up to date.
ANTIDOTE_REPO="https://github.com/mattmc3/antidote.git"
ANTIDOTE_DIR="$HOME/.antidote"

# TPM (tmux plugin manager) — installed via git clone at ~/.tmux/plugins/tpm.
# The plugin list lives in ~/.tmux.conf as `set -g @plugin '…'` directives
# (shipped by fedora-dotfiles). setup.sh parses that file as the source of
# truth: anything declared is cloned into ~/.tmux/plugins, anything on disk
# but not declared is removed.
TPM_REPO="https://github.com/tmux-plugins/tpm.git"
TPM_DIR="$HOME/.tmux/plugins/tpm"
TMUX_PLUGIN_DIR="$HOME/.tmux/plugins"

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

install_antidote() {
  # Ensure antidote itself is installed/updated. Plugin entries live in the
  # user's ~/.zsh_plugins.txt (shipped by fedora-dotfiles); antidote rebuilds
  # its static bundle at first shell startup after that file changes.
  if [[ -d "$ANTIDOTE_DIR/.git" ]]; then
    if git -C "$ANTIDOTE_DIR" pull --ff-only --quiet; then
      echo "  Updated antidote"
    else
      echo "  Failed to update antidote; leaving the existing checkout in place." >&2
    fi
  else
    if [[ -e "$ANTIDOTE_DIR" ]]; then
      echo "  Skipping antidote install because $ANTIDOTE_DIR exists and is not a git checkout." >&2
      return 0
    fi
    git clone --depth 1 "$ANTIDOTE_REPO" "$ANTIDOTE_DIR" >/dev/null
    echo "  Installed antidote at $ANTIDOTE_DIR"
  fi

  # Legacy cleanup: previous setup.sh versions cloned each plugin into
  # ~/.local/share/zsh/plugins. antidote stores plugins under ~/.cache/antidote
  # instead, so the old tree is dead weight — remove it once.
  local legacy="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins"
  if [[ -d "$legacy" ]]; then
    echo "  Removing legacy plugin directory: $legacy"
    rm -rf "$legacy"
  fi
}

install_tpm() {
  # Ensure TPM itself is installed or updated.
  if [[ -d "$TPM_DIR/.git" ]]; then
    if git -C "$TPM_DIR" pull --ff-only --quiet; then
      echo "  Updated TPM"
    else
      echo "  Failed to update TPM; leaving the existing checkout in place." >&2
    fi
  else
    if [[ -e "$TPM_DIR" ]]; then
      echo "  Skipping TPM install because $TPM_DIR exists and is not a git checkout." >&2
      return 0
    fi
    mkdir -p "$TMUX_PLUGIN_DIR"
    git clone --depth 1 "$TPM_REPO" "$TPM_DIR" >/dev/null
    echo "  Installed TPM at $TPM_DIR"
  fi

  # Plugin sync depends on chezmoi-applied ~/.tmux.conf as source of truth.
  local conf="$HOME/.tmux.conf"
  if [[ ! -f "$conf" ]]; then
    echo "  ~/.tmux.conf not found yet — skipping tmux plugin sync."
    return 0
  fi

  # Extract every `set[-option] -g @plugin '<repo>'` declaration.
  local -a declared=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && declared+=("$name")
  done < <(grep -E "^[[:space:]]*set(-option)?[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+" "$conf" \
    | sed -E "s/.*@plugin[[:space:]]+['\"]([^'\"]+)['\"].*/\1/")

  local plugin name dir
  for plugin in "${declared[@]}"; do
    name="${plugin##*/}"
    dir="$TMUX_PLUGIN_DIR/$name"
    if [[ -d "$dir/.git" ]]; then
      git -C "$dir" pull --ff-only --quiet || echo "  Failed to update tmux plugin: $plugin" >&2
    else
      if git clone --depth 1 "https://github.com/${plugin}.git" "$dir" >/dev/null 2>&1; then
        echo "  Installed tmux plugin: $plugin"
      else
        echo "  Failed to clone tmux plugin: $plugin" >&2
      fi
    fi
  done

  # ~/.tmux.conf is the source of truth: remove any plugin directory that was
  # cloned previously but is no longer declared. tpm itself is always kept.
  declare -A DESIRED_TMUX=()
  for plugin in "${declared[@]}"; do
    DESIRED_TMUX["${plugin##*/}"]=1
  done
  DESIRED_TMUX[tpm]=1

  shopt -s nullglob
  for dir in "$TMUX_PLUGIN_DIR"/*/; do
    name="$(basename "$dir")"
    if [[ -z "${DESIRED_TMUX[$name]:-}" ]]; then
      echo "  Removing tmux plugin not in ~/.tmux.conf: $name"
      rm -rf "$dir"
    fi
  done
  shopt -u nullglob
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

# LAYERED_PACKAGES is the source of truth: remove anything the user previously
# layered but is no longer in the array. netbird is preserved when its install
# was deferred this run so an older rpm-ostree doesn't accidentally drop it.
REQUESTED_LAYERED="$(sudo rpm-ostree status --json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d["deployments"][0].get("requested-packages",[])))' 2>/dev/null || true)"

if [[ -n "$REQUESTED_LAYERED" ]]; then
  declare -A DESIRED_LAYERED=()
  for pkg in "${LAYERED_PACKAGES[@]}"; do
    DESIRED_LAYERED["$pkg"]=1
  done
  if [[ "$NETBIRD_DEFERRED" == true ]]; then
    DESIRED_LAYERED[netbird]=1
  fi

  TO_REMOVE=()
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    [[ -n "${DESIRED_LAYERED[$pkg]:-}" ]] || TO_REMOVE+=("$pkg")
  done <<<"$REQUESTED_LAYERED"

  if (( ${#TO_REMOVE[@]} > 0 )); then
    echo "  Removing layered packages not in LAYERED_PACKAGES: ${TO_REMOVE[*]}"
    sudo rpm-ostree uninstall "${TO_REMOVE[@]}"
    NEEDS_REBOOT=true
  fi
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

# FLATPAK_APPS is the source of truth for flathub-origin apps: remove any
# flathub app that was previously installed but is no longer in the array.
# Apps from other remotes (e.g., fedora, vendor flatpak repos) are left alone.
declare -A DESIRED_FLATPAKS=()
for app in "${FLATPAK_APPS[@]}"; do
  DESIRED_FLATPAKS["$app"]=1
done

flatpak_removals=()
while IFS=$'\t' read -r app_id origin; do
  [[ -z "$app_id" || "$origin" != "flathub" ]] && continue
  [[ -n "${DESIRED_FLATPAKS[$app_id]:-}" ]] || flatpak_removals+=("$app_id")
done < <(flatpak list --app --columns=application,origin 2>/dev/null || true)

if (( ${#flatpak_removals[@]} > 0 )); then
  echo "  Removing Flatpak apps not in FLATPAK_APPS: ${flatpak_removals[*]}"
  flatpak uninstall -y --noninteractive "${flatpak_removals[@]}" || true
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

# Raise rootless Podman pids_limit so heavy container workloads (npm install,
# node-gyp, dnf inside toolbox) don't hit EAGAIN on pthread_create. The Podman
# default (2048) easily spikes during thread bursts and crashes GLib/Go tools.
containers_conf_dir="$HOME/.config/containers"
containers_conf="$containers_conf_dir/containers.conf"
mkdir -p "$containers_conf_dir"
if [[ ! -f "$containers_conf" ]]; then
  cat > "$containers_conf" <<'EOF'
[containers]
pids_limit = 0
EOF
  echo "  Created $containers_conf with pids_limit = 0"
elif ! grep -qE '^[[:space:]]*pids_limit[[:space:]]*=' "$containers_conf"; then
  if grep -qE '^\[containers\]' "$containers_conf"; then
    sed -i '/^\[containers\]/a pids_limit = 0' "$containers_conf"
  else
    printf '\n[containers]\npids_limit = 0\n' >> "$containers_conf"
  fi
  echo "  Added pids_limit = 0 to $containers_conf"
fi

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
# 5. Shell + tmux plugin managers (antidote + TPM)
# -----------------------------------------------------------------------------
echo "--- [5/10] Shell + tmux plugin managers (antidote + TPM) ---"

# Both plugin managers are installed here. Their plugin lists live inside
# fedora-dotfiles and are the declarative source of truth:
#   antidote → ~/.zsh_plugins.txt
#   TPM      → ~/.tmux.conf (`set -g @plugin '…'` directives)
# install_tpm clones declared entries into ~/.tmux/plugins and removes any
# checkout that is no longer declared.
install_antidote
install_tpm

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

# Best-effort: never fail the whole bootstrap just because the YubiKey is
# absent, scdaemon is unhappy, or keys.openpgp.org is unreachable. Any errors
# inside the subshell are contained.
(
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
      if card_output="$(LC_ALL=C timeout 10 gpg --card-status 2>&1)"; then
        card_rc=0
        break
      else
        card_rc=$?
      fi
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
) || echo "  YubiKey step had errors; continuing." >&2

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

# If an existing 'ai' toolbox was created before containers.conf was updated,
# its PidsLimit is still the old default and bootstrap will crash again.
# Recreate it so the new limit applies.
if command -v podman &>/dev/null && podman container exists ai 2>/dev/null; then
  ai_pids_limit="$(podman inspect ai --format '{{.HostConfig.PidsLimit}}' 2>/dev/null || echo 0)"
  if [[ "$ai_pids_limit" =~ ^[0-9]+$ ]] && (( ai_pids_limit > 0 && ai_pids_limit <= 2048 )); then
    echo "  Existing 'ai' toolbox has PidsLimit=$ai_pids_limit; recreating to pick up new containers.conf"
    toolbox rm -f ai &>/dev/null || podman rm -f ai &>/dev/null || true
  fi
fi

if [[ "$CHEZMOI_DEFERRED" == false ]]; then
  ai_bootstrap_ok=false
  for ai_attempt in 1 2 3; do
    if run_ai_toolbox_bootstrap; then
      ai_bootstrap_ok=true
      break
    fi
    if (( ai_attempt < 3 )); then
      echo "  AI toolbox bootstrap failed on attempt $ai_attempt/3; cleaning up and retrying..." >&2
      # Conmon exit-file timeouts and stale overlay locks usually clear after
      # removing the container and letting podman drop its transient state.
      toolbox rm -f ai &>/dev/null || podman rm -f ai &>/dev/null || true
      sleep 3
    fi
  done
  if [[ "$ai_bootstrap_ok" == false ]]; then
    echo "  AI toolbox bootstrap failed after 3 attempts; continuing with the rest of setup." >&2
    echo "  Retry manually: toolbox rm -f ai && bash ~/.local/share/chezmoi/bootstrap-ai-toolbox.sh" >&2
    echo "  If the error is a conmon exit-file timeout, also try:" >&2
    echo "    systemctl --user restart podman.socket && podman system migrate" >&2
  fi
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
