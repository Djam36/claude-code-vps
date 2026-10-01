# claude-code-vps: Windows installer and helper (Windows PowerShell 5.1 or PowerShell 7).
#
#   irm https://raw.githubusercontent.com/Djam36/claude-code-vps/main/install.ps1 | iex
#
# After setup the command `claude-vps` is available in new terminal windows:
#   claude-vps login         log in to Claude Code on the VPS (official URL + code flow)
#   claude-vps open <port>   open a site that runs on the VPS (SSH port forwarding)
#   claude-vps attach        tmux session on the VPS that survives disconnects
#   claude-vps setup         run the installation again
#
# Everything runs inside one script block so nothing leaks into the caller's session
# when the script is piped into Invoke-Expression. For the same reason `exit` is used only
# when the script runs as a file (the installed helper), to return a failure exit code.

& {
$ErrorActionPreference = 'Stop'

$CcvVersion = '1.1.0'
$CcvApi = 1
$BaseUrl = if ($env:CCV_BASE_URL) { $env:CCV_BASE_URL } else { 'https://raw.githubusercontent.com/Djam36/claude-code-vps/main' }
$CcvHome = Join-Path $env:USERPROFILE '.claude-vps'
$AliasFile = Join-Path $CcvHome 'alias'
# The alias chosen at setup is remembered, so daily commands find the same server.
$Alias = if ($env:CCV_ALIAS) { $env:CCV_ALIAS }
         elseif (Test-Path $AliasFile) { ([System.IO.File]::ReadAllText($AliasFile)).Trim() }
         else { '' }
if (-not $Alias) { $Alias = 'claude-vps' }
$WorkUser = if ($env:CCV_USER) { $env:CCV_USER } else { 'dev' }
$AdminUser = if ($env:CCV_ADMIN_USER) { $env:CCV_ADMIN_USER } else { 'root' }
$SudoMode = if ($env:CCV_SUDO) { $env:CCV_SUDO } else { 'password' }

$BinDir = Join-Path $CcvHome 'bin'
$HelperPs1 = Join-Path $CcvHome 'claude-vps.ps1'
$SshDir = Join-Path $env:USERPROFILE '.ssh'
$KeyPath = Join-Path $SshDir 'claude_vps_ed25519'
$SshConfig = Join-Path $SshDir 'config'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Shared mutable state (a hashtable avoids scope surprises under Invoke-Expression).
$S = @{ Host = $env:CCV_HOST; Port = $env:CCV_PORT; Tunnel = $null; SudoPasswordPath = $null; Bootstrap = $null; TempFiles = @() }
$Self = $PSCommandPath

function Write-Info([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host '[OK] ' -ForegroundColor Green -NoNewline; Write-Host $Text }
function Write-Warn([string]$Text) { Write-Host 'Внимание: ' -ForegroundColor Yellow -NoNewline; Write-Host $Text }
function Fail([string]$Text) { throw $Text }

function Find-Tool([string]$Name) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) {
    Fail "Не найден $Name. Установите компонент Windows «Клиент OpenSSH» (Параметры → Приложения → Дополнительные компоненты), откройте PowerShell заново и повторите."
  }
  return $cmd.Source
}

function Show-Usage {
  Write-Host @"
claude-vps $CcvVersion — Claude Code на вашем VPS без рабочего стола на сервере.

  claude-vps setup          установить или перенастроить сервер
  claude-vps login          войти в Claude Code на сервере (ссылка + код)
  claude-vps open <порт>    открыть сайт, запущенный на сервере (например 3000)
  claude-vps attach         сессия tmux на сервере, которая переживает обрывы связи
  claude-vps help           эта справка

Подключение по SSH: ssh $Alias
Документация: https://github.com/Djam36/claude-code-vps
"@
}

# Runs a native program with a raw command line (PowerShell 5.1 drops empty arguments).
function Invoke-Raw([string]$File, [string]$Arguments) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File
  $psi.Arguments = $Arguments
  $psi.UseShellExecute = $false
  $process = [System.Diagnostics.Process]::Start($psi)
  $process.WaitForExit()
  return $process.ExitCode
}

