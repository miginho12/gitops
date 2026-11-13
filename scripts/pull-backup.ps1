# DB 백업 외부 복제 — 노트북(Windows)이 Pi 에서 최신 prod 백업을 가져간다(pull).
# Pi 쪽은 scripts/backup-export.sh (forced command) 가 age 로 암호화해 stdout 으로 내보낸다.
# 노트북에는 암호문(.sql.gz.age)만 저장하고, 복호화 검증용 평문은 임시 파일로만 썼다가 지운다.
#
# 설치: %USERPROFILE%\clog-backup\ 에 이 파일과 register-pull-task.ps1 을 복사 → register 한 번 실행
# 수동 실행: powershell -NoProfile -ExecutionPolicy Bypass -File pull-backup.ps1
# Windows PowerShell 5.1 기준 (삼항·?? 연산자 안 씀)

$ErrorActionPreference = 'Stop'

$Base      = Join-Path $env:USERPROFILE 'clog-backup'
$SshKey    = Join-Path $Base 'keys\pull_ed25519'
$AgeKey    = Join-Path $Base 'keys\age.key'
$OutDir    = Join-Path $Base 'backups'
$LogFile   = Join-Path $Base 'pull.log'
$PiHost    = 'miginho@100.96.195.103'   # Pi 의 Tailscale IP — 집 밖에서도 동작
$KeepDays  = 30
$KeepMin   = 7                          # 오래 꺼져 있다 켜져도 전부 지우지 않는 하한
$KeyDir    = Join-Path $Base 'sealed-keys'   # sealed-secrets 마스터 키 번들(암호문, 전부 보관 — 개당 수십 KB)
$LogDir    = Join-Path $Base 'logs'          # prod 로그 하루치(암호문 .ndjson.gz.age) — 감사 M5
$LogKeepDays = 90
$LogLookback = 6                        # Pi 가 내보낼 수 있는 범위: 6일 전 ~ 어제 (Loki 보존 7일)
$TfDir     = Join-Path $Base 'tfstate'       # infra Terraform state(암호문, 바뀔 때만 새 파일 — 전부 보관, 개당 수 KB) — H5
$TfStacks  = @('uptime', 'cloudflare')       # infra 저장소 폴더(stack)마다 state 하나 — cloudflare 는 2026-11-14(ADR-096)
$rc        = 0                          # 키·로그 단계 실패 시 1 — DB 단계는 계속 진행하되 LastTaskResult 에 드러나게

function Write-Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

