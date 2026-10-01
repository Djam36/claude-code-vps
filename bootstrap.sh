#!/usr/bin/env bash
# claude-code-vps: server-side bootstrap for Debian / Ubuntu.
#
# Started by install.sh / install.ps1 over SSH, as root (directly or via sudo):
#   bootstrap.sh prepare <api> <user> <public_key_base64> <sudo_mode>
#   bootstrap.sh harden  <api> <user> [ssh_port_the_client_used]
#
# prepare: base packages, Claude Code from Anthropic's signed apt repo, the work
#          user with the SSH key, swap on small servers.
# harden:  key-only SSH without root login, UFW, fail2ban, automatic updates.
#          Runs only after the client has proven it can log in as the work user.
#
# Both phases are idempotent: running them again is safe.
# Nothing graphical is installed and nothing new listens on the network.

set -Eeuo pipefail
umask 022

readonly CCV_API=1
readonly STATE_DIR=/var/lib/claude-vps
readonly LOG_FILE=/var/log/claude-vps-install.log
readonly SUDO_PASSWORD_FILE="$STATE_DIR/sudo-password"
readonly SSHD=/usr/sbin/sshd
readonly SSHD_DROPIN=/etc/ssh/sshd_config.d/00-claude-vps.conf
readonly SUDOERS_INSTALL=/etc/sudoers.d/90-claude-vps-install
readonly SUDOERS_NOPASSWD=/etc/sudoers.d/91-claude-vps-nopasswd
readonly F2B_JAIL=/etc/fail2ban/jail.d/claude-vps.conf
readonly SUDO_CLEANUP_UNIT=claude-vps-sudo-cleanup
readonly UU_CLAUDE=/etc/apt/apt.conf.d/52claude-vps
readonly CLAUDE_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
readonly CLAUDE_KEY_FILE=/etc/apt/keyrings/claude-code.asc
# Fingerprint published in the official Claude Code setup docs.
readonly CLAUDE_KEY_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
readonly CLAUDE_APT_LIST=/etc/apt/sources.list.d/claude-code.list
readonly SWAP_FILE=/swapfile-claude-vps

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a LC_ALL=C

STEP="запуск"
USER_NAME=""
KEY_B64=""
SUDO_MODE=""
CLIENT_PORT=""

say()  { printf '\n[ .. ] %s\n' "$*"; }
ok()   { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die()  { rm -f "$SUDOERS_INSTALL" 2>/dev/null || true; printf '[FAIL] %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  # Never leave the temporary passwordless sudo behind after a failed phase.
  rm -f "$SUDOERS_INSTALL"
  printf '\n[FAIL] Шаг «%s» завершился с ошибкой (код %s).\n' "$STEP" "$rc" >&2
  printf '[FAIL] Полный журнал на сервере: %s\n' "$LOG_FILE" >&2
  exit "$rc"
}

version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

# apt waits for dpkg locks held by cloud-init or unattended-upgrades instead of failing.
# Its long output goes to the log only; on failure the tail is shown.
apt_get() {
  local rc=0
  apt-get -o DPkg::Lock::Timeout=600 -y -q "$@" </dev/null >>"$LOG_FILE" 2>&1 || rc=$?
  if (( rc != 0 )); then
    warn "apt-get $1 завершился с ошибкой (код $rc). Последние строки журнала:"
    tail -n 25 "$LOG_FILE" >&2
  fi
  return "$rc"
}

apt_update() {
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if apt_get update; then
      return 0
    fi
    warn "apt-get update не прошёл (попытка $attempt из 6), повторю через 20 секунд..."
    sleep 20
  done
  die "apt-get update так и не прошёл. Проверьте интернет на сервере и источники пакетов."
}

# ---------------------------------------------------------------- prepare ----

check_os() {
  STEP="проверка системы"
  [[ -r /etc/os-release ]] || die "Нет /etc/os-release: это не похоже на Debian или Ubuntu."
  # shellcheck disable=SC1091
  . /etc/os-release
  local id=${ID:-} version=${VERSION_ID:-} like=" ${ID_LIKE:-} "

  case "$id" in
    ubuntu)
      version_ge "$version" 20.04 || die "Ubuntu $version слишком старая: нужна 20.04 или новее (лучше 24.04 LTS)."
      ;;
    debian)
      if [[ -z "$version" ]]; then
        warn "Debian testing/sid официально не проверялся. Продолжаю."
      else
        version_ge "$version" 11 || die "Debian $version слишком старый: нужен 11 или новее (лучше 12)."
      fi
      ;;
    *)
      if [[ "$like" == *" debian "* || "$like" == *" ubuntu "* ]]; then
        warn "${PRETTY_NAME:-$id} — производная Debian/Ubuntu, официально не проверялась. Продолжаю."
      else
        die "${PRETTY_NAME:-$id} не поддерживается: нужен Debian 11+ или Ubuntu 20.04+."
      fi
      ;;
  esac

  command -v apt-get >/dev/null 2>&1 || die "Не найден apt-get: нужна Debian-подобная система."
  [[ -d /run/systemd/system ]] || die "Нужен systemd. Контейнеры и урезанные образы без systemd не поддерживаются."
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "Архитектура $(uname -m) не поддерживается: Claude Code собирается только для x86_64 и ARM64." ;;
  esac
  ok "Система: ${PRETTY_NAME:-$id} ($(uname -m))"
}

