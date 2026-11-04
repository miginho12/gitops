# pull-backup.ps1 을 작업 스케줄러에 등록한다 (관리자 권한 불필요, 한 번만 실행).
# 트리거: 매일 09:00 (백업 03:00 KST 이후) + 로그온 3분 뒤. 꺼져 있어 놓친 실행은 켜지면 바로 실행.
$ErrorActionPreference = 'Stop'
$ps  = Join-Path $env:USERPROFILE 'clog-backup\pull-backup.ps1'
if (-not (Test-Path $ps)) { throw "없음: $ps" }

$act = New-ScheduledTaskAction -Execute 'powershell.exe' `
         -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps`""
$daily = New-ScheduledTaskTrigger -Daily -At 9:00
$logon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$logon.Delay = 'PT3M'      # 로그온 직후 네트워크·Tailscale 연결 대기
$set = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
         -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName 'clog-backup-pull' -Action $act -Trigger @($daily, $logon) -Settings $set `
  -Description 'Pi 에서 clog prod DB 백업(age 암호화)을 가져온다 (gitops/scripts/pull-backup.ps1)' -Force | Out-Null

Get-ScheduledTask -TaskName 'clog-backup-pull' | Select-Object TaskName, State
(Get-ScheduledTask -TaskName 'clog-backup-pull').Triggers | Select-Object @{n='Trigger';e={$_.CimClass.CimClassName}}, StartBoundary, Delay
