# Простой гайд: Свой защищенный API для Claude и Codex (OMP Gateway)

Этот гайд поможет вам настроить собственный сервер (VPS), который будет хранить ваши подписки на Claude и Codex и предоставлять к ним безопасный доступ с любых ваших устройств (Windows, Mac, OpenClaw).

**Простыми словами:**
*   **Брокер (Broker)** — это "сейф" на сервере. Он хранит ваши логины и пароли (OAuth-токены) от нейросетей.
*   **Шлюз (Gateway)** — это "окошко выдачи". Вы даете ему один секретный ключ, а он сам решает, к какой нейросети обратиться.
*   **Зачем это нужно?** Чтобы не вводить пароли от нейросетей на каждом устройстве и не бояться, что они утекут. Все устройства подключаются к вашему серверу через один защищенный канал.

---

## Архитектура

Ваш компьютер/телефон подключается к серверу по его публичному IP-адресу.

```text
Ваши устройства (OMP, OpenClaw)
  -> Секретный ключ (Gateway Token)
  -> OMP Auth Gateway (Порт 4000 на <IP_VPS>)
       -> Обращается к Брокеру (Порт 8765 на <IP_VPS>)
            -> Брокер использует сохраненные доступы
                 -> Anthropic (Claude)
                 -> OpenAI (Codex)
```

---

## Шаг 1. Создание отдельного пользователя (Безопасность)

Мы не будем запускать всё от имени администратора (root). Если программу взломают, хакер не получит полный контроль над сервером.

Выполните в консоли сервера:

```bash
# Создаем пользователя claude-gateway без прав администратора
sudo adduser \
  --system \
  --group \
  --home /var/lib/claude-gateway \
  --shell /bin/bash \
  claude-gateway

# Закрываем его домашнюю папку от посторонних глаз
sudo chmod 700 /var/lib/claude-gateway
```

---

## Шаг 2. Установка OMP

Теперь переключаемся в этого пользователя и ставим саму программу.

```bash
# Переключаемся в пользователя
sudo -iu claude-gateway

# Скачиваем установщик
umask 077
installer="$(mktemp)"
curl -fsSL https://raw.githubusercontent.com/can1357/oh-my-pi/main/scripts/install.sh -o "$installer"

# Устанавливаем (флаг --binary скачает готовую программу)
sh "$installer" --binary

# Проверяем, что всё работает
"$HOME/.local/bin/omp" --version
```

---

## Шаг 3. Настройка "Сейфа" (Брокера)

Брокер будет слушать порт **8765**. Он не использует сложные сети, он просто слушает IP-адрес вашего сервера.

1. Создаем папки для хранения данных:
   ```bash
   mkdir -p "$HOME/.omp" "$HOME/.cache"
   chmod 700 "$HOME/.omp" "$HOME/.cache"
   ```

2. Генерируем секретные токены (пароли):
   ```bash
   # Токен для связи между Брокером и Шлюзом
   "$HOME/.local/bin/omp" auth-broker token >/dev/null
   # Токен для подключения ваших устройств к Шлюзу
   "$HOME/.local/bin/omp" auth-gateway token >/dev/null
   ```
   *Запомните: эти токены нужно будет вставить в настройки ваших программ на Windows/Mac.*

---

## Шаг 4. Добавление доступов (Самое важное!)

Нам нужно "скормить" брокеру ваши аккаунты Claude и Codex.

### Claude (Anthropic)
Здесь есть нюанс: сервер не может открыть браузер. Мы используем "туннель", чтобы браузер на вашем компьютере думал, что он работает на сервере.

1. **На вашем компьютере** (Windows/Mac) откройте терминал и выполните:
   ```bash
   # Замените <IP_VPS> на реальный IP вашего сервера
   ssh -L 127.0.0.1:54545:127.0.0.1:54545 root@<IP_VPS>
   ```
2. **В открывшемся окне SSH** (вы на сервере) выполните:
   ```bash
   sudo -iu claude-gateway
   "$HOME/.local/bin/omp" auth-broker login anthropic
   ```
3. Ссылка, которую выдаст программа, откроется в браузере на вашем компьютере. Войдите в аккаунт. Доступ сохранится на сервере.

