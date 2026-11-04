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

function Write-Log($msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ssh = (Get-Command ssh -ErrorAction Stop).Source
$age = (Get-Command age -ErrorAction Stop).Source

$tmpEnc = [IO.Path]::GetTempFileName()
$tmpErr = [IO.Path]::GetTempFileName()
$tmpGz  = [IO.Path]::GetTempFileName()
try {
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

    if (Test-Path $dest) { Write-Log "SKIP 이미 있음 $name"; exit 0 }

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
    Write-Log "OK $name gz=$bytes enc=$((Get-Item $dest).Length)"

    # 4) 보관 정리 — KeepDays 지난 것 삭제, 단 최신 KeepMin 개는 항상 유지
    $files = Get-ChildItem $OutDir -Filter '*.sql.gz.age' | Sort-Object Name -Descending
    $files | Select-Object -Skip $KeepMin |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepDays) } |
        ForEach-Object { Remove-Item $_.FullName; Write-Log "DEL $($_.Name)" }
    exit 0
}
catch {
    Write-Log "FAIL $($_.Exception.Message)"
    exit 1
}
finally {
    # 평문(복호화본)과 임시 파일 정리
    foreach ($f in @($tmpEnc, $tmpErr, $tmpGz)) { if (Test-Path $f) { Remove-Item $f -Force } }
}

# 작업 스케줄러 등록: scripts/register-pull-task.ps1 (같은 폴더에 복사 후 한 번 실행)