add_swap() {
  local mem_mb=$1 disk_mb=$2
  if [[ -f "$SWAP_FILE" ]]; then
    swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$SWAP_FILE" || swapon "$SWAP_FILE" 2>/dev/null || true
    return 0
  fi
  if (( disk_mb < 8000 )); then
    warn "RAM всего ${mem_mb} МБ, а места на диске под swap мало. Claude Code может падать по памяти."
    return 0
  fi
  say "RAM меньше 4 ГБ: создаю swap-файл на 2 ГБ, чтобы Claude Code не падал по памяти..."
  if ! { fallocate -l 2G "$SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=2048 status=none; }; then
    rm -f "$SWAP_FILE"
    warn "Не удалось создать swap-файл. Продолжаю без него."
    return 0
  fi
  chmod 0600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  if swapon "$SWAP_FILE" 2>/dev/null; then
    grep -q "^${SWAP_FILE} " /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab
    ok "Swap 2 ГБ включён"
  else
    rm -f "$SWAP_FILE"
    warn "Хостинг не разрешает swap (swapon не сработал). Продолжаю без него."
  fi
}

check_resources() {
  STEP="проверка ресурсов"
  local mem_mb swap_mb disk_mb
  mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  swap_mb=$(awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  disk_mb=$(df -Pm / | awk 'NR == 2 {print $4}')

  (( disk_mb >= 3000 )) || die "На диске свободно ${disk_mb} МБ, нужно хотя бы 3 ГБ."
  (( mem_mb >= 900 )) || die "Всего ${mem_mb} МБ RAM: этого мало для Claude Code. Нужно от 2 ГБ, лучше 4 ГБ."
  if (( mem_mb + swap_mb < 3800 )); then
    add_swap "$mem_mb" "$disk_mb"
  fi
  ok "Ресурсы: RAM ${mem_mb} МБ, свободно на диске ${disk_mb} МБ"
}

wait_cloud_init() {
  STEP="ожидание cloud-init"
  command -v cloud-init >/dev/null 2>&1 || return 0
  local status
  status=$(cloud-init status 2>/dev/null) || true
  if grep -Eq 'status: (running|not run|not started)' <<<"$status"; then
    say "Хостинг ещё донастраивает сервер (cloud-init). Жду до 10 минут..."
    timeout 600 cloud-init status --wait >/dev/null 2>&1 || warn "cloud-init закончил с предупреждением. Продолжаю."
  fi
}

install_packages() {
  STEP="установка пакетов"
  say "Обновляю список пакетов и ставлю базовые утилиты..."
  apt_update
  apt_get install --no-install-recommends \
    ca-certificates curl gnupg sudo git tmux nano openssh-server \
    ufw fail2ban python3-systemd unattended-upgrades
  ok "Базовые пакеты установлены: git, tmux, curl, ufw, fail2ban"
}

check_anthropic_access() {
  STEP="проверка доступа к Anthropic"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 https://api.anthropic.com/v1/models 2>/dev/null) || code=000
  case "$code" in
    401|404|405) ok "API Anthropic доступен с этого сервера" ;;
    403) warn "api.anthropic.com ответил 403 на проверочный запрос. Установка продолжится; если Claude Code не сможет обратиться к API, уточните у хостинга ограничения исходящих соединений." ;;
    *) warn "Не удалось проверить доступ к api.anthropic.com (HTTP $code). Продолжаю." ;;
  esac
}

