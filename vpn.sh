#!/usr/bin/env bash
set -euo pipefail
SSH_HOST=""
SSH_USER=""
SSH_PASS=""
SSH_PORT=""
SSH_KEY=""
SSH_EXTRA_OPTS=""
USER_CONF="${HOME}/Library/Application Support/ASO VPN/vpn.conf"
if [[ -n "${ASO_VPN_CONFIG:-}" && -f "${ASO_VPN_CONFIG}" ]]; then
  CONFIG_FILE="${ASO_VPN_CONFIG}"
elif [[ -f "$USER_CONF" ]]; then
  CONFIG_FILE="$USER_CONF"
else
  CONFIG_FILE=""
fi
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi
[[ -n "${SSH_PORT:-}" ]] || SSH_PORT="22"
case "${TMPDIR:-}" in
  *PKInstallSandbox*|*com.apple.installer*|*InstallAssistant*) unset TMPDIR ;;
esac
RUNTIME_TMP="/tmp"
PID_FILE="${RUNTIME_TMP}/aso-ssh-vpn.pid"
HELPER_DIR="${RUNTIME_TMP}/aso-ssh-vpn-helpers"
STATE_MARKER="${RUNTIME_TMP}/aso-ssh-vpn.mode"
PFCTL_BIN="$(command -v pfctl 2>/dev/null || true)"
[[ -x "$PFCTL_BIN" ]] || PFCTL_BIN="/sbin/pfctl"
KILL_BIN="$(command -v kill 2>/dev/null || true)"
[[ -x "$KILL_BIN" ]] || KILL_BIN="/bin/kill"
# Fixed system paths — survive app moves, Homebrew upgrades, and relaunches.
ASO_LIB_DIR="/Library/ASOVPN"
ASO_HELPER="${ASO_LIB_DIR}/helper.sh"
ASO_SUDOERS="/etc/sudoers.d/aso-vpn"
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
notify() {
  local title="$1" msg="$2"
  osascript -e "display notification \"${msg}\" with title \"${title}\"" 2>/dev/null || true
}
need_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { red "macOS only"; exit 1; }
}
check_config() {
  [[ -n "$SSH_HOST" && -n "$SSH_USER" ]] || {
    red "No config yet. Open Config, enter Host/User, then Save."
    echo "STATE=OFF"
    exit 1
  }
}
# True CPU family (not process arch) — correct under Rosetta on Apple Silicon.
host_is_apple_silicon() {
  [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]
}
find_sshuttle() {
  local p candidates=()
  # Prefer native Homebrew path for this Mac (M-series vs Intel).
  if host_is_apple_silicon; then
    candidates+=(/opt/homebrew/bin/sshuttle /usr/local/bin/sshuttle)
  else
    candidates+=(/usr/local/bin/sshuttle /opt/homebrew/bin/sshuttle)
  fi
  candidates+=("$(command -v sshuttle 2>/dev/null || true)")
  for p in "${candidates[@]}"; do
    [[ -n "$p" && -x "$p" ]] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
ensure_sshuttle() {
  local bin
  if bin="$(find_sshuttle)"; then SSHUTTLE_BIN="$bin"; return 0; fi
  yellow "Installing sshuttle via Homebrew..."
  if ! install_deps_for_user "$(id -un)"; then
    red "Could not install sshuttle (Homebrew required: https://brew.sh)"
    echo "STATE=OFF"
    exit 1
  fi
  bin="$(find_sshuttle)" || { red "sshuttle install failed"; echo "STATE=OFF"; exit 1; }
  SSHUTTLE_BIN="$bin"
}
real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  local cu
  cu="$(stat -f%Su /dev/console 2>/dev/null || true)"
  if [[ -n "$cu" && "$cu" != "root" ]]; then
    printf '%s\n' "$cu"
    return 0
  fi
  id -un
}
user_home() {
  local user="$1"
  if [[ "$(id -un)" == "$user" && "$(id -u)" -ne 0 ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  local home=""
  home="$(sudo -u "$user" -H sh -c 'printf %s "$HOME"' 2>/dev/null || true)"
  [[ -n "$home" ]] && { printf '%s\n' "$home"; return 0; }
  printf '/Users/%s\n' "$user"
}
launch_script_path_for() {
  printf '%s/.aso-vpn/launch-sshuttle.sh\n' "$(user_home "$1")"
}
brew_prefix_for_arch() {
  # Apple Silicon → /opt/homebrew ; Intel → /usr/local.
  # Prefer an already-installed brew; otherwise choose by real CPU (Rosetta-safe).
  if host_is_apple_silicon; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
      printf '/opt/homebrew\n'
    elif [[ -x /usr/local/bin/brew ]]; then
      printf '/usr/local\n'
    else
      printf '/opt/homebrew\n'
    fi
  else
    if [[ -x /usr/local/bin/brew ]]; then
      printf '/usr/local\n'
    elif [[ -x /opt/homebrew/bin/brew ]]; then
      printf '/opt/homebrew\n'
    else
      printf '/usr/local\n'
    fi
  fi
}
ensure_xcode_clt() {
  if xcode-select -p >/dev/null 2>&1; then
    return 0
  fi
  yellow "Installing Apple Command Line Tools (needed for Homebrew)..."
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  local prod=""
  prod="$(softwareupdate -l 2>/dev/null | awk -F: '/Label:.*Command Line Tools/{gsub(/^ /,"",$2); print $2; exit}')"
  if [[ -z "$prod" ]]; then
    prod="$(softwareupdate -l 2>/dev/null | sed -n 's/^[[:space:]]*\*[[:space:]]*Label:[[:space:]]*//p' | grep -i 'Command Line Tools' | head -n1 || true)"
  fi
  if [[ -n "$prod" ]]; then
    softwareupdate -i "$prod" --agree-to-license || true
  else
    /usr/bin/xcode-select --install 2>/dev/null || true
    sleep 2
  fi
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  xcode-select -p >/dev/null 2>&1
}
ensure_homebrew_for_user() {
  local user="$1"
  local home brew_prefix brew_bin
  home="$(user_home "$user")"
  brew_prefix="$(brew_prefix_for_arch)"
  brew_bin="${brew_prefix}/bin/brew"
  if [[ -x "$brew_bin" ]]; then
    green "Homebrew: OK (${brew_bin})"
    return 0
  fi
  if sudo -u "$user" -H bash -lc 'command -v brew >/dev/null 2>&1'; then
    green "Homebrew: OK (in PATH)"
    return 0
  fi
  yellow "Homebrew not found — installing automatically for ${user}..."
  ensure_xcode_clt || yellow "CLT check incomplete; continuing Homebrew install..."
  mkdir -p "${brew_prefix}"
  chown -R "${user}:admin" "${brew_prefix}" 2>/dev/null || chown -R "${user}:staff" "${brew_prefix}"
  if ! host_is_apple_silicon; then
    mkdir -p /usr/local/{bin,Cellar,Frameworks,Homebrew,etc,include,lib,opt,sbin,share,var}
    chown -R "${user}:admin" /usr/local/{bin,Cellar,Frameworks,Homebrew,etc,include,lib,opt,sbin,share,var} 2>/dev/null || true
  fi
  local installer="/tmp/aso-homebrew-install.sh" brew_install_cmd
  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"
  chmod 755 "$installer"
  # Force arm64 Homebrew on Apple Silicon even if this shell is Rosetta x86_64.
  if host_is_apple_silicon && [[ "$(uname -m)" != "arm64" ]]; then
    brew_install_cmd=(arch -arm64 /bin/bash "$installer")
  else
    brew_install_cmd=(/bin/bash "$installer")
  fi
  if ! sudo -u "$user" -H env \
      NONINTERACTIVE=1 \
      CI=1 \
      HOME="$home" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:${brew_prefix}/bin" \
      "${brew_install_cmd[@]}"; then
    red "Automatic Homebrew install failed."
    rm -f "$installer"
    return 1
  fi
  rm -f "$installer"
  if [[ ! -x "$brew_bin" ]]; then
    red "Homebrew installed but brew binary not found at ${brew_bin}"
    return 1
  fi
  local profile="${home}/.zprofile"
  if ! grep -q 'brew shellenv' "$profile" 2>/dev/null; then
    sudo -u "$user" -H tee -a "$profile" >/dev/null <<EOF

eval "\$(${brew_bin} shellenv)"
EOF
  fi
  green "Homebrew installed at ${brew_prefix}"
  return 0
}
install_deps_for_user() {
  local user="$1" brew_bin brew_prefix
  yellow "Checking / installing dependencies for ${user}..."
  if sudo -u "$user" -H bash -lc 'command -v sshuttle >/dev/null 2>&1' \
     || [[ -x /opt/homebrew/bin/sshuttle ]] \
     || [[ -x /usr/local/bin/sshuttle ]]; then
    green "sshuttle: OK"
    return 0
  fi
  ensure_homebrew_for_user "$user" || return 1
  brew_prefix="$(brew_prefix_for_arch)"
  brew_bin="${brew_prefix}/bin/brew"
  [[ -x "$brew_bin" ]] || brew_bin="$(sudo -u "$user" -H bash -lc 'command -v brew' 2>/dev/null || true)"
  [[ -n "$brew_bin" && -x "$brew_bin" ]] || { red "brew still missing after install"; return 1; }
  yellow "Installing sshuttle..."
  local brew_env=(env HOMEBREW_NO_AUTO_UPDATE=1 PATH="$(dirname "$brew_bin"):/usr/bin:/bin" "$brew_bin" install sshuttle)
  local ok=0
  if host_is_apple_silicon && [[ "$(uname -m)" != "arm64" ]]; then
    sudo -u "$user" -H arch -arm64 "${brew_env[@]}" && ok=1
  else
    sudo -u "$user" -H "${brew_env[@]}" && ok=1
  fi
  if [[ "$ok" -eq 1 ]]; then
    green "sshuttle installed"
    return 0
  fi
  red "Failed to install sshuttle"
  return 1
}
sshuttle_path_for_user() {
  local user="$1" bin=""
  bin="$(sudo -u "$user" -H bash -lc 'command -v sshuttle' 2>/dev/null || true)"
  [[ -n "$bin" && -x "$bin" ]] && { printf '%s\n' "$bin"; return 0; }
  find_sshuttle
}
write_launch_script_for_user() {
  local user="$1"
  local launch home session
  home="$(user_home "$user")"
  launch="${home}/.aso-vpn/launch-sshuttle.sh"
  session="${home}/.aso-vpn/session.env"
  if [[ "$(id -un)" == "$user" && "$(id -u)" -ne 0 ]]; then
    mkdir -p "${home}/.aso-vpn"
    cat > "$launch" <<LAUNCH
#!/bin/bash
set -euo pipefail
SESSION="${session}"
[[ -f "\$SESSION" ]] || { echo "ASO VPN: missing session.env"; exit 1; }
source "\$SESSION"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
if [[ -n "\${ASO_SSH_PASS:-}" ]]; then
  export ASO_SSH_PASS SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
fi
/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || /usr/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
exec "\$SSHUTTLE_BIN" -D --pidfile="\$PID_FILE" --dns --ns-hosts 8.8.8.8,1.1.1.1 --to-ns 8.8.8.8 --disable-ipv6 --method auto --ssh-cmd "\$SSH_CMD" -r "\$REMOTE" -x "\$EXCLUDE_IP" 0/0
LAUNCH
    chmod 700 "$launch"
  else
    sudo -u "$user" -H mkdir -p "${home}/.aso-vpn"
    sudo -u "$user" -H tee "$launch" >/dev/null <<LAUNCH
#!/bin/bash
set -euo pipefail
SESSION="${session}"
[[ -f "\$SESSION" ]] || { echo "ASO VPN: missing session.env"; exit 1; }
source "\$SESSION"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
if [[ -n "\${ASO_SSH_PASS:-}" ]]; then
  export ASO_SSH_PASS SSH_ASKPASS SSH_ASKPASS_REQUIRE DISPLAY
fi
/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || /usr/sbin/pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
exec "\$SSHUTTLE_BIN" -D --pidfile="\$PID_FILE" --dns --ns-hosts 8.8.8.8,1.1.1.1 --to-ns 8.8.8.8 --disable-ipv6 --method auto --ssh-cmd "\$SSH_CMD" -r "\$REMOTE" -x "\$EXCLUDE_IP" 0/0
LAUNCH
    sudo -u "$user" -H chmod 700 "$launch"
  fi
  printf '%s\n' "$launch"
}
# Recreate user launch script without admin (path is always ~/.aso-vpn/...).
ensure_launch_script() {
  local user launch
  user="$(id -un)"
  [[ "$user" != "root" ]] || return 0
  launch="$(launch_script_path_for "$user")"
  if [[ -x "$launch" ]]; then
    return 0
  fi
  write_launch_script_for_user "$user" >/dev/null
}
# One durable check: fixed helper + NOPASSWD. Nothing else (brew path, launch file) can "forget" auth.
has_nopasswd_sudo() {
  ensure_launch_script || true
  [[ -x "$ASO_HELPER" ]] || return 1
  sudo -n "$ASO_HELPER" ping >/dev/null 2>&1
}
require_privilege() {
  if has_nopasswd_sudo; then
    return 0
  fi
  red "Admin access not granted yet."
  echo "STATE=NEED_AUTH"
  exit 78
}
sudo_run() {
  require_privilege
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$ASO_HELPER" run "$@"
  fi
}
# Root (AppleScript install/reset) or passwordless helper — works on every Mac admin setup.
net_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$ASO_HELPER" run "$@"
  fi
}
write_aso_helper() {
  mkdir -p "$ASO_LIB_DIR"
  cat > "$ASO_HELPER" <<'HELPER'
#!/bin/bash
set -euo pipefail
cmd="${1:-}"
shift || true
allowed_bin() {
  case "$1" in
    /opt/homebrew/bin/sshuttle|/usr/local/bin/sshuttle) return 0 ;;
    /sbin/pfctl|/usr/sbin/pfctl) return 0 ;;
    /bin/kill|/bin/rm) return 0 ;;
    /usr/sbin/networksetup|/usr/bin/killall|/usr/bin/dscacheutil) return 0 ;;
    *) return 1 ;;
  esac
}
allowed_launch() {
  [[ "$1" =~ ^/Users/[A-Za-z0-9._-]+/\.aso-vpn/launch-sshuttle\.sh$ ]]
}
case "$cmd" in
  ping)
    printf 'PONG\n'
    exit 0
    ;;
  run)
    [[ "$#" -ge 1 ]] || { echo "ASO helper: missing command" >&2; exit 2; }
    bin="$1"; shift || true
    if allowed_bin "$bin" || allowed_launch "$bin"; then
      exec "$bin" "$@"
    fi
    echo "ASO helper: refused $bin" >&2
    exit 3
    ;;
  *)
    echo "ASO helper: usage: helper.sh ping|run <cmd> [args...]" >&2
    exit 2
    ;;
