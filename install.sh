#!/usr/bin/env bash
# claude-code-vps: one-command setup of Claude Code on your own Debian/Ubuntu VPS,
# plus a small helper for daily use. Runs on macOS, Linux and Git Bash.
#
#   curl -fsSL https://raw.githubusercontent.com/Djam36/claude-code-vps/main/install.sh | bash
#
# After setup the same script is installed as `claude-vps`:
#   claude-vps login         browser through the VPS + Claude Code login
#   claude-vps browser [url] only the browser through the VPS (SOCKS5 over SSH)
#   claude-vps open <port>   open a site that runs on the VPS (SSH port forwarding)
#   claude-vps attach        tmux session on the VPS that survives disconnects
#   claude-vps setup         run the installation again
#
# Nothing graphical is installed on the server: the browser runs on your computer
# and only its traffic goes through the server via `ssh -D` (dynamic port forwarding).

set -Eeuo pipefail

readonly CCV_VERSION="1.0.0"
readonly CCV_API=1
readonly BASE_URL="${CCV_BASE_URL:-https://raw.githubusercontent.com/Djam36/claude-code-vps/main}"
# The alias chosen at setup is remembered, so daily commands find the same server.
ALIAS="${CCV_ALIAS:-$(cat "${HOME}/.claude-vps/alias" 2>/dev/null || true)}"
readonly ALIAS="${ALIAS:-claude-vps}"
readonly WORK_USER="${CCV_USER:-dev}"
readonly ADMIN_USER="${CCV_ADMIN_USER:-root}"
readonly SUDO_MODE="${CCV_SUDO:-password}"
readonly CCV_HOME="${HOME}/.claude-vps"
readonly SSH_DIR="${HOME}/.ssh"
readonly KEY_PATH="${SSH_DIR}/claude_vps_ed25519"
readonly SSH_CONFIG="${SSH_DIR}/config"
readonly BIN_DIR="${HOME}/.local/bin"
readonly LOGIN_URL="https://claude.ai/login"
readonly SELF="${BASH_SOURCE[0]:-}"

HOST="${CCV_HOST:-}"
PORT="${CCV_PORT:-}"
BOOTSTRAP=""
SOCKS_PORT=""
TUNNEL_PID=""
SUDO_PASSWORD_PATH=""
TMP_FILES=()
SSH_BASE=()

if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_RESET=""
fi

info() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%sВнимание:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%sОшибка:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

cleanup() {
  stop_tunnel
  local file
  for file in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do
    rm -f -- "$file"
  done
}
trap cleanup EXIT

need() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда '$1'. Установите OpenSSH Client и curl, затем запустите ещё раз."
}

tty_read() {
  # Reads from the terminal even when the script itself arrives via `curl | bash`.
  local prompt=$1 answer
  tty_in || die "Нет интерактивного терминала. Запустите команду в обычном окне терминала."
  read -r -p "$prompt" answer </dev/tty
  printf '%s' "$answer"
}

# True when the controlling terminal can actually be opened (not just exists).
tty_in() {
  { : </dev/tty; } 2>/dev/null
}

tty_or_null() {
  if tty_in; then printf '/dev/tty'; else printf '/dev/null'; fi
}

usage() {
  cat <<EOF
claude-vps ${CCV_VERSION} — Claude Code на вашем VPS без рабочего стола на сервере.

  claude-vps setup          установить или перенастроить сервер
  claude-vps login          браузер через сервер + вход в Claude Code
  claude-vps browser [url]  только браузер, который ходит в интернет через сервер
  claude-vps open <порт>    открыть сайт, запущенный на сервере (например 3000)
  claude-vps attach         сессия tmux на сервере, которая переживает обрывы связи
  claude-vps help           эта справка

Подключение по SSH: ssh ${ALIAS}
Документация: https://github.com/Djam36/claude-code-vps
EOF
}

# ------------------------------------------------------------------ setup ----