install_claude_code() {
  STEP="установка Claude Code"
  say "Подключаю официальный apt-репозиторий Anthropic и ставлю Claude Code..."
  install -d -m 0755 /etc/apt/keyrings

  local tmp_key gnupg_home fingerprint
  tmp_key=$(mktemp)
  gnupg_home=$(mktemp -d)
  curl -fsSL --retry 3 --max-time 60 "$CLAUDE_KEY_URL" -o "$tmp_key"
  fingerprint=$(GNUPGHOME="$gnupg_home" gpg --batch --show-keys --with-colons "$tmp_key" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print $10; exit}')
  rm -rf "$gnupg_home"
  if [[ "$fingerprint" != "$CLAUDE_KEY_FPR" ]]; then
    rm -f "$tmp_key"
    die "Отпечаток ключа Anthropic не совпал (ожидался $CLAUDE_KEY_FPR, получен ${fingerprint:-пусто}). Установка остановлена."
  fi
  install -m 0644 "$tmp_key" "$CLAUDE_KEY_FILE"
  rm -f "$tmp_key"

  printf 'deb [signed-by=%s] https://downloads.claude.ai/claude-code/apt/stable stable main\n' \
    "$CLAUDE_KEY_FILE" > "$CLAUDE_APT_LIST"
  apt_update
  apt_get install claude-code
  command -v claude >/dev/null 2>&1 || die "Пакет claude-code установился, но команды claude нет."
  ok "Claude Code установлен: $(claude --version 2>/dev/null | head -n 1)"
}

write_sudoers() {
  local file=$1 tmp
  tmp=$(mktemp)
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$USER_NAME" > "$tmp"
  visudo -cqf "$tmp" || { rm -f "$tmp"; die "visudo отклонил правило sudo."; }
  install -m 0440 "$tmp" "$file"
  rm -f "$tmp"
}

setup_user() {
  STEP="пользователь $USER_NAME"
  [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Недопустимое имя пользователя: $USER_NAME"
  [[ "$USER_NAME" != root ]] || die "Рабочий пользователь не может быть root."

  local public_key home
  public_key=$(printf '%s' "$KEY_B64" | base64 -d 2>/dev/null) || die "Не удалось декодировать SSH-ключ."
  case "$public_key" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp*) ;;
    *) die "Переданный SSH-ключ имеет неизвестный формат." ;;
  esac

  if id "$USER_NAME" >/dev/null 2>&1; then
    ok "Пользователь $USER_NAME уже есть"
  else
    useradd --create-home --shell /bin/bash "$USER_NAME"
    ok "Создан пользователь $USER_NAME"
  fi
  usermod -aG sudo "$USER_NAME"
  home=$(getent passwd "$USER_NAME" | cut -d: -f6)

  install -d -m 0700 -o "$USER_NAME" -g "$USER_NAME" "$home/.ssh"
  touch "$home/.ssh/authorized_keys"
  grep -qxF -- "$public_key" "$home/.ssh/authorized_keys" || printf '%s\n' "$public_key" >> "$home/.ssh/authorized_keys"
  chown "$USER_NAME:$USER_NAME" "$home/.ssh/authorized_keys"
  chmod 0600 "$home/.ssh/authorized_keys"
  ok "SSH-ключ добавлен пользователю $USER_NAME"

  # Passwordless sudo only for the rest of the installation; harden removes it.
  # The cleanup timer is armed first: no timer, no grant.
  arm_sudo_cleanup
  write_sudoers "$SUDOERS_INSTALL"

  if [[ "$SUDO_MODE" == nopasswd ]]; then
    write_sudoers "$SUDOERS_NOPASSWD"
    passwd -l "$USER_NAME" >/dev/null 2>&1 || true
    rm -f "$SUDO_PASSWORD_FILE"
    ok "sudo без пароля включён (CCV_SUDO=nopasswd)"
  else
    rm -f "$SUDOERS_NOPASSWD"
    if [[ "$(passwd -S "$USER_NAME" | awk '{print $2}')" != P ]]; then
      local password
      password=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-HJ-NP-Za-km-z2-9' | cut -c 1-20)
      printf '%s:%s\n' "$USER_NAME" "$password" | chpasswd
      ( umask 077; printf '%s\n' "$password" > "$SUDO_PASSWORD_FILE" )
      ok "Создан пароль для sudo (установщик сохранит его у вас на компьютере)"
    else
      ok "Пароль для sudo уже задан ранее, не меняю"
    fi
  fi

  install -d -m 0755 -o "$USER_NAME" -g "$USER_NAME" "$home/work"
  if [[ ! -e "$home/.tmux.conf" ]]; then
    cat > "$home/.tmux.conf" <<'EOF'
# Created by claude-code-vps.
set -g mouse on
set -g history-limit 50000
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",*256col*:Tc"
EOF
    chown "$USER_NAME:$USER_NAME" "$home/.tmux.conf"
  fi
}