esac
HELPER
  chmod 755 "$ASO_HELPER"
  chown root:wheel "$ASO_HELPER"
  chown root:wheel "$ASO_LIB_DIR"
}
all_network_services() {
  local service
  while IFS= read -r service; do
    [[ -z "$service" || "$service" == *"*"* ]] && continue
    printf '%s\n' "$service"
  done < <(net_cmd /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
}
clear_all_system_proxies() {
  local service
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    net_cmd /usr/sbin/networksetup -setsocksfirewallproxystate "$service" off >/dev/null 2>&1 || true
    net_cmd /usr/sbin/networksetup -setwebproxystate "$service" off >/dev/null 2>&1 || true
    net_cmd /usr/sbin/networksetup -setsecurewebproxystate "$service" off >/dev/null 2>&1 || true
    net_cmd /usr/sbin/networksetup -setftpproxystate "$service" off >/dev/null 2>&1 || true
    net_cmd /usr/sbin/networksetup -setautoproxystate "$service" off >/dev/null 2>&1 || true
  done < <(all_network_services)
  flush_dns_cache
}
net_state_file() {
  # Console user home — works for Intel + Apple Silicon, and if script is elevated.
  printf '%s/Library/Application Support/ASO VPN/net-state.txt\n' "$(user_home "$(real_user)")"
}
flush_dns_cache() {
  net_cmd /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
  net_cmd /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
}
# Hardware en* services only (Wi-Fi/Ethernet). Skips VPN utun services on any Mac.
hardware_network_services() {
  local line service device name
  service=""
  device=""
  while IFS= read -r line; do
    # Capture BASH_REMATCH immediately — a later [[ =~ ]] overwrites it (breaks set -u).
    if [[ "$line" =~ ^\([0-9]+\)\ (.+)$ ]]; then
      name="${BASH_REMATCH[1]}"
      if [[ -n "$service" && "$device" =~ ^en[0-9]+$ ]]; then
        printf '%s\n' "$service"
      fi
      service="$name"
      device=""
    elif [[ "$line" =~ Device:\ (en[0-9]+) ]]; then
      device="${BASH_REMATCH[1]}"
    fi
  done < <(net_cmd /usr/sbin/networksetup -listnetworkserviceorder 2>/dev/null || true)
  if [[ -n "$service" && "$device" =~ ^en[0-9]+$ ]]; then
    printf '%s\n' "$service"
  fi
}
# Browsers prefer IPv6; sshuttle here is IPv4-only, so disable IPv6 + pin DNS while up.
harden_network_for_tunnel() {
  local service info dns v6 ip save_state=0 state_file
  state_file="$(net_state_file)"
  mkdir -p "$(dirname "$state_file")"
  # Only snapshot originals once per session (avoid saving already-pinned 8.8.8.8).
  if [[ ! -f "$state_file" ]]; then
    save_state=1
    : > "$state_file"
  fi
  while IFS= read -r service; do
    [[ -z "$service" ]] && continue
    info="$(net_cmd /usr/sbin/networksetup -getinfo "$service" 2>/dev/null || true)"
    [[ -n "$info" ]] || continue
    ip="$(printf '%s\n' "$info" | awk -F': ' '/^IP address:/{print $2; exit}')"
    [[ -n "$ip" && "$ip" != "none" ]] || continue
    if [[ "$save_state" -eq 1 ]]; then
      dns="$(net_cmd /usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)"
      if [[ -z "$dns" ]] || printf '%s\n' "$dns" | grep -qi "aren't any"; then
        dns="Empty"
      else
        dns="$(printf '%s\n' "$dns" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
      fi
      v6="Automatic"
      if printf '%s\n' "$info" | grep -q 'IPv6: Off'; then
        v6="Off"
      elif printf '%s\n' "$info" | grep -q 'IPv6: Manual'; then
        v6="Manual"
      fi
      printf '%s\t%s\t%s\n' "$service" "$v6" "$dns" >> "$state_file"
    fi
    net_cmd /usr/sbin/networksetup -setv6off "$service" >/dev/null 2>&1 || true
    net_cmd /usr/sbin/networksetup -setdnsservers "$service" 8.8.8.8 1.1.1.1 >/dev/null 2>&1 || true
  done < <(hardware_network_services)
  flush_dns_cache
}
restore_network_after_tunnel() {
  local service v6 dns state_file
  state_file="$(net_state_file)"
  [[ -f "$state_file" ]] || return 0
  while IFS=$'\t' read -r service v6 dns; do
    [[ -z "$service" ]] && continue
    case "$v6" in
      Off) net_cmd /usr/sbin/networksetup -setv6off "$service" >/dev/null 2>&1 || true ;;
      *)   net_cmd /usr/sbin/networksetup -setv6automatic "$service" >/dev/null 2>&1 || true ;;
    esac
    if [[ -z "$dns" || "$dns" == "Empty" ]]; then
      net_cmd /usr/sbin/networksetup -setdnsservers "$service" Empty >/dev/null 2>&1 || true
    else
      # Intentional word-split: stored as space-separated DNS list.
      # shellcheck disable=SC2086
      net_cmd /usr/sbin/networksetup -setdnsservers "$service" $dns >/dev/null 2>&1 || true
    fi
  done < "$state_file"
  rm -f "$state_file"
  flush_dns_cache
}
pid_alive() {
  local pid="${1:-}"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}