### Codex (OpenAI)
Из-за региональных ограничений новая авторизация через браузер на сервере может не сработать. Мы просто **скопируем** уже работающий доступ с вашего домашнего компьютера.

1. Убедитесь, что у вас на домашнем ПК уже работает Codex через OMP.
2. На сервере выполните:
   ```bash
   sudo -iu claude-gateway
   # Сначала смотрим, что будет скопировано (Dry Run)
   "$HOME/.local/bin/omp" auth-broker migrate --from-local --include-oauth --dry-run
   # Если всё верно, копируем по-настоящему
   "$HOME/.local/bin/omp" auth-broker migrate --from-local --include-oauth
   ```

---

## Шаг 5. Настройка "Окошка выдачи" (Шлюза)

Шлюз слушает порт **4000**. Он принимает запросы от ваших устройств и перенаправляет их Брокеру.

Запускаем его вручную для проверки (вместо `<IP_VPS>` подставьте IP сервера):

```bash
sudo -iu claude-gateway
OMP_AUTH_BROKER_URL=http://<IP_VPS>:8765 \
  "$HOME/.local/bin/omp" auth-gateway serve --bind=<IP_VPS>:4000
```

Если ошибок нет, нажимаем `Ctrl+C` и переходим к автозапуску.

---

## Шаг 6. Автозапуск и Защита (UFW)

Чтобы сервисы запускались сами при включении сервера и пережили перезагрузки, мы используем `systemd`.
Так как мы убрали Tailscale, порты 4000 и 8765 будут смотреть в интернет. **Защита держится на ваших секретных токенах.** Дополнительно мы настроим файрвол (UFW).

Ниже приведен **Bash-скрипт**, который сделает всю грязную работу по созданию служб и настройке UFW за вас.

---

## 🤖 Скрипт автоматической настройки

Сохраните этот код в файл `setup_omp.sh` на вашем сервере, сделайте его исполняемым (`chmod +x setup_omp.sh`) и запустите с правами root (`sudo ./setup_omp.sh`).

Скрипт сам определит IP вашего сервера (или вы можете передать его как аргумент: `sudo ./setup_omp.sh 123.45.67.89`).