prepare() {
  check_os
  check_resources
  wait_cloud_init
  install_packages
  check_anthropic_access
  install_claude_code
  setup_user
  STEP="готово"
  printf '\n[ OK ] Сервер подготовлен. Дальше установщик проверит вход под %s.\n' "$USER_NAME"
}

# ----------------------------------------------------------------- harden ----

reload_sshd() {
  local unit
  for unit in ssh.service sshd.service; do
    if systemctl is-active --quiet "$unit"; then
      systemctl reload "$unit"
      return 0
    fi
  done
  # Socket-activated sshd (Ubuntu 22.10+) reads the new config on its next start.
  return 0
}

harden_ssh() {
  STEP="защита SSH"
  local home
  home=$(getent passwd "$USER_NAME" | cut -d: -f6) || die "Пользователь $USER_NAME не найден. Сначала нужен этап prepare."
  [[ -s "$home/.ssh/authorized_keys" ]] || die "У $USER_NAME нет SSH-ключа: отключать вход по паролю опасно. Остановлено."

  grep -Eqi '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
    || die "В /etc/ssh/sshd_config нет строки «Include /etc/ssh/sshd_config.d/*.conf». Не трогаю SSH вслепую."

  # sshd -t/-T refuse to run without /run/sshd, which socket-activated setups may lack.
  install -d -m 0755 /run/sshd
  # Capture first: `sshd -T | grep -q` dies of SIGPIPE under pipefail.
  local kbd_option=KbdInteractiveAuthentication current
  current=$("$SSHD" -T 2>/dev/null) || true
  grep -qi '^kbdinteractiveauthentication ' <<<"$current" || kbd_option=ChallengeResponseAuthentication

  cat > "$SSHD_DROPIN" <<EOF
# Managed by claude-code-vps. Delete this file and reload ssh to undo.
PermitRootLogin no
PasswordAuthentication no
${kbd_option} no
PubkeyAuthentication yes
EOF
  chmod 0644 "$SSHD_DROPIN"

  if ! "$SSHD" -t; then
    rm -f "$SSHD_DROPIN"
    die "sshd отклонил новую конфигурацию. Изменения отменены, SSH работает как раньше."
  fi
  local effective
  effective=$("$SSHD" -T)
  if ! grep -qx 'permitrootlogin no' <<<"$effective" || ! grep -qx 'passwordauthentication no' <<<"$effective"; then
    rm -f "$SSHD_DROPIN"
    die "Другие настройки в /etc/ssh перекрывают защиту. Изменения отменены, проверьте /etc/ssh/sshd_config."
  fi
  reload_sshd
  ok "SSH: вход только по ключу, root по SSH не пускается"
}

# Every port sshd is reachable on: sshd_config, socket activation (Ubuntu 22.10+
# may listen through ssh.socket on a port sshd -T does not report) and the port
# the client is connected through right now.
ssh_ports() {
  {
    "$SSHD" -T 2>/dev/null | awk '$1 == "port" {print $2}' || true
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
      systemctl show -p Listen --value ssh.socket 2>/dev/null \
        | grep -oE ':[0-9]+ \(Stream\)' | grep -oE '[0-9]+' || true
    fi
    if [[ -n "$CLIENT_PORT" ]]; then printf '%s\n' "$CLIENT_PORT"; fi
  } | awk '$1 ~ /^[0-9]+$/ && $1 >= 1 && $1 <= 65535' | sort -un
}