is_tunnel_up() {
  local pid=""
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    # sshuttle daemon runs as root; use ps (not kill -0) so non-root can detect it.
    if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sudo -n /bin/rm -f "$PID_FILE" 2>/dev/null || rm -f "$PID_FILE" 2>/dev/null || true
  fi
  pgrep -f "sshuttle.*${SSH_HOST}" >/dev/null 2>&1
}
resolve_host_ip() {
  local ip
  ip="$(dscacheutil -q host -a name "$SSH_HOST" 2>/dev/null | awk '/^ip_address:/{print $2; exit}')"
  [[ -z "$ip" ]] && ip="$(dig +short "$SSH_HOST" A 2>/dev/null | awk 'NR==1 && $1 ~ /^[0-9.]+$/{print; exit}')"
  [[ -z "$ip" ]] && ip="$(python3 -c "import socket; print(socket.gethostbyname('${SSH_HOST}'))" 2>/dev/null || true)"
  printf '%s\n' "$ip"
}
make_askpass() {
  mkdir -p "$HELPER_DIR"
  local askpass="${HELPER_DIR}/askpass.sh"
  cat > "$askpass" <<'ASK'
#!/bin/bash
printf '%s\n' "${ASO_SSH_PASS}"
ASK
  chmod 700 "$askpass"
  printf '%s\n' "$askpass"
}
build_ssh_cmd() {
  local parts=(ssh -p "$SSH_PORT"
    -o ExitOnForwardFailure=yes
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
  )
  if [[ -n "$SSH_KEY" ]]; then
    parts+=(-i "$SSH_KEY")
  elif [[ -n "${SSH_PASS:-}" ]]; then
    parts+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
  fi
  if [[ -n "$SSH_EXTRA_OPTS" ]]; then
    parts+=($SSH_EXTRA_OPTS)
  fi
  printf '%q ' "${parts[@]}"
}
kill_tunnel() {
  local pid="" orphan
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && pid_alive "$pid"; then
    sudo_run /bin/kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pid_alive "$pid" || break
      sleep 0.2
    done
    if pid_alive "$pid"; then
      sudo_run /bin/kill -9 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  while IFS= read -r orphan; do
    [[ -z "$orphan" ]] && continue
    sudo_run /bin/kill -9 "$orphan" 2>/dev/null || kill -9 "$orphan" 2>/dev/null || true
  done < <(pgrep -f "sshuttle.*${SSH_HOST}" 2>/dev/null || true)
  sudo_run /bin/rm -f "$PID_FILE" "$STATE_MARKER" 2>/dev/null || rm -f "$PID_FILE" "$STATE_MARKER" 2>/dev/null || true
  sudo_run "$PFCTL_BIN" -f /etc/pf.conf 2>/dev/null || true
}
install_privileges() {
  need_macos
  local user home tmp
  user="$(real_user)"
  [[ "$user" != "root" ]] || user="$(stat -f%Su /dev/console 2>/dev/null || true)"
  [[ -n "$user" && "$user" != "root" ]] || { red "Could not determine console user"; exit 1; }
  yellow "Setting up ASO VPN for user: ${user}"
  install_deps_for_user "$user" || exit 1
  local bin=""
  bin="$(sshuttle_path_for_user "$user")"
  [[ -n "$bin" && -x "$bin" ]] || { red "sshuttle not found after install"; exit 1; }
  write_launch_script_for_user "$user" >/dev/null
  write_aso_helper
  home="$(user_home "$user")"
  tmp="$(mktemp /tmp/aso-sudoers.XXXXXX)"
  # Single NOPASSWD rule for the fixed helper — never breaks when brew/app paths change.
  cat > "$tmp" <<EOF
Defaults!${ASO_HELPER} !requiretty
${user} ALL=(root) NOPASSWD: ${ASO_HELPER}
EOF
  chmod 440 "$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    red "Invalid sudoers content"
    cat "$tmp" >&2 || true
    rm -f "$tmp"
    exit 1
  fi
  cp "$tmp" "$ASO_SUDOERS"
  chmod 440 "$ASO_SUDOERS"
  chown root:wheel "$ASO_SUDOERS"
  rm -f "$tmp"
  if ! sudo -u "$user" -H sudo -n "$ASO_HELPER" ping >/dev/null 2>&1; then
    red "Sudo verify failed for ${user} (helper ping)"
    exit 1
  fi
  if ! sudo -u "$user" -H sudo -n "$ASO_HELPER" run /sbin/pfctl -s info >/dev/null 2>&1; then
    red "Sudo verify failed for ${user} (helper pfctl)"
    exit 1
  fi
  sudo -u "$user" -H mkdir -p "${home}/Library/Application Support/ASO VPN"
  sudo -u "$user" -H sh -c "date > '${home}/Library/Application Support/ASO VPN/.sudoers-ok'"
  green "Privileges saved permanently for ${user}"
  echo "STATE=AUTH_OK"
}
auth_status() {
  need_macos
  if has_nopasswd_sudo; then
    echo "STATE=AUTH_OK"
    green "Admin: granted (one-time, permanent)"
  else
    echo "STATE=NEED_AUTH"
    yellow "Admin: not granted yet"
  fi
}
reset_privileges() {
  need_macos
  local user home
  user="$(real_user)"
  [[ "$user" != "root" ]] || user="$(stat -f%Su /dev/console)"
  home="$(user_home "$user")"
  yellow "Resetting ASO VPN permission for ${user}..."
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
  pkill -f "sshuttle.*${SSH_HOST}" 2>/dev/null || true
  rm -f "$STATE_MARKER"
  rm -f "$ASO_SUDOERS"
  rm -f "$ASO_HELPER"
  rmdir "$ASO_LIB_DIR" 2>/dev/null || true
  sudo -u "$user" -H rm -f "${home}/Library/Application Support/ASO VPN/.sudoers-ok" 2>/dev/null || true
  rm -f "${home}/Library/Application Support/ASO VPN/.sudoers-ok" 2>/dev/null || true
  sudo -u "$user" -H rm -f "${home}/.aso-vpn/session.env" 2>/dev/null || true
  # Best-effort network restore while still root (AppleScript reset).
  /usr/sbin/networksetup -listallnetworkservices >/dev/null 2>&1 || true
  clear_all_system_proxies 2>/dev/null || true
  restore_network_after_tunnel 2>/dev/null || true
  "$PFCTL_BIN" -f /etc/pf.conf >/dev/null 2>&1 || true
  green "Permission reset. Click Connect and Allow once."
  echo "STATE=NEED_AUTH"
}
start_tunnel() {
  need_macos
  check_config
  ensure_sshuttle
  require_privilege
  clear_all_system_proxies
  if is_tunnel_up; then
    yellow "Already connected."
    [[ -f "$(net_state_file)" ]] || harden_network_for_tunnel
    echo "tunnel" > "$STATE_MARKER"
    echo "STATE=ON"
    green "VPN ON"
    notify "VPN" "ON — ${SSH_HOST}"
    exit 0
  fi
  kill_tunnel || true
  clear_all_system_proxies
  # Pin DNS/IPv6 BEFORE sshuttle so --dns/--ns-hosts capture real resolvers, not poisoned ISP DNS.
  harden_network_for_tunnel
  local host_ip askpass="" ssh_cmd
  host_ip="$(resolve_host_ip)"
  [[ -n "$host_ip" ]] || { red "Could not resolve ${SSH_HOST}"; restore_network_after_tunnel; echo "STATE=OFF"; exit 1; }
  dim "Remote IP: $host_ip"
  ssh_cmd="$(build_ssh_cmd)"
  ssh_cmd="${ssh_cmd% }"
  if [[ -n "${SSH_PASS:-}" && -z "${SSH_KEY:-}" ]]; then
    askpass="$(make_askpass)"
  fi
  local aso_dir="${HOME}/.aso-vpn"
  local session="${aso_dir}/session.env"
  local launch="${aso_dir}/launch-sshuttle.sh"
  mkdir -p "$aso_dir"
  {
    printf 'SSHUTTLE_BIN=%q\n' "$SSHUTTLE_BIN"
    printf 'PID_FILE=%q\n' "$PID_FILE"
    printf 'SSH_CMD=%q\n' "$ssh_cmd"
    printf 'REMOTE=%q\n' "${SSH_USER}@${SSH_HOST}"
    printf 'EXCLUDE_IP=%q\n' "$host_ip"
    if [[ -n "$askpass" ]]; then
      printf 'ASO_SSH_PASS=%q\n' "$SSH_PASS"
      printf 'SSH_ASKPASS=%q\n' "$askpass"
      printf 'SSH_ASKPASS_REQUIRE=%q\n' "force"
      printf 'DISPLAY=%q\n' "${DISPLAY:-:0}"
    fi
  } > "$session"
  chmod 600 "$session"
  write_launch_script_for_user "$(id -un)" >/dev/null
  green "Starting system tunnel..."
  local launch_err
  launch_err="$(mktemp "${RUNTIME_TMP}/aso-ssh-launch.XXXXXX")"
  if ! sudo_run "$launch" >"$launch_err" 2>&1; then
    red "Failed to start sshuttle (sudo/launch)."
    [[ -s "$launch_err" ]] && cat "$launch_err" >&2 || true
    rm -f "$launch_err"
    kill_tunnel || true
    restore_network_after_tunnel
    echo "STATE=OFF"
    exit 1
  fi
  rm -f "$launch_err"
  local i
  for i in $(seq 1 40); do
    if is_tunnel_up; then
      break
    fi
    sleep 0.5
  done
  if ! is_tunnel_up; then
    red "Tunnel did not stay up within timeout. Check SSH credentials / remote Python."
    kill_tunnel || true
    restore_network_after_tunnel
    echo "STATE=OFF"
    exit 1
  fi
  echo "tunnel" > "$STATE_MARKER"
  echo "STATE=ON"
  green "VPN ON — all TCP + DNS via ${SSH_HOST}"
  notify "VPN" "ON — full tunnel ${SSH_HOST}"
}
stop_tunnel() {
  need_macos
  if is_tunnel_up || [[ -f "$PID_FILE" ]] || pgrep -f "sshuttle.*${SSH_HOST}" >/dev/null 2>&1; then
    yellow "Disconnecting..."
    if has_nopasswd_sudo; then
      kill_tunnel
    else
      local pid orphan
      pid="$(cat "$PID_FILE" 2>/dev/null || true)"
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
      while IFS= read -r orphan; do
        [[ -z "$orphan" ]] && continue
        kill -9 "$orphan" 2>/dev/null || true
      done < <(pgrep -f "sshuttle.*${SSH_HOST}" 2>/dev/null || true)
      rm -f "$PID_FILE" "$STATE_MARKER"
    fi
    green "Tunnel stopped."
  else
    yellow "No active tunnel."
    rm -f "$PID_FILE" "$STATE_MARKER"
  fi
  clear_all_system_proxies
  restore_network_after_tunnel
  if is_tunnel_up; then
    red "Could not fully stop tunnel."
    echo "STATE=ON"
    exit 1
  fi
  echo "STATE=OFF"
  green "VPN OFF"
  notify "VPN" "OFF"
}
show_status() {
  need_macos
  local state="OFF" pid=""
  if is_tunnel_up; then
    state="ON"
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ -z "$pid" ]] && pid="$(pgrep -f "sshuttle.*${SSH_HOST}" 2>/dev/null | head -n1 || true)"
  fi
  echo "STATE=${state}"
  if has_nopasswd_sudo; then
    echo "AUTH=OK"
  else
    echo "AUTH=NEED"
  fi
  if [[ "$state" == "ON" ]]; then
    green "Tunnel: RUNNING (pid ${pid:-?})"
    green "Mode  : system-wide (all apps)"
  else
    yellow "Tunnel: STOPPED"
  fi
  if [[ -n "${SSH_HOST:-}" && -n "${SSH_USER:-}" ]]; then
    echo "Target: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
  else
    echo "Target: (not configured)"
  fi
  echo "Engine: sshuttle"
}
restart_tunnel() { stop_tunnel || true; start_tunnel; }
toggle_tunnel() {
  if is_tunnel_up; then stop_tunnel; else start_tunnel; fi
}
main() {
  case "${1:-}" in
    ""|toggle|t)     toggle_tunnel ;;
    on|start|1)      start_tunnel ;;
    off|stop|0)      stop_tunnel ;;
    status|s)        show_status ;;
    restart)         restart_tunnel ;;
    auth-status)     auth_status ;;
    install-priv)    install_privileges ;;
    reset-priv)      reset_privileges ;;
    -h|--help|help)
      echo "Usage: vpn.sh on|off|status|auth-status|install-priv|reset-priv"
      ;;
    *) red "Unknown: $1"; exit 1 ;;
  esac
}
main "$@"