# 검증·저장이 끝났다고 Pi 에 알린다 → Pi 가 신선도 지표 갱신 (알림 ClogBackupReplicaStale)
function Send-Ack($fileName) {
    $a = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $tmpAck -RedirectStandardError $tmpErr `
        -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                        '-o', 'ConnectTimeout=20', $PiHost, 'ack', $fileName)
    if ($a.ExitCode -ne 0) { throw "ack 실패 exit=$($a.ExitCode): $(Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue)" }
}

# sealed-secrets 마스터 키 번들 (2026-11-09, 감사 H4) — 디스크 유실 시 Git 의 SealedSecret 을 풀 유일한 수단.
# Pi: backup-export.sh keys (키 전부, kind: List JSON, age 암호화) → 여기서 검증 → ack-keys
# → Pi 지표 갱신 (알림 ClogSealedKeysBackupStale: 새 키가 72h 안에 여기 안 들어오면)
# 복구: age -d -i keys\age.key <번들>.json.age | kubectl apply -f -   (컨트롤러 재시작)
function Sync-SealedKeys {
    New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    $kEnc = [IO.Path]::GetTempFileName(); $kErr = [IO.Path]::GetTempFileName()
    $kPlain = [IO.Path]::GetTempFileName(); $kAck = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $kEnc -RedirectStandardError $kErr `
            -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                            '-o', 'ConnectTimeout=20', $PiHost, 'keys')
        $err = (Get-Content $kErr -Raw -ErrorAction SilentlyContinue)
        if ($p.ExitCode -ne 0) { throw "ssh/keys 실패 exit=$($p.ExitCode): $err" }
        if ($err -notmatch 'keys=(\d+) bundle=(sealed-keys-\d+-\d{8}-\d{6})') { throw "키 메타데이터 없음: $err" }
        $count = [int]$Matches[1]; $bundle = $Matches[2]
        $dest = Join-Path $KeyDir ($bundle + '.json.age')

        if (-not (Test-Path $dest)) {
            # 검증 — 복호화 → List JSON → 개수 일치 → 키마다 tls.key·tls.crt 존재
            & $age -d -i $AgeKey -o $kPlain $kEnc
            if ($LASTEXITCODE -ne 0) { throw "키 번들 age 복호화 실패 exit=$LASTEXITCODE" }
            $j = Get-Content $kPlain -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.kind -ne 'List') { throw "키 번들 형식 오류: kind=$($j.kind)" }
            if (@($j.items).Count -ne $count) { throw "키 개수 불일치: 번들 $(@($j.items).Count) / Pi $count" }
            foreach ($it in $j.items) {
                if ($it.kind -ne 'Secret' -or -not $it.data.'tls.key' -or -not $it.data.'tls.crt') {
                    throw "키 항목 불완전: $($it.metadata.name)"
                }
            }
            Move-Item -Path $kEnc -Destination $dest
            $state = 'OK'
        } else { $state = 'SKIP' }

        $a = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $kAck -RedirectStandardError $kErr `
            -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                            '-o', 'ConnectTimeout=20', $PiHost, 'ack-keys', $bundle)
        if ($a.ExitCode -ne 0) { throw "ack-keys 실패 exit=$($a.ExitCode): $(Get-Content $kErr -Raw -ErrorAction SilentlyContinue)" }
        Write-Log "KEYS $state $bundle count=$count (ack)"
    }
    finally {
        # 평문 키(복호화본)는 반드시 지운다
        foreach ($f in @($kEnc, $kErr, $kPlain, $kAck)) { if (Test-Path $f) { Remove-Item $f -Force } }
    }
}

# prod 로그 외부 백업 (2026-11-10, 감사 M5) — Loki 보존 7일 이후에도 90일간 사본.
# Pi: backup-export.sh logs <YYYY-MM-DD> (그 날 UTC 하루, NDJSON → gzip → age) → 여기서 검증 → ack-logs
# 노트북이 며칠 꺼져 있어도 6일 안이면 밀린 날을 옛날 것부터 채운다.
# 알림: ClogLogBackupStale (노트북에 있는 가장 최근 날이 4일 넘게 안 바뀜)
# 열람: age -d -i keys\age.key <파일> | gzip -d   → 한 줄 = {"ts","labels","line"}
function Sync-Logs {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $today = [DateTime]::UtcNow.Date
    $newestHave = $null
    $failed = @()
    for ($i = $LogLookback; $i -ge 1; $i--) {
        $day = $today.AddDays(-$i).ToString('yyyy-MM-dd')
        $dest = Join-Path $LogDir ("prod-logs-$day.ndjson.gz.age")
        if (Test-Path $dest) { $newestHave = $day; continue }

        $lEnc = [IO.Path]::GetTempFileName(); $lErr = [IO.Path]::GetTempFileName()
        $lGz = [IO.Path]::GetTempFileName()
        try {
            $p = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $lEnc -RedirectStandardError $lErr `
                -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                                '-o', 'ConnectTimeout=20', $PiHost, 'logs', $day)
            $err = (Get-Content $lErr -Raw -ErrorAction SilentlyContinue)
            if ($p.ExitCode -ne 0) { throw "ssh/logs $day 실패 exit=$($p.ExitCode): $err" }
            if ($err -notmatch 'logs day=(\d{4}-\d{2}-\d{2}) lines=(\d+) raw=(\d+)') { throw "로그 메타데이터 없음: $err" }
            if ($Matches[1] -ne $day) { throw "날짜 불일치: 요청 $day / Pi $($Matches[1])" }
            $lines = [long]$Matches[2]

            # 검증 — 복호화 → gzip 해제 → 줄 수 일치 → 첫·마지막 줄 JSON
            & $age -d -i $AgeKey -o $lGz $lEnc
            if ($LASTEXITCODE -ne 0) { throw "로그 $day age 복호화 실패 exit=$LASTEXITCODE" }
            $fs = [IO.File]::OpenRead($lGz)
            try {
                $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
                $rd = New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)
                $n = 0; $first = $null; $last = $null
                while ($null -ne ($ln = $rd.ReadLine())) { if ($n -eq 0) { $first = $ln }; $last = $ln; $n++ }
            } finally { $fs.Dispose() }
            if ($n -ne $lines) { throw "로그 $day 줄 수 불일치: 받은 $n / Pi $lines" }
            if ($n -gt 0) {
                foreach ($l in @($first, $last)) {
                    $o = $l | ConvertFrom-Json
                    if (-not $o.ts -or $null -eq $o.line) { throw "로그 $day 형식 오류" }
                }
            }

            Move-Item -Path $lEnc -Destination $dest
            $newestHave = $day
            Write-Log "LOGS OK $day lines=$lines enc=$((Get-Item $dest).Length)"
        }
        catch {
            # 한 날이 실패해도 다음 날은 계속 받는다 (끝에서 한 번에 실패 처리)
            Write-Log "FAIL LOGS $day $($_.Exception.Message)"; $failed += $day
        }
        finally {
            # 평문(복호화본)은 반드시 지운다 — 로그에 IP·user_id 가 있다
            foreach ($f in @($lEnc, $lErr, $lGz)) { if (Test-Path $f) { Remove-Item $f -Force } }
        }
    }

    # 가장 최근 날 ack → Pi 지표 갱신 (새로 받은 게 없어도 보냄 — 사본이 있다는 사실은 그대로)
    if ($newestHave) {
        $kErr = [IO.Path]::GetTempFileName(); $kOut = [IO.Path]::GetTempFileName()
        try {
            $a = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput $kOut -RedirectStandardError $kErr `
                -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                                '-o', 'ConnectTimeout=20', $PiHost, 'ack-logs', $newestHave)
            if ($a.ExitCode -ne 0) { throw "ack-logs 실패 exit=$($a.ExitCode): $(Get-Content $kErr -Raw -ErrorAction SilentlyContinue)" }
            Write-Log "LOGS ack $newestHave"
        } finally { foreach ($f in @($kErr, $kOut)) { if (Test-Path $f) { Remove-Item $f -Force } } }
    }

    # 보관 정리 — 파일명 날짜 기준 90일
    $cut = $today.AddDays(-$LogKeepDays).ToString('yyyy-MM-dd')
    Get-ChildItem $LogDir -Filter 'prod-logs-*.ndjson.gz.age' |
        Where-Object { $_.Name.Substring(10, 10) -lt $cut } |
        ForEach-Object { Remove-Item $_.FullName; Write-Log "LOGS DEL $($_.Name)" }

    if ($failed.Count -gt 0) { throw "로그 실패 날짜: $($failed -join ',')" }
}

# infra Terraform state (2026-11-12, H5·ADR-095) — state 는 Git 밖(웹훅·ping URL 평문)이라 Pi 유실 대비 사본.
# Pi: backup-export.sh tfstate <stack> (검증 후 age 암호화) → 여기서 검증 → ack-tfstate
# → Pi stack 별 지표 갱신 (알림 ClogTfstateBackupStale: 72h 동안 ack 없음 · MetricMissing: stack 지표 없음)
# 복구: age -d -i keys\age.key tfstate-<stack>-<serial>-<sha>.json.age > infra\<stack>\terraform.tfstate  (그 뒤 terraform plan 이 No changes 인지)
function Sync-Tfstate($Stack) {
    New-Item -ItemType Directory -Force -Path $TfDir | Out-Null
    $tEnc = [IO.Path]::GetTempFileName(); $tErr = [IO.Path]::GetTempFileName()
    $tPlain = [IO.Path]::GetTempFileName(); $tAck = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tEnc -RedirectStandardError $tErr `
            -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                            '-o', 'ConnectTimeout=20', $PiHost, 'tfstate', $Stack)
        $err = (Get-Content $tErr -Raw -ErrorAction SilentlyContinue)
        if ($p.ExitCode -ne 0) { throw "ssh/tfstate 실패 exit=$($p.ExitCode): $err" }
        if ($err -notmatch ('tfstate name=(tfstate-' + $Stack + '-(\d+)-[0-9a-f]{12}) serial=\d+ sha256=([0-9a-f]{64}) bytes=(\d+)')) { throw "state 메타데이터 없음($Stack): $err" }
        $name = $Matches[1]; $serial = [int]$Matches[2]; $sha = $Matches[3]; $bytes = [long]$Matches[4]
        $dest = Join-Path $TfDir ($name + '.json.age')

        if (-not (Test-Path $dest)) {
            # 검증 — 복호화 → 크기·SHA256 일치 → JSON version 4·serial 일치
            & $age -d -i $AgeKey -o $tPlain $tEnc
            if ($LASTEXITCODE -ne 0) { throw "state age 복호화 실패 exit=$LASTEXITCODE" }
            if ((Get-Item $tPlain).Length -ne $bytes) { throw "state 크기 불일치: 받은 $((Get-Item $tPlain).Length) / Pi $bytes" }
            $got = (Get-FileHash -Algorithm SHA256 -Path $tPlain).Hash.ToLower()
            if ($got -ne $sha) { throw "state SHA256 불일치" }
            $j = Get-Content $tPlain -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.version -ne 4 -or [int]$j.serial -ne $serial) { throw "state 형식 오류: version=$($j.version) serial=$($j.serial)" }
            Move-Item -Path $tEnc -Destination $dest
            $state = 'OK'
        } else { $state = 'SKIP' }

        $a = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $tAck -RedirectStandardError $tErr `
            -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                            '-o', 'ConnectTimeout=20', $PiHost, 'ack-tfstate', $name)
        if ($a.ExitCode -ne 0) { throw "ack-tfstate 실패 exit=$($a.ExitCode): $(Get-Content $tErr -Raw -ErrorAction SilentlyContinue)" }
        Write-Log "TFSTATE $state $name (ack)"
    }
    finally {
        # 평문 state(웹훅·ping URL 포함)는 반드시 지운다
        foreach ($f in @($tEnc, $tErr, $tPlain, $tAck)) { if (Test-Path $f) { Remove-Item $f -Force } }
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ssh = (Get-Command ssh -ErrorAction Stop).Source
$age = (Get-Command age -ErrorAction Stop).Source

$tmpEnc = [IO.Path]::GetTempFileName()
$tmpErr = [IO.Path]::GetTempFileName()
$tmpGz  = [IO.Path]::GetTempFileName()
$tmpAck = [IO.Path]::GetTempFileName()
try {
    # 0) sealed-secrets 키 — 실패해도 DB 복제는 계속 (서로 독립), 종료 코드로만 드러냄
    try { Sync-SealedKeys } catch { Write-Log "FAIL KEYS $($_.Exception.Message)"; $rc = 1 }
    # 0') prod 로그 — 마찬가지로 독립 (M5)
    try { Sync-Logs } catch { Write-Log "FAIL LOGS $($_.Exception.Message)"; $rc = 1 }
    # 0'') infra Terraform state — 마찬가지로 독립 (H5)
    foreach ($st in $TfStacks) {
        try { Sync-Tfstate $st } catch { Write-Log "FAIL TFSTATE $st $($_.Exception.Message)"; $rc = 1 }
    }

    # 1) 가져오기 — Start-Process 리다이렉트는 바이트 그대로 저장한다 (PS 5.1 의 > 는 바이너리를 깨뜨림)
    $p = Start-Process -FilePath $ssh -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $tmpEnc -RedirectStandardError $tmpErr `
        -ArgumentList @('-i', $SshKey, '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
                        '-o', 'ConnectTimeout=20', $PiHost, 'export')
    $err = (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue)
    if ($p.ExitCode -ne 0) { throw "ssh/export 실패 exit=$($p.ExitCode): $err" }

    # stderr 의 "backup-export: file=<이름> bytes=<크기> ..." 에서 메타데이터
    if ($err -notmatch 'file=(\S+\.sql\.gz) bytes=(\d+)') { throw "메타데이터 없음: $err" }
    $name = $Matches[1]; $bytes = [long]$Matches[2]
    $dest = Join-Path $OutDir ($name + '.age')

    # 이미 검증·저장된 사본이 있음 → 저장은 건너뛰되 ack 는 보낸다 (사본이 있다는 사실은 그대로)
    if (Test-Path $dest) { Send-Ack $name; Write-Log "SKIP 이미 있음 $name (ack)"; exit $rc }

    # 2) 검증 — 복호화 → 원본 크기 일치 → gzip 해제 → pg_dump 끝 표시
    & $age -d -i $AgeKey -o $tmpGz $tmpEnc
    if ($LASTEXITCODE -ne 0) { throw "age 복호화 실패 exit=$LASTEXITCODE" }
    $gzLen = (Get-Item $tmpGz).Length
    if ($gzLen -ne $bytes) { throw "크기 불일치: 받은 $gzLen / Pi $bytes" }

    $fs = [IO.File]::OpenRead($tmpGz)
    try {
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
        $sql = (New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)).ReadToEnd()
    } finally { $fs.Dispose() }
    if ($sql -notmatch 'PostgreSQL database dump complete') { throw "끝 표시 없음(잘린 덤프): $name" }

    # 3) 저장 — 암호문만
    Move-Item -Path $tmpEnc -Destination $dest
    Send-Ack $name
    Write-Log "OK $name gz=$bytes enc=$((Get-Item $dest).Length) (ack)"

    # 4) 보관 정리 — KeepDays 지난 것 삭제, 단 최신 KeepMin 개는 항상 유지
    $files = Get-ChildItem $OutDir -Filter '*.sql.gz.age' | Sort-Object Name -Descending
    $files | Select-Object -Skip $KeepMin |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } |
        ForEach-Object { Remove-Item $_.FullName; Write-Log "DEL $($_.Name)" }
    exit $rc
}
catch {
    Write-Log "FAIL $($_.Exception.Message)"
    exit 1
}
finally {
    # 평문(복호화본)과 임시 파일 정리
    foreach ($f in @($tmpEnc, $tmpErr, $tmpGz, $tmpAck)) { if (Test-Path $f) { Remove-Item $f -Force } }
}

# 작업 스케줄러 등록: scripts/register-pull-task.ps1 (같은 폴더에 복사 후 한 번 실행)
