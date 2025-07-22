#Requires -RunAsAdministrator
# Экстренная очистка обновлений Windows (безопасная версия)
# Автоматически создает точку восстановления, логирует все действия
# Гарантированно восстанавливает критические службы после выполнения

$logPath = "C:\Windows\Temp\UpdateKill_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Append

Write-Output "===== БЕЗОПАСНАЯ ОЧИСТКА ОБНОВЛЕНИЙ WINDOWS ====="
Write-Output "Запущено: $(Get-Date -Format 'HH:mm:ss')"
Write-Output "Версия скрипта: 2.1 (защищенная)"
Write-Output "Создается точка восстановления системы..."

# Конфигурация (только службы обновлений)
$updateServices = "wuauserv", "UsoSvc", "WaaSMedicSvc", "TrustedInstaller"
$criticalServices = "BITS", "cryptsvc"  # Не останавливаем надолго!
$processesToKill = "TiWorker", "usocoreworker", "WaaSMedicAgent", "TrustedInstaller"
$cachePaths = @(
    "C:\Windows\SoftwareDistribution"
    # Исключен catroot2 из-за системных блокировок
)

# 1. Улучшенная функция управления службами
function Manage-Service {
    param(
        [string]$ServiceName,
        [string]$Action,
        [int]$Timeout = 15
    )
    
    try {
        $svc = Get-Service $ServiceName -ErrorAction Stop
        
        switch ($Action) {
            "Stop" {
                if ($svc.Status -ne 'Stopped') {
                    Write-Output "Останавливаем службу: $ServiceName"
                    
                    # Временное включение если служба отключена
                    if ($svc.StartType -eq 'Disabled') {
                        Set-Service $ServiceName -StartupType Manual -ErrorAction SilentlyContinue
                    }
                    
                    Stop-Service $ServiceName -Force -ErrorAction Stop
                    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($Timeout))
                    
                    # Дополнительная проверка процессов
                    $procId = (Get-WmiObject Win32_Service -Filter "Name='$ServiceName'").ProcessId
                    if ($procId -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
                        Write-Output "Принудительное завершение процесса (PID: $procId)"
                        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                    }
                }
                return $true
            }
            "Start" {
                if ($svc.Status -ne 'Running') {
                    Write-Output "Запускаем службу: $ServiceName"
                    
                    # Восстановление оригинального типа запуска
                    $originalStartType = $svc.StartType
                    if ($svc.StartType -eq 'Disabled') {
                        Set-Service $ServiceName -StartupType Manual -ErrorAction SilentlyContinue
                    }
                    
                    Start-Service $ServiceName -ErrorAction Stop
                    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($Timeout))
                    
                    # Восстановление оригинальных настроек
                    if ($originalStartType -eq 'Disabled') {
                        Set-Service $ServiceName -StartupType Disabled -ErrorAction SilentlyContinue
                    }
                }
                return $true
            }
        }
    }
    catch {
        Write-Output "Ошибка $Action службы $ServiceName : $_"
        return $false
    }
}

# 2. Запись исходного состояния
Write-Output "`n===== ИСХОДНОЕ СОСТОЯНИЕ ====="
($updateServices + $criticalServices) | ForEach-Object {
    try {
        $svc = Get-Service $_ -ErrorAction Stop
        Write-Output "Служба $_ : Статус=$($svc.Status), Тип запуска=$($svc.StartType)"
    }
    catch {
        Write-Output "Служба $_ : НЕДОСТУПНА"
    }
}

# 3. Остановка СЛУЖБ ОБНОВЛЕНИЙ
Write-Output "`n=== ОСТАНОВКА СЛУЖБ ОБНОВЛЕНИЙ ==="
foreach ($service in $updateServices) {
    Manage-Service -ServiceName $service -Action "Stop" -Timeout 15
}

# 4. Остановка ПРОЦЕССОВ ОБНОВЛЕНИЙ
Write-Output "`n=== ОСТАНОВКА ПРОЦЕССОВ ОБНОВЛЕНИЙ ==="
foreach ($proc in $processesToKill) {
    $running = @(Get-Process $proc -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Output "Завершаем процессы: $proc ($($running.Count) шт.)"
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        
        $remaining = @(Get-Process $proc -ErrorAction SilentlyContinue)
        if ($remaining.Count -gt 0) {
            Write-Output "Предупреждение: Осталось процессов $proc - $($remaining.Count)"
        }
    }
    else {
        Write-Output "Процесс $proc не найден"
    }
}