# ------------------------------------------------------------------ setup ----

function Get-SshBase {
  return @('-p', "$($S.Port)", '-i', $KeyPath, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=accept-new',
           '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=10')
}

function Read-Input {
  Write-Host ''
  Write-Host "claude-code-vps $CcvVersion — Claude Code на вашем VPS" -ForegroundColor Cyan
  Write-Host 'Сервер: Debian 11+ или Ubuntu 20.04+, доступ root (обычно пароль из панели хостинга).'
  Write-Host ''
  if (-not $S.Host) { $S.Host = Read-Host 'IP-адрес или домен сервера' }
  $S.Host = ($S.Host -replace '\s', '')
  if ($S.Host -notmatch '^[A-Za-z0-9.-]+$') { Fail 'Введите IPv4-адрес или домен без http://, пробелов и лишних символов.' }
  if (-not $S.Port) {
    $S.Port = Read-Host 'SSH-порт [22]'
    if (-not $S.Port) { $S.Port = '22' }
  }
  $portNumber = 0
  if (-not [int]::TryParse("$($S.Port)", [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
    Fail 'SSH-порт должен быть числом от 1 до 65535.'
  }
  $S.Port = $portNumber
  if ($WorkUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $WorkUser -eq 'root') { Fail "CCV_USER: недопустимое имя пользователя '$WorkUser'." }
  if ($SudoMode -ne 'password' -and $SudoMode -ne 'nopasswd') { Fail 'CCV_SUDO может быть только password или nopasswd.' }
}

function New-Key {
  if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir | Out-Null }
  if ((Test-Path $KeyPath) -and -not (Test-Path "$KeyPath.pub")) {
    Fail "Есть приватный ключ без публичной части: $KeyPath. Перезаписывать его не буду."
  }
  if (Test-Path $KeyPath) {
    Write-Ok "Использую существующий ключ $KeyPath"
    return
  }
  $code = Invoke-Raw $SshKeygen ('-q -t ed25519 -a 64 -N "" -C claude-vps -f "' + $KeyPath + '"')
  if ($code -ne 0) { Fail 'ssh-keygen не смог создать ключ.' }
  Write-Ok "Создан отдельный SSH-ключ $KeyPath"
}

function Test-KeyLogin([string]$User) {
  # Windows PowerShell 5.1 turns redirected native stderr into errors; keep them non-terminating here.
  $ErrorActionPreference = 'Continue'
  $base = Get-SshBase
  & $Ssh -n @base -o BatchMode=yes "$User@$($S.Host)" true 2>$null | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Push-Key {
  $pub = (Get-Content -Raw "$KeyPath.pub").Trim()
  if ($pub.Contains("'") -or $pub.Contains('"')) { Fail 'Неожиданный формат публичного ключа.' }
  Write-Info 'Шаг 1/5. Добавляю ключ на сервер.'
  Write-Host "Сервер один раз спросит пароль $AdminUser. При вводе пароля символы не отображаются — это нормально."
  Write-Host ''
  $remote = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys)"
  & $Ssh -p "$($S.Port)" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$AdminUser@$($S.Host)" $remote
  if ($LASTEXITCODE -ne 0) { Fail "Не удалось войти как $AdminUser. Проверьте IP, порт и пароль в панели хостинга." }
  Write-Ok 'Ключ добавлен'
}

function Get-Bootstrap {
  $local = $null
  if ($Self) { $local = Join-Path (Split-Path -Parent $Self) 'bootstrap.sh' }
  if ($local -and (Test-Path $local)) {
    $S.Bootstrap = $local
  } else {
    $S.Bootstrap = Join-Path $env:TEMP ("ccv-bootstrap-" + [guid]::NewGuid().ToString('N') + '.sh')
    $S.TempFiles += $S.Bootstrap
    try {
      Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/bootstrap.sh?v=$CcvVersion" -OutFile $S.Bootstrap
    } catch {
      Fail "Не удалось скачать bootstrap.sh с $BaseUrl."
    }
  }
  $text = [System.IO.File]::ReadAllText($S.Bootstrap)
  if (-not $text.StartsWith('#!/usr/bin/env bash')) { Fail 'bootstrap.sh скачался повреждённым.' }
  if ($text -notmatch "(?m)^readonly CCV_API=$CcvApi\r?$") {
    Fail 'Версии install.ps1 и bootstrap.sh не совпадают. Подождите 5 минут (кэш GitHub) и повторите.'
  }
}

# Called as a statement (never inside an expression) so ssh keeps the real console:
# live output and the sudo password prompt work. The caller checks $LASTEXITCODE.
function Invoke-Phase([string]$User, [string]$Phase, [string[]]$PhaseArgs) {
  & $Scp -q -P "$($S.Port)" -i $KeyPath -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new $S.Bootstrap "${User}@$($S.Host):.ccv-bootstrap.sh"
  if ($LASTEXITCODE -ne 0) { Fail 'Не удалось передать bootstrap.sh на сервер.' }
  $sudo = if ($User -eq 'root') { '' } else { 'sudo' }
  $joined = $PhaseArgs -join ' '
  $remote = "sed -i 's/\r`$//' .ccv-bootstrap.sh; $sudo bash .ccv-bootstrap.sh $Phase $CcvApi $joined; rc=`$?; rm -f .ccv-bootstrap.sh; exit `$rc"
  $base = Get-SshBase
  & $Ssh -t @base "$User@$($S.Host)" $remote
}

function Confirm-WorkLogin {
  Write-Info "Шаг 4/5. Проверяю вход под $WorkUser по ключу..."
  $base = Get-SshBase
  $out = & $Ssh -n @base -o BatchMode=yes "$WorkUser@$($S.Host)" 'printf CCV_LOGIN_OK; sudo -n cat /var/lib/claude-vps/sudo-password 2>/dev/null || true'
  if ($LASTEXITCODE -ne 0) {
    Fail "Вход под $WorkUser не прошёл. Root и пароли пока НЕ отключены — исправьте причину и запустите установщик снова."
  }
  $out = (@($out) -join "`n")
  if (-not $out.StartsWith('CCV_LOGIN_OK')) { Fail 'Сервер ответил неожиданно при проверке входа.' }
  Write-Ok "Вход под $WorkUser работает"

  $password = $out.Substring('CCV_LOGIN_OK'.Length).Trim()
  if ($password) {
    if (-not (Test-Path $CcvHome)) { New-Item -ItemType Directory -Path $CcvHome | Out-Null }
    $S.SudoPasswordPath = Join-Path $CcvHome "sudo-password-$Alias.txt"
    [System.IO.File]::WriteAllText($S.SudoPasswordPath, $password + "`n", $Utf8NoBom)
    Write-Ok "Пароль sudo сохранён: $($S.SudoPasswordPath)"
  }
}

function Write-SshConfig {
  $begin = "# >>> claude-code-vps: $Alias >>>"
  $end = "# <<< claude-code-vps: $Alias <<<"
  $existing = ''
  if (Test-Path $SshConfig) { $existing = [System.IO.File]::ReadAllText($SshConfig) }
  $pattern = '(?s)' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n(\r?\n)?'
  $existing = [regex]::Replace($existing, $pattern, '')

  # Our block goes first so `Host *` sections below cannot override it.
  # The trailing `Host *` returns any global options that follow to global scope.
  $block = @(
    $begin,
    "Host $Alias",
    "    HostName $($S.Host)",
    "    User $WorkUser",
    "    Port $($S.Port)",
    '    IdentityFile ~/.ssh/claude_vps_ed25519',
    '    IdentitiesOnly yes',
    '    ServerAliveInterval 30',
    '    ServerAliveCountMax 6',
    'Host *',
    $end,
    ''
  ) -join "`n"
  [System.IO.File]::WriteAllText($SshConfig, $block + "`n" + $existing, $Utf8NoBom)
  $ErrorActionPreference = 'Continue'
  & $Ssh -G $Alias 2>$null | Out-Null
  $ErrorActionPreference = 'Stop'
  if ($LASTEXITCODE -ne 0) { Fail 'Получившийся .ssh\config не прошёл проверку ssh -G.' }
  Write-Ok "В .ssh\config добавлено подключение '$Alias' (ssh $Alias)"
}

function Add-UserPath([string]$Dir) {
  $key = Get-Item -Path 'HKCU:\Environment'
  $current = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
  $parts = @($current -split ';' | Where-Object { $_ })
  if ($parts -contains $Dir) { return }
  $new = (@($parts) + $Dir) -join ';'
  [Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment', 'Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
  # SetEnvironmentVariable broadcasts WM_SETTINGCHANGE, so new terminals pick up the PATH change.
  [Environment]::SetEnvironmentVariable('CLAUDE_VPS_HOME', $CcvHome, 'User')
  $env:Path = "$env:Path;$Dir"
}

function Install-Helper {
  foreach ($dir in @($CcvHome, $BinDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  }
  [System.IO.File]::WriteAllText($AliasFile, $Alias + "`n", (New-Object System.Text.UTF8Encoding $false))
  # The repository file has no BOM (a BOM breaks `irm | iex`), but Windows PowerShell 5.1
  # reads BOM-less files with -File as ANSI. The installed helper is therefore saved with a BOM.
  $helperText = $null
  if ($Self -and (Test-Path $Self)) {
    if ((Resolve-Path $Self).Path -eq $HelperPs1) { $helperText = $null } else { $helperText = [System.IO.File]::ReadAllText($Self, $Utf8NoBom) }
  } else {
    try {
      $bytes = (Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/install.ps1?v=$CcvVersion").RawContentStream.ToArray()
      $helperText = $Utf8NoBom.GetString($bytes)
    } catch {
      Write-Warn 'Не удалось скачать команду claude-vps. Её можно поставить позже повторным запуском установщика.'
      return
    }
  }
  if ($helperText) {
    $helperText = $helperText.TrimStart([char]0xFEFF)
    [System.IO.File]::WriteAllText($HelperPs1, $helperText, (New-Object System.Text.UTF8Encoding $true))
  }
  $cmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\claude-vps.ps1`" %*`r`n"
  [System.IO.File]::WriteAllText((Join-Path $BinDir 'claude-vps.cmd'), $cmd, [System.Text.Encoding]::ASCII)
  Add-UserPath $BinDir
  Write-Ok "Установлена команда claude-vps ($BinDir). В новых окнах терминала она доступна сразу."
}

function Show-Summary {
  Write-Host ''
  Write-Host 'Готово! Сервер настроен.' -ForegroundColor Green
  Write-Host ''
  Write-Host "  Терминал на сервере:   ssh $Alias"
  Write-Host "  VS Code:               Remote-SSH → Connect to Host → $Alias"
  Write-Host '  Вход в Claude Code:    claude-vps login'
  Write-Host '  Сайт с сервера:        claude-vps open 3000'
  Write-Host '  Долгая сессия (tmux):  claude-vps attach'
  if ($S.SudoPasswordPath) { Write-Host "  Пароль для sudo:       $($S.SudoPasswordPath)" }
  Write-Host ''
  Write-Host "Вход root и вход по паролю на сервере теперь отключены. Ключ: $KeyPath — не теряйте его."
}

function Invoke-Setup {
  Read-Input
  New-Key

  $conn = $null
  if (Test-KeyLogin $WorkUser) {
    $conn = $WorkUser
    Write-Ok "Ключ уже подходит для $WorkUser — это повторная установка"
    if ($SudoMode -eq 'password') { Write-Host "Если сервер спросит пароль sudo — он в файле $(Join-Path $CcvHome "sudo-password-$Alias.txt")" }
  } elseif (Test-KeyLogin $AdminUser) {
    $conn = $AdminUser
    Write-Ok "Ключ уже подходит для $AdminUser"
  } else {
    Push-Key
    if (-not (Test-KeyLogin $AdminUser)) { Fail 'Ключ добавлен, но вход по нему не работает. Проверьте /root/.ssh на сервере.' }
    $conn = $AdminUser
  }

  Write-Info 'Шаг 2/5. Загружаю серверный скрипт...'
  Get-Bootstrap
  Write-Ok 'bootstrap.sh готов'

  Write-Info "Шаг 3/5. Настраиваю сервер: пакеты, Claude Code, пользователь $WorkUser (обычно 2–5 минут)..."
  $pubB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$KeyPath.pub"))
  Invoke-Phase $conn 'prepare' @($WorkUser, $pubB64, $SudoMode)
  if ($LASTEXITCODE -ne 0) {
    Fail 'Подготовка сервера не завершилась. Текст ошибки выше; журнал на сервере: /var/log/claude-vps-install.log'
  }

  Confirm-WorkLogin

  Write-Info 'Шаг 5/5. Включаю защиту: SSH только по ключу, UFW, fail2ban, автообновления...'
  # The remote shell expands SSH_CONNECTION: UFW must keep the port we are connected through open.
  Invoke-Phase $WorkUser 'harden' @($WorkUser, '${SSH_CONNECTION##* }')
  if ($LASTEXITCODE -ne 0) {
    Fail 'Защита не включилась. Текст ошибки выше; журнал на сервере: /var/log/claude-vps-install.log'
  }
  if (-not (Test-KeyLogin $WorkUser)) {
    Fail "После включения защиты вход под $WorkUser не проверился. Откройте консоль в панели хостинга и проверьте /etc/ssh/sshd_config.d/00-claude-vps.conf."
  }

  Write-SshConfig
  Install-Helper
  Show-Summary

  $answer = Read-Host "`nВойти в Claude Code сейчас? [Y/n]"
  if ($answer -match '^(n|no|н|нет)$') {
    Write-Host 'Позже: claude-vps login'
  } else {
    Invoke-Login
  }
}

# ---------------------------------------------------------------- tunnels ----

function Assert-Alias {
  $marker = "# >>> claude-code-vps: $Alias >>>"
  if (-not (Test-Path $SshConfig) -or -not ([System.IO.File]::ReadAllText($SshConfig).Contains($marker))) {
    Fail "Подключение '$Alias' не найдено в .ssh\config. Сначала выполните установку: claude-vps setup"
  }
}

function Test-PortBusy([int]$Port) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync('127.0.0.1', $Port)
    return ($task.Wait(300) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Close()
  }
}

function Get-FreePort([int]$From, [int]$To) {
  for ($port = $From; $port -le $To; $port++) {
    if (Test-PortBusy $port) { continue }
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
    try { $listener.Start(); $listener.Stop(); return $port } catch { continue }
  }
  return 0
}

function Stop-Tunnel {
  if ($S.Tunnel -and -not $S.Tunnel.HasExited) {
    Stop-Process -Id $S.Tunnel.Id -Force -ErrorAction SilentlyContinue
  }
  $S.Tunnel = $null
}

# Starts `ssh -N <forward> <alias>` hidden in the background and waits until the local port listens.
function Start-Tunnel([int]$LocalPort, [string]$Forward) {
  $S.Tunnel = Start-Process -FilePath $Ssh -ArgumentList "-N -o ExitOnForwardFailure=yes -o BatchMode=yes $Forward $Alias" -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 40; $i++) {
    if (Test-PortBusy $LocalPort) { return }
    if ($S.Tunnel.HasExited) { $S.Tunnel = $null; Fail "SSH-туннель не поднялся. Проверьте: ssh $Alias" }
    Start-Sleep -Milliseconds 500
  }
  Fail "SSH-туннель не ответил за 20 секунд. Проверьте: ssh $Alias"
}

# --------------------------------------------------------------- commands ----

function Invoke-Login {
  Assert-Alias
  Write-Info 'Вход в Claude Code'
  Write-Host @'

Сейчас на сервере запустится официальный вход Claude Code (claude auth login):
  1. В терминале появится ссылка. Скопируйте её и откройте в обычном браузере
     на своём компьютере.
  2. Войдите в свой аккаунт Claude и нажмите Authorize.
  3. Скопируйте показанный код и вставьте его в терминал в строку
     «Paste code here if prompted» (правая кнопка мыши или Ctrl+V). Затем Enter.
  4. Появится «Login successful».

'@
  & $Ssh -t $Alias 'claude auth login'
  if ($LASTEXITCODE -ne 0) { Fail 'Вход не завершился. Повторите: claude-vps login' }
  Write-Ok "Вход выполнен. Работайте через VS Code, ssh $Alias или claude-vps attach"
}

function Invoke-Open([string]$RemotePort) {
  Assert-Alias
  $remote = 0
  if (-not [int]::TryParse("$RemotePort", [ref]$remote) -or $remote -lt 1 -or $remote -gt 65535) {
    Fail 'Укажите порт сайта на сервере, например: claude-vps open 3000'
  }
  $localPort = Get-FreePort $remote ([Math]::Min($remote + 20, 65535))
  if ($localPort -eq 0) { Fail "Локальные порты $remote–$($remote + 20) заняты." }
  Start-Tunnel $localPort "-L 127.0.0.1:${localPort}:127.0.0.1:$remote"
  $url = "http://127.0.0.1:$localPort"
  Write-Ok "Порт $remote сервера доступен у вас по адресу $url"
  Start-Process $url | Out-Null
  Read-Host 'Нажмите Enter, чтобы закрыть проброс порта' | Out-Null
  Stop-Tunnel
}

function Invoke-Attach {
  Assert-Alias
  & $Ssh -t $Alias 'tmux new-session -A -s claude'
}

function Invoke-Main([object[]]$Arguments) {
  $command = 'setup'
  if ($Arguments -and $Arguments.Count -gt 0 -and $Arguments[0]) { $command = [string]$Arguments[0] }
  $rest = $null
  if ($Arguments -and $Arguments.Count -gt 1) { $rest = [string]$Arguments[1] }

  # Tools are looked up per command, so `help` works without OpenSSH. The command
  # functions called below see these variables through PowerShell dynamic scoping.
  $Ssh = $null; $Scp = $null; $SshKeygen = $null
  if ($command -in @('setup', 'install', 'login', 'open', 'attach')) { $Ssh = Find-Tool 'ssh.exe' }
  if ($command -in @('setup', 'install')) {
    $Scp = Find-Tool 'scp.exe'
    $SshKeygen = Find-Tool 'ssh-keygen.exe'
  }

  switch ($command) {
    { $_ -in @('setup', 'install') } { Invoke-Setup; break }
    'login' { Invoke-Login; break }
    'open' { Invoke-Open $rest; break }
    'attach' { Invoke-Attach; break }
    { $_ -in @('version', '--version', '-v') } { Write-Host "claude-vps $CcvVersion"; break }
    { $_ -in @('help', '--help', '-h') } { Show-Usage; break }
    default { Show-Usage; Fail "Неизвестная команда: $command" }
  }
}

$previousEncoding = [Console]::OutputEncoding
$failed = $false
try {
  # Server output is UTF-8; without this the Russian text from bootstrap.sh turns into mojibake.
  [Console]::OutputEncoding = $Utf8NoBom
  Invoke-Main $args
} catch {
  $failed = $true
  Write-Host ''
  Write-Host ('Ошибка: ' + $_.Exception.Message) -ForegroundColor Red
} finally {
  Stop-Tunnel
  foreach ($file in $S.TempFiles) { Remove-Item -Force -ErrorAction SilentlyContinue $file }
  [Console]::OutputEncoding = $previousEncoding
}
if ($failed -and $Self) { exit 1 }
} @args