setup_firewall() {
  STEP="брандмауэр UFW"
  local ports=() port
  mapfile -t ports < <(ssh_ports)
  (( ${#ports[@]} > 0 )) || ports=(22)

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for port in "${ports[@]}"; do
    ufw allow "${port}/tcp" comment 'SSH (claude-code-vps)' >/dev/null
  done
  ufw --force enable >/dev/null
  ok "UFW включён: снаружи открыт только SSH (порт ${ports[*]})"
}

setup_fail2ban() {
  STEP="fail2ban"
  local ports
  ports=$(ssh_ports | paste -sd, -)
  cat > "$F2B_JAIL" <<EOF
# Managed by claude-code-vps.
[sshd]
enabled  = true
backend  = systemd
port     = ${ports:-22}
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || true

  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if fail2ban-client status sshd >/dev/null 2>&1; then
      ok "fail2ban следит за SSH: 5 неудачных входов — бан на час"
      return 0
    fi
    sleep 1
  done
  warn "fail2ban не запустился. Это не критично; подробности: journalctl -u fail2ban -n 50"
}

setup_auto_updates() {
  STEP="автообновления"
  # Our file sorts after 20auto-upgrades, so it wins over an image that ships it disabled.
  cat > "$UU_CLAUDE" <<'EOF'
// Managed by claude-code-vps: automatic security updates, plus Claude Code
// from Anthropic's apt repo.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Origins-Pattern {
    "origin=Anthropic,codename=stable";
};
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
  local dump
  dump=$(apt-config dump 2>/dev/null || true)
  if grep -qx 'APT::Periodic::Unattended-Upgrade "1";' <<<"$dump" \
    && grep -qx 'APT::Periodic::Update-Package-Lists "1";' <<<"$dump"; then
    ok "Автообновления: обновления безопасности системы и Claude Code ставятся сами"
  else
    warn "Автообновления выключены другими файлами в /etc/apt/apt.conf.d (проверьте: apt-config dump | grep Periodic)."
  fi
}

# Removes the temporary sudo grant if the client never reaches harden: a timer one
# hour after prepare (disconnect, error) and a boot-time service (reboot).
arm_sudo_cleanup() {
  cat > "/etc/systemd/system/${SUDO_CLEANUP_UNIT}.service" <<EOF
# Managed by claude-code-vps: removes the temporary installation sudo rule.
[Unit]
Description=claude-code-vps: remove temporary installation sudo rule

[Service]
Type=oneshot
ExecStart=/bin/rm -f ${SUDOERS_INSTALL}

[Install]
WantedBy=multi-user.target
EOF
  cat > "/etc/systemd/system/${SUDO_CLEANUP_UNIT}.timer" <<EOF
# Managed by claude-code-vps: removes the temporary installation sudo rule.
[Unit]
Description=claude-code-vps: remove temporary installation sudo rule

[Timer]
OnActiveSec=1h
EOF
  if ! { systemctl daemon-reload \
      && systemctl enable "${SUDO_CLEANUP_UNIT}.service" >/dev/null 2>&1 \
      && systemctl restart "${SUDO_CLEANUP_UNIT}.timer"; }; then
    die "Не удалось включить очистку временного sudo (systemd). Остановлено, sudo не менялся."
  fi
}

disarm_sudo_cleanup() {
  systemctl stop "${SUDO_CLEANUP_UNIT}.timer" >/dev/null 2>&1 || true
  systemctl disable "${SUDO_CLEANUP_UNIT}.service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SUDO_CLEANUP_UNIT}.service" "/etc/systemd/system/${SUDO_CLEANUP_UNIT}.timer"
  systemctl daemon-reload || true
}

finish_sudo() {
  STEP="права sudo"
  rm -f "$SUDOERS_INSTALL" "$SUDO_PASSWORD_FILE"
  disarm_sudo_cleanup
  if [[ -e "$SUDOERS_NOPASSWD" ]]; then
    ok "sudo для $USER_NAME работает без пароля"
  else
    ok "sudo для $USER_NAME спрашивает пароль"
  fi
}

harden() {
  id "$USER_NAME" >/dev/null 2>&1 || die "Пользователь $USER_NAME не найден. Сначала нужен этап prepare."
  harden_ssh
  setup_firewall
  setup_fail2ban
  setup_auto_updates
  finish_sudo
  STEP="готово"
  printf '\n[ OK ] Защита включена.\n'
}

# ------------------------------------------------------------------- main ----

main() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "bootstrap.sh нужно запускать от root."
  local action=${1:-} api=${2:-}
  [[ "$api" == "$CCV_API" ]] || die "Версии установщика и bootstrap.sh не совпадают (${api:-нет} и $CCV_API). Подождите 5 минут (кэш GitHub) и запустите установщик ещё раз."

  install -d -m 0700 "$STATE_DIR"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
  printf '\n===== claude-code-vps %s %s =====\n' "$action" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  trap on_error ERR

  case "$action" in
    prepare)
      (( $# == 5 )) || die "Использование: bootstrap.sh prepare <api> <user> <key_b64> <sudo_mode>"
      USER_NAME=$3 KEY_B64=$4 SUDO_MODE=$5
      [[ "$SUDO_MODE" == password || "$SUDO_MODE" == nopasswd ]] || die "sudo_mode должен быть password или nopasswd."
      prepare
      ;;
    harden)
      (( $# == 3 || $# == 4 )) || die "Использование: bootstrap.sh harden <api> <user> [ssh_port]"
      USER_NAME=$3 CLIENT_PORT=${4:-}
      [[ -z "$CLIENT_PORT" || "$CLIENT_PORT" =~ ^[0-9]{1,5}$ ]] || CLIENT_PORT=""
      harden
      ;;
    *)
      die "Неизвестное действие: ${action:-пусто}. Ожидается prepare или harden."
      ;;
  esac
}

main "$@"