collect_input() {
  printf '\n%sclaude-code-vps %s%s — Claude Code на вашем VPS\n' "$C_BOLD" "$CCV_VERSION" "$C_RESET"
  printf 'Сервер: Debian 11+ или Ubuntu 20.04+, доступ root (обычно пароль из панели хостинга).\n'

  if [[ -z "$HOST" ]]; then
    HOST=$(tty_read $'\nIP-адрес или домен сервера: ')
  fi
  HOST=${HOST// /}
  [[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "Введите IPv4-адрес или домен без http://, пробелов и лишних символов."

  if [[ -z "$PORT" ]]; then
    PORT=$(tty_read 'SSH-порт [22]: ')
    PORT=${PORT:-22}
  fi
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && PORT=$((10#$PORT)) && (( PORT >= 1 && PORT <= 65535 )) || die "SSH-порт должен быть числом от 1 до 65535."
  [[ "$WORK_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$WORK_USER" != root ]] || die "CCV_USER: недопустимое имя пользователя '$WORK_USER'."
  [[ "$SUDO_MODE" == password || "$SUDO_MODE" == nopasswd ]] || die "CCV_SUDO может быть только password или nopasswd."

  SSH_BASE=(-p "$PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
            -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=10)
}

ensure_key() {
  mkdir -p "$SSH_DIR"
  chmod 0700 "$SSH_DIR"
  if [[ -f "$KEY_PATH" && ! -f "${KEY_PATH}.pub" ]]; then
    die "Есть приватный ключ без публичной части: $KEY_PATH. Перезаписывать его не буду."
  fi
  if [[ -f "$KEY_PATH" ]]; then
    ok "Использую существующий ключ $KEY_PATH"
  else
    ssh-keygen -q -t ed25519 -a 64 -N "" -C "claude-vps" -f "$KEY_PATH"
    ok "Создан отдельный SSH-ключ $KEY_PATH"
  fi
  chmod 0600 "$KEY_PATH"
}

key_login_ok() {
  ssh -n "${SSH_BASE[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$1@$HOST" true >/dev/null 2>&1
}

push_key() {
  local pub
  pub=$(tr -d '\r\n' < "${KEY_PATH}.pub")
  [[ "$pub" != *"'"* ]] || die "Неожиданный формат публичного ключа."
  info "Шаг 1/5. Добавляю ключ на сервер."
  printf 'Сервер один раз спросит пароль %s. При вводе пароля символы не отображаются — это нормально.\n' "$ADMIN_USER"
  printf 'Если SSH спросит про отпечаток сервера (fingerprint), ответьте yes.\n\n'
  ssh -n -p "$PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "$ADMIN_USER@$HOST" \
    "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys)" \
    || die "Не удалось войти как $ADMIN_USER. Проверьте IP, порт и пароль в панели хостинга."
  ok "Ключ добавлен"
}

fetch_bootstrap() {
  local dir=""
  [[ -n "$SELF" && -f "$SELF" ]] && dir=$(cd "$(dirname "$SELF")" && pwd)
  if [[ -n "$dir" && -f "$dir/bootstrap.sh" ]]; then
    BOOTSTRAP="$dir/bootstrap.sh"
  else
    BOOTSTRAP=$(mktemp "${TMPDIR:-/tmp}/ccv-bootstrap.XXXXXX")
    TMP_FILES+=("$BOOTSTRAP")
    curl -fsSL --retry 3 "${BASE_URL}/bootstrap.sh?v=${CCV_VERSION}" -o "$BOOTSTRAP" \
      || die "Не удалось скачать bootstrap.sh с ${BASE_URL}."
  fi
  head -n 1 "$BOOTSTRAP" | grep -q '^#!/usr/bin/env bash' || die "bootstrap.sh скачался повреждённым."
  grep -q "^readonly CCV_API=${CCV_API}\$" "$BOOTSTRAP" \
    || die "Версии install.sh и bootstrap.sh не совпадают. Подождите 5 минут (кэш GitHub) и повторите."
}

run_phase() {
  local user=$1 phase=$2
  shift 2
  local sudo_cmd="sudo"
  [[ "$user" == root ]] && sudo_cmd=""
  scp -q -P "$PORT" -i "$KEY_PATH" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    "$BOOTSTRAP" "$user@$HOST:.ccv-bootstrap.sh" || die "Не удалось передать bootstrap.sh на сервер."
  ssh -t "${SSH_BASE[@]}" "$user@$HOST" \
    "sed -i 's/\r\$//' .ccv-bootstrap.sh; $sudo_cmd bash .ccv-bootstrap.sh $phase $CCV_API $*; rc=\$?; rm -f .ccv-bootstrap.sh; exit \$rc" \
    <"$(tty_or_null)"
}

verify_work_login() {
  info "Шаг 4/5. Проверяю вход под $WORK_USER по ключу..."
  local out password
  out=$(ssh -n "${SSH_BASE[@]}" -o BatchMode=yes "$WORK_USER@$HOST" \
    'printf CCV_LOGIN_OK; sudo -n cat /var/lib/claude-vps/sudo-password 2>/dev/null || true') \
    || die "Вход под $WORK_USER не прошёл. Root и пароли пока НЕ отключены — исправьте причину и запустите установщик снова."
  [[ "$out" == CCV_LOGIN_OK* ]] || die "Сервер ответил неожиданно при проверке входа."
  ok "Вход под $WORK_USER работает"

  password=${out#CCV_LOGIN_OK}
  password=${password//$'\r'/}
  password=${password//$'\n'/}
  if [[ -n "$password" ]]; then
    mkdir -p "$CCV_HOME"
    chmod 0700 "$CCV_HOME"
    SUDO_PASSWORD_PATH="$CCV_HOME/sudo-password-${ALIAS}.txt"
    ( umask 077; printf '%s\n' "$password" > "$SUDO_PASSWORD_PATH" )
    ok "Пароль sudo сохранён: $SUDO_PASSWORD_PATH"
  fi
}

write_ssh_config() {
  local begin="# >>> claude-code-vps: ${ALIAS} >>>"
  local end="# <<< claude-code-vps: ${ALIAS} <<<"
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ccv-ssh-config.XXXXXX")
  TMP_FILES+=("$tmp")
  touch "$SSH_CONFIG"

  # Our block goes first so `Host *` sections below cannot override it.
  # The trailing `Host *` returns any global options that follow to global scope.
  {
    printf '%s\n' "$begin"
    printf 'Host %s\n' "$ALIAS"
    printf '    HostName %s\n' "$HOST"
    printf '    User %s\n' "$WORK_USER"
    printf '    Port %s\n' "$PORT"
    printf '    IdentityFile ~/.ssh/claude_vps_ed25519\n'
    printf '    IdentitiesOnly yes\n'
    printf '    ServerAliveInterval 30\n'
    printf '    ServerAliveCountMax 6\n'
    printf 'Host *\n'
    printf '%s\n\n' "$end"
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip = 1; next }
      $0 == end   { skip = 0; drop_blank = 1; next }
      skip        { next }
      drop_blank && $0 == "" { drop_blank = 0; next }
      { drop_blank = 0; print }
    ' "$SSH_CONFIG"
  } > "$tmp"

  cat "$tmp" > "$SSH_CONFIG"
  chmod 0600 "$SSH_CONFIG"
  ssh -G "$ALIAS" >/dev/null 2>&1 || die "Получившийся ~/.ssh/config не прошёл проверку ssh -G."
  ok "В ~/.ssh/config добавлено подключение '$ALIAS' (ssh $ALIAS)"
}

shell_rc_file() {
  case "$(basename "${SHELL:-bash}")" in
    zsh) printf '%s' "$HOME/.zshrc" ;;
    bash) if [[ "$(uname -s)" == Darwin ]]; then printf '%s' "$HOME/.bash_profile"; else printf '%s' "$HOME/.bashrc"; fi ;;
    *) printf '%s' "$HOME/.profile" ;;
  esac
}

install_helper() {
  local target="$BIN_DIR/claude-vps"
  mkdir -p "$BIN_DIR" "$CCV_HOME"
  chmod 0700 "$CCV_HOME"
  printf '%s\n' "$ALIAS" > "$CCV_HOME/alias"
  if [[ -n "$SELF" && -f "$SELF" ]]; then
    if [[ "$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" != "$target" ]]; then
      cp "$SELF" "$target"
    fi
  else
    curl -fsSL --retry 3 "${BASE_URL}/install.sh?v=${CCV_VERSION}" -o "$target" \
      || { warn "Не удалось скачать команду claude-vps. Её можно поставить позже повторным запуском установщика."; return 0; }
  fi
  chmod 0755 "$target"

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      local rc
      rc=$(shell_rc_file)
      if ! grep -qs '# claude-code-vps PATH' "$rc"; then
        printf '\nexport PATH="$HOME/.local/bin:$PATH"  # claude-code-vps PATH\n' >> "$rc"
      fi
      warn "Команда claude-vps заработает в новом окне терминала (PATH дописан в $rc)."
      ;;
  esac
  ok "Установлена команда claude-vps ($target)"
}

summary() {
  printf '\n%s%sГотово! Сервер настроен.%s\n\n' "$C_GREEN" "$C_BOLD" "$C_RESET"
  printf '  Терминал на сервере:   ssh %s\n' "$ALIAS"
  printf '  VS Code:               Remote-SSH → Connect to Host → %s\n' "$ALIAS"
  printf '  Вход в Claude Code:    claude-vps login\n'
  printf '  Сайт с сервера:        claude-vps open 3000\n'
  printf '  Долгая сессия (tmux):  claude-vps attach\n'
  if [[ -n "$SUDO_PASSWORD_PATH" ]]; then
    printf '  Пароль для sudo:       %s\n' "$SUDO_PASSWORD_PATH"
  fi
  printf '\nВход root и вход по паролю на сервере теперь отключены. Ключ: %s — не теряйте его.\n' "$KEY_PATH"
}

cmd_setup() {
  need ssh; need scp; need ssh-keygen; need curl
  collect_input
  ensure_key

  local conn
  if key_login_ok "$WORK_USER"; then
    conn=$WORK_USER
    ok "Ключ уже подходит для $WORK_USER — это повторная установка"
    [[ "$SUDO_MODE" == password ]] && printf 'Если сервер спросит пароль sudo — он в файле %s\n' "$CCV_HOME/sudo-password-${ALIAS}.txt"
  elif key_login_ok "$ADMIN_USER"; then
    conn=$ADMIN_USER
    ok "Ключ уже подходит для $ADMIN_USER"
  else
    push_key
    key_login_ok "$ADMIN_USER" || die "Ключ добавлен, но вход по нему не работает. Проверьте /root/.ssh на сервере."
    conn=$ADMIN_USER
  fi

  info "Шаг 2/5. Загружаю серверный скрипт..."
  fetch_bootstrap
  ok "bootstrap.sh готов"

  info "Шаг 3/5. Настраиваю сервер: пакеты, Claude Code, пользователь $WORK_USER (обычно 2–5 минут)..."
  run_phase "$conn" prepare "$WORK_USER" "$(base64 < "${KEY_PATH}.pub" | tr -d '\r\n')" "$SUDO_MODE" \
    || die "Подготовка сервера не завершилась. Текст ошибки выше; журнал на сервере: /var/log/claude-vps-install.log"

  verify_work_login

  info "Шаг 5/5. Включаю защиту: SSH только по ключу, UFW, fail2ban, автообновления..."
  # The remote shell expands SSH_CONNECTION: UFW must keep the port we are connected through open.
  run_phase "$WORK_USER" harden "$WORK_USER" '${SSH_CONNECTION##* }' \
    || die "Защита не включилась. Текст ошибки выше; журнал на сервере: /var/log/claude-vps-install.log"
  key_login_ok "$WORK_USER" || die "После включения защиты вход под $WORK_USER не проверился. Откройте консоль в панели хостинга и проверьте /etc/ssh/sshd_config.d/00-claude-vps.conf."

  write_ssh_config
  install_helper
  summary

  local answer
  answer=$(tty_read $'\nВойти в Claude Code сейчас? [Y/n]: ')
  case "$answer" in
    n|N|н|Н|no|нет) printf 'Позже: claude-vps login\n' ;;
    *) cmd_login ;;
  esac
}

# ---------------------------------------------------------------- tunnels ----

require_alias() {
  grep -qsF "# >>> claude-code-vps: ${ALIAS} >>>" "$SSH_CONFIG" \
    || die "Подключение '$ALIAS' не найдено в ~/.ssh/config. Сначала выполните установку: claude-vps setup"
}

port_busy() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

pick_port() {
  local port
  for port in $(seq "$1" "$2"); do
    if ! port_busy "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

stop_tunnel() {
  if [[ -n "$TUNNEL_PID" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
  fi
}

# Starts `ssh -N <forward> <alias>` in the background and waits until the local port listens.
start_tunnel() {
  local local_port=$1
  shift
  ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes "$@" "$ALIAS" </dev/null &
  TUNNEL_PID=$!
  local _
  for _ in $(seq 1 40); do
    port_busy "$local_port" && return 0
    kill -0 "$TUNNEL_PID" 2>/dev/null || { TUNNEL_PID=""; die "SSH-туннель не поднялся. Проверьте: ssh $ALIAS"; }
    sleep 0.5
  done
  die "SSH-туннель не ответил за 20 секунд. Проверьте: ssh $ALIAS"
}

start_socks() {
  require_alias
  SOCKS_PORT=$(pick_port 1080 1099) || die "Локальные порты 1080–1099 заняты. Закройте старые туннели и повторите."
  start_tunnel "$SOCKS_PORT" -D "127.0.0.1:${SOCKS_PORT}"
  local ip
  if ip=$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null); then
    ok "Туннель поднят: браузер будет выходить в интернет с IP сервера ${ip}"
  else
    ok "Туннель поднят на 127.0.0.1:${SOCKS_PORT}"
  fi
}

firefox_profile() {
  local dir="$CCV_HOME/browser/firefox-${SOCKS_PORT}"
  mkdir -p "$dir"
  cat > "$dir/user.js" <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", ${SOCKS_PORT});
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "");
user_pref("media.peerconnection.enabled", false);
user_pref("browser.shell.checkDefaultBrowser", false);
EOF
  printf '%s' "$dir"
}

manual_browser_hint() {
  local url=$1
  warn "Не нашёл Chrome, Edge, Chromium, Brave, Yandex или Firefox для автоматического запуска."
  printf 'Настройте прокси вручную в любом браузере: SOCKS5, адрес 127.0.0.1, порт %s,\n' "$SOCKS_PORT"
  printf 'включите «DNS через прокси» (в Firefox: Proxy DNS when using SOCKS v5). Затем откройте %s\n' "$url"
}

# Launches a separate browser profile whose traffic goes through the SOCKS tunnel.
launch_browser() {
  local url=$1
  mkdir -p "$CCV_HOME/browser"
  local profile="$CCV_HOME/browser/chromium-${SOCKS_PORT}"
  local proxy="socks5://127.0.0.1:${SOCKS_PORT}"
  local -a chromium_flags=(
    "--proxy-server=${proxy}"
    "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"
    "--no-first-run" "--no-default-browser-check" "--new-window"
  )

  case "$(uname -s)" in
    Darwin)
      local app
      for app in "Google Chrome" "Chromium" "Microsoft Edge" "Brave Browser" "Yandex" "Vivaldi"; do
        if [[ -d "/Applications/${app}.app" || -d "$HOME/Applications/${app}.app" ]]; then
          open -na "$app" --args "--user-data-dir=${profile}" "${chromium_flags[@]}" "$url"
          ok "Открыт ${app} в отдельном профиле через сервер"
          return 0
        fi
      done
      if [[ -d "/Applications/Firefox.app" ]]; then
        open -na Firefox --args -profile "$(firefox_profile)" -no-remote "$url"
        ok "Открыт Firefox в отдельном профиле через сервер"
        return 0
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      local exe candidate
      for candidate in \
        "${PROGRAMFILES:-C:\\Program Files}\\Google\\Chrome\\Application\\chrome.exe" \
        "${LOCALAPPDATA:-}\\Google\\Chrome\\Application\\chrome.exe" \
        "${PROGRAMFILES:-C:\\Program Files} (x86)\\Microsoft\\Edge\\Application\\msedge.exe" \
        "${PROGRAMFILES:-C:\\Program Files}\\Microsoft\\Edge\\Application\\msedge.exe"; do
        exe=$(cygpath -u "$candidate" 2>/dev/null) || continue
        if [[ -f "$exe" ]]; then
          "$exe" "--user-data-dir=$(cygpath -w "$profile")" "${chromium_flags[@]}" "$url" >/dev/null 2>&1 &
          disown || true
          ok "Открыт $(basename "$exe") в отдельном профиле через сервер"
          return 0
        fi
      done
      ;;
    *)
      if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        warn "В WSL браузер автоматически не запускается. Удобнее установщик для PowerShell (см. README)."
        manual_browser_hint "$url"
        return 0
      fi
      local bin
      for bin in google-chrome google-chrome-stable chromium chromium-browser microsoft-edge \
                 microsoft-edge-stable brave-browser yandex-browser vivaldi; do
        if command -v "$bin" >/dev/null 2>&1; then
          nohup "$bin" "--user-data-dir=${profile}" "${chromium_flags[@]}" "$url" >/dev/null 2>&1 &
          disown || true
          ok "Открыт ${bin} в отдельном профиле через сервер"
          return 0
        fi
      done
      if command -v firefox >/dev/null 2>&1; then
        nohup firefox -profile "$(firefox_profile)" -no-remote "$url" >/dev/null 2>&1 &
        disown || true
        ok "Открыт Firefox в отдельном профиле через сервер"
        return 0
      fi
      ;;
  esac
  manual_browser_hint "$url"
}