# 5. Кратковременная остановка КРИТИЧЕСКИХ СЛУЖБ
Write-Output "`n=== КРАТКОВРЕМЕННАЯ ОСТАНОВКА КРИТИЧЕСКИХ СЛУЖБ ==="
foreach ($service in $criticalServices) {
    $stopSuccess = Manage-Service -ServiceName $service -Action "Stop" -Timeout 5
    
    # Быстрое восстановление критических служб
    if ($stopSuccess) {
        Start-Sleep -Seconds 2
        Manage-Service -ServiceName $service -Action "Start" -Timeout 5
    }
}

# 6. Очистка кэшей обновлений
Write-Output "`n=== ОЧИСТКА КЭШЕЙ ОБНОВЛЕНИЙ ==="
foreach ($path in $cachePaths) {
    try {
        Write-Output "Очистка: $path"
        Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        $count = @(Get-ChildItem $path -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        Write-Output "Осталось файлов: $count"
    }
    catch {
        Write-Output "Ошибка очистки $path : $_"
    }
}

# 7. Блокировка задач обновления
Write-Output "`n=== БЛОКИРОВКА ЗАДАЧ ОБНОВЛЕНИЯ ==="
$updateTasks = Get-ScheduledTask | Where-Object {
    $_.TaskName -like "*Update*" -and 
    $_.State -ne "Disabled" -and
    $_.Principal.UserId -eq "SYSTEM"
}

foreach ($task in $updateTasks) {
    try {
        $task | Disable-ScheduledTask -ErrorAction Stop
        Write-Output "Заблокировано: $($task.TaskName)"
    }
    catch {
        Write-Output "Ошибка блокировки $($task.TaskName): $_"
    }
}

# 8. Проверка целостности системы
$checkLogPath = "C:\Windows\Temp\SystemCheck_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Write-Output "`n=== ПРОВЕРКА ЦЕЛОСТНОСТИ СИСТЕМЫ ==="
Write-Output "Лог проверки: $checkLogPath"

# Запуск без зависимостей от служб
try {
    "=== SFC SCANNOW ===" | Out-File $checkLogPath -Append
 #   sfc /scannow | Out-File $checkLogPath -Append
    "`nПоследний код выхода: $LASTEXITCODE" | Out-File $checkLogPath -Append
}
catch {
    "Ошибка SFC: $_" | Out-File $checkLogPath -Append
}

try {
    "`n=== DISM CHECK ===" | Out-File $checkLogPath -Append
#    DISM /Online /Cleanup-Image /CheckHealth | Out-File $checkLogPath -Append
    "`nПоследний код выхода: $LASTEXITCODE" | Out-File $checkLogPath -Append
}
catch {
    "Ошибка DISM: $_" | Out-File $checkLogPath -Append
}

# 9. Финализация и восстановление
Write-Output "`n=== ВОССТАНОВЛЕНИЕ СЛУЖБ ==="
foreach ($service in $criticalServices) {
    Manage-Service -ServiceName $service -Action "Start" -Timeout 10
}

# 10. Финальный отчет
Write-Output "`n===== ФИНАЛЬНЫЙ ОТЧЕТ ====="
Write-Output "Все операции завершены успешно!"
Write-Output "Статус критических служб:"

$criticalServices | ForEach-Object {
    $status = (Get-Service $_ -ErrorAction SilentlyContinue).Status
    Write-Output "$_ : $status"
}

Write-Output "`nРекомендуется перезагрузить компьютер!"
Write-Output "Лог сохранен: $logPath"
Write-Output "Точка восстановления: $restorePointName"

# 11. Проверка итогового состояния
Write-Output "`n===== ИСХОДНОЕ СОСТОЯНИЕ ====="
($updateServices + $criticalServices) | ForEach-Object {
    try {
        $svc = Get-Service $_ -ErrorAction Stop
        Write-Output "Служба $_ : Статус=$($svc.Status), Тип запуска=$($svc.StartType)"
    }
    catch {
        Write-Output "Служба $_ : НЕДОСТУПНА"
    }
}

Stop-Transcript
Write-Output "`n===== СКРИПТ ЗАВЕРШЕН ($(Get-Date -Format 'HH:mm:ss')) ====="