```bash
#!/bin/bash
# Скрипт автоматической настройки OMP Gateway + Broker для VPS (Ubuntu/Debian)
# Запуск: sudo ./setup_omp.sh [IP_VPS]

set -e # Останавливать скрипт при ошибках

# Проверка прав
if [ "$EUID" -ne 0 ]; then
  echo "❌ Ошибка: Запустите скрипт с правами root (sudo)."
  exit 1
fi

# Получение IP
IP_VPS=${1:-$(curl -s ifconfig.me)}
echo "🚀 Настраиваем OMP Gateway на IP: $IP_VPS"

USER="claude-gateway"
HOME_DIR="/var/lib/$USER"
OMP_BIN="$HOME_DIR/.local/bin/omp"

# 1. Создание пользователя (если нет)
if ! id -u $USER >/dev/null 2>&1; then
    echo "👤 Создаем пользователя $USER..."
    adduser --system --group --home $HOME_DIR --shell /bin/bash $USER
    chmod 700 $HOME_DIR
fi

# 2. Установка OMP
echo "📦 Устанавливаем OMP..."
sudo -u $USER -H bash -c "
    umask 077
    mkdir -p \$HOME/.omp \$HOME/.cache
    chmod 700 \$HOME/.omp \$HOME/.cache
    if [ ! -f \$HOME/.local/bin/omp ]; then
        installer=\$(mktemp)
        curl -fsSL https://raw.githubusercontent.com/can1357/oh-my-pi/main/scripts/install.sh -o \"\$installer\"
        sh \"\$installer\" --binary
    fi
    # Генерация токенов (если их еще нет в базе)
    \$HOME/.local/bin/omp auth-broker token >/dev/null || true
    \$HOME/.local/bin/omp auth-gateway token >/dev/null || true
"

# 3. Создание systemd служб
echo "⚙️ Настраиваем автозапуск (systemd)..."

# --- Broker Service ---
cat > /etc/systemd/system/omp-auth-broker.service <<EOF
[Unit]
Description=OMP Auth Broker
After=network.target

[Service]
Type=simple
User=$USER
Group=$USER
ExecStart=$OMP_BIN auth-broker serve --bind=$IP_VPS:8765
Restart=on-failure
RestartSec=5

# Безопасность (Hardening)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
CapabilityBoundingSet=
UMask=0077
ReadWritePaths=$HOME_DIR/.omp $HOME_DIR/.cache
Environment="HOME=$HOME_DIR"
Environment="XDG_CACHE_HOME=$HOME_DIR/.cache"

[Install]
WantedBy=multi-user.target
EOF

# --- Gateway Service ---
cat > /etc/systemd/system/omp-auth-gateway.service <<EOF
[Unit]
Description=OMP Auth Gateway
After=network.target omp-auth-broker.service
Requires=omp-auth-broker.service

[Service]
Type=simple
User=$USER
Group=$USER
Environment="OMP_AUTH_BROKER_URL=http://$IP_VPS:8765"
ExecStart=$OMP_BIN auth-gateway serve --bind=$IP_VPS:4000
Restart=on-failure
RestartSec=5

# Безопасность (Hardening)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
CapabilityBoundingSet=
UMask=0077
ReadWritePaths=$HOME_DIR/.omp $HOME_DIR/.cache
Environment="HOME=$HOME_DIR"
Environment="XDG_CACHE_HOME=$HOME_DIR/.cache"

[Install]
WantedBy=multi-user.target
EOF

# 4. Активация служб
systemctl daemon-reload
systemctl enable --now omp-auth-broker.service
systemctl enable --now omp-auth-gateway.service

# 5. Настройка UFW (Файрвол)
echo "🛡️ Настраиваем UFW..."
ufw allow ssh >/dev/null 2>&1 || true
# Внимание: Порты открываются для всех. Защита обеспечивается Bearer-токенами.
ufw allow 4000/tcp >/dev/null 2>&1 || true
ufw allow 8765/tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

echo "✅ Установка завершена!"
echo ""
echo "📋 Что делать дальше:"
echo "1. Добавьте доступы (OAuth) согласно инструкции (Шаг 4)."
echo "2. После добавления доступов ОБЯЗАТЕЛЬНО перезапустите шлюз:"
echo "   sudo systemctl restart omp-auth-gateway.service"
echo ""
echo "🔑 Ваши токены хранятся в базе OMP. Чтобы узнать Gateway Token для клиента:"
echo "   sudo -u $USER $OMP_BIN auth-gateway token"
```

---

## Шаг 7. Подключение клиентов (Windows / OpenClaw)

После того как скрипт отработал и вы добавили OAuth-доступы (Шаг 4), ваш сервер готов.

1.  **Узнайте Gateway Token:**
    Выполните на сервере:
    ```bash
    sudo -u claude-gateway /var/lib/claude-gateway/.local/bin/omp auth-gateway token
    ```
    Скопируйте длинную строку, которую выдаст команда.

2.  **Настройка OMP на Windows:**
    В файле конфигурации (например, `models.yml`) укажите провайдеры:
    ```yaml
    providers:
      - name: claude-vps
        type: anthropic
        base_url: http://<IP_VPS>:4000/v1
        api_key: "ВАШ_GATEWAY_TOKEN" # Сюда вставьте токен из шага 1

      - name: codex-vps
        type: openai-codex
        base_url: http://<IP_VPS>:4000/v1
        api_key: "ВАШ_GATEWAY_TOKEN" # Тот же токен
    ```

3.  **Проверка списка моделей:**
    Вы можете прямо с компьютера проверить, видит ли шлюз ваши нейросети (замените `<TOKEN>` и `<IP_VPS>`):
    ```bash
    curl -H "Authorization: Bearer <TOKEN>" http://<IP_VPS>:4000/v1/models
    ```
    Если в ответ пришел JSON со списком моделей — поздравляю, всё работает!

### Важные правила безопасности (Чек-лист)
*   **Никогда не коммитьте** файлы `agent.db`, `.env` или токены в Git.
*   Если вы добавили новый аккаунт или токен в Брокер, **всегда перезапускайте Шлюз**: `sudo systemctl restart omp-auth-gateway.service`.
*   Токен — это ваш единственный ключ. Если он скомпрометирован, просто сгенерируйте новый на сервере и обновите его на всех устройствах.