open_local_url() {
  local url=$1
  case "$(uname -s)" in
    Darwin) open "$url" ;;
    MINGW*|MSYS*|CYGWIN*) start "" "$url" 2>/dev/null || cmd.exe /c start "" "$url" ;;
    *) xdg-open "$url" >/dev/null 2>&1 || printf 'Откройте в браузере: %s\n' "$url" ;;
  esac
}

wait_enter() {
  tty_read "$1" >/dev/null || true
}

# --------------------------------------------------------------- commands ----

cmd_login() {
  need ssh; need curl
  info "Вход в Claude Code"
  start_socks
  launch_browser "$LOGIN_URL"
  cat <<EOF

Как войти:
  1. В открывшемся окне браузера войдите в свой аккаунт Claude.
     Это окно ходит в интернет через ваш сервер, поэтому claude.ai его пускает.
  2. Ниже запустится Claude Code на сервере. Выберите тему, затем
     «Claude account with subscription».
  3. Claude Code покажет ссылку. Нажмите c (скопировать) или выделите её мышью
     и откройте в ТОМ ЖЕ окне браузера, что открылось на шаге 1.
  4. Нажмите Authorize, скопируйте показанный код и вставьте его в терминал
     в строку «Paste code here». Затем Enter.
  5. Проверка: команда /status. Выход из Claude Code: /exit.

EOF
  wait_enter "Нажмите Enter, чтобы запустить Claude Code на сервере..."
  ssh -t "$ALIAS" 'cd ~/work 2>/dev/null; claude' <"$(tty_or_null)" || true
  stop_tunnel
  ok "Туннель закрыт. Дальше работайте через VS Code или ssh ${ALIAS}"
}

cmd_browser() {
  need ssh; need curl
  local url=${1:-$LOGIN_URL}
  start_socks
  launch_browser "$url"
  printf '\nПока это окно открыто, браузер ходит в интернет через сервер.\n'
  printf 'Сюда можно вставить ссылку входа из расширения Claude Code в VS Code.\n'
  wait_enter "Нажмите Enter, чтобы закрыть туннель..."
  stop_tunnel
  ok "Туннель закрыт"
}

cmd_open() {
  need ssh
  require_alias
  local remote_port=${1:-}
  [[ "$remote_port" =~ ^[0-9]+$ ]] && (( remote_port >= 1 && remote_port <= 65535 )) \
    || die "Укажите порт сайта на сервере, например: claude-vps open 3000"
  local local_port
  local_port=$(pick_port "$remote_port" "$((remote_port + 20))") || die "Локальные порты ${remote_port}–$((remote_port + 20)) заняты."
  start_tunnel "$local_port" -L "127.0.0.1:${local_port}:127.0.0.1:${remote_port}"
  local url="http://127.0.0.1:${local_port}"
  ok "Порт ${remote_port} сервера доступен у вас по адресу ${url}"
  open_local_url "$url" || true
  wait_enter "Нажмите Enter, чтобы закрыть проброс порта..."
  stop_tunnel
}

cmd_attach() {
  need ssh
  require_alias
  ssh -t "$ALIAS" 'tmux new-session -A -s claude' <"$(tty_or_null)"
}

main() {
  local command=${1:-setup}
  [[ $# -gt 0 ]] && shift
  case "$command" in
    setup|install) cmd_setup ;;
    login) cmd_login ;;
    browser) cmd_browser "$@" ;;
    open) cmd_open "$@" ;;
    attach) cmd_attach ;;
    version|--version|-v) printf 'claude-vps %s\n' "$CCV_VERSION" ;;
    help|--help|-h) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
