#Requires -Version 7.6
<#
    Azure Database for PostgreSQL Flexible Server 자동 기동/중지 런북

    태그   : AutoStartTime / AutoStopTime 에 HH:mm 지정 (분은 00 또는 30 만 유효)
    스케줄 : 00:00 시작 1시간마다 + 00:30 시작 1시간마다, 두 개를 이 런북에 연결
    정책   : 주말·공휴일에는 기동하지 않고 중지는 매일 수행 (공휴일은 변수 HolidayList)
    환경   : PowerShell 7.6 / Az.Accounts, Az.PostgreSql / 시스템 할당 관리 ID
             대상 구독에 Contributor 이상 필요
             Az.PostgreSqlFlexibleServer 는 cmdlet 이름이 겹치므로 함께 넣지 않습니다

    중지한 서버는 7일이 지나면 Azure 가 자동으로 기동합니다.
    주말 이틀만 중지하는 용도에는 영향이 없으나, 장기 중지에는 사용할 수 없습니다.
#>

param(
    [Parameter(Mandatory = $true)]
    [string[]] $TargetSubscriptionIds
)

# ===== 설정 ===== (변경 시 런북 재게시 필요)
$StartTagName         = 'AutoStartTime'
$StopTagName          = 'AutoStopTime'
$HolidayVariableName  = 'HolidayList'
$SlotMinutes          = 30         # 태그 시각 단위. 스케줄 실행 간격과 반드시 일치시켜야 합니다
$ThrottleLimit        = 4          # 병렬 동시 실행 개수
$StrictHolidayParsing = $true      # 공휴일 목록에 형식 오류가 있으면 실행 중단
$DryRun               = $false     # $true 이면 대상만 출력하고 실제 조작은 하지 않음

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

#region 0. 시간대 및 로깅

# 한국은 서머타임이 없어 UTC+9 가 항상 KST 입니다. 현재 시각을 고정해 이후 판정에 사용합니다.
$kstNow = [DateTime]::UtcNow.AddHours(9)

# 로그 한 줄을 [시각 KST][레벨] 메시지 형태로 출력합니다. WARN 은 경고 스트림으로 보냅니다.
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [ValidateSet('INFO', 'WARN')][string] $Level = 'INFO'
    )
    $stamp = [DateTime]::UtcNow.AddHours(9).ToString('HH:mm:ss')
    if ($Level -eq 'WARN') { Write-Warning "[$stamp KST][WARN] $Message" }
    else                   { Write-Output  "[$stamp KST][INFO] $Message" }
}

#endregion

#region 1. 파라미터 검증 및 담당 슬롯 계산

$todayYmd  = $kstNow.ToString('yyyy-MM-dd')
$dayOfWeek = $kstNow.DayOfWeek.ToString()

# 현재 시각을 30분 단위로 내림해 이번 실행이 담당할 슬롯과, 슬롯 대비 지연 시간을 구합니다.
$slot     = $kstNow.Date.AddMinutes([Math]::Floor($kstNow.TimeOfDay.TotalMinutes / $SlotMinutes) * $SlotMinutes)
$slotText = $slot.ToString('HH:mm')
$driftMin = [int]($kstNow - $slot).TotalMinutes

Write-Log ("=== PostgreSQL AutoStart/Stop | {0} ({1}) | DryRun={2}" -f `
    $kstNow.ToString('yyyy-MM-dd HH:mm:ss'), $dayOfWeek, $DryRun)
Write-Log ("담당 슬롯: {0} (잡 시작 지연 {1}분)" -f $slotText, $driftMin)

# 지연이 10분 이상이면 경고를 남깁니다.
if ($driftMin -ge 10) {
    Write-Log ("잡 시작이 {0}분 지연됐습니다. {1}분 이상 지연되면 그 슬롯의 태그가 실행되지 않습니다." -f `
        $driftMin, $SlotMinutes) -Level WARN
}

# 구독 ID 목록에서 공백과 중복을 제거하고 GUID 형식을 검사합니다.
$targetSubs = @($TargetSubscriptionIds |
    ForEach-Object { $_.Trim() } |
    Where-Object   { $_ } |
    Select-Object  -Unique)

$invalidSubs = @($targetSubs.Where({ $_ -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' }))
if ($targetSubs.Count -eq 0)  { throw '처리할 대상 구독 ID가 없습니다.' }
if ($invalidSubs.Count -gt 0) { throw ("구독 ID 형식 오류: {0}" -f ($invalidSubs -join ', ')) }

Write-Log ("대상 구독 {0}개: {1}" -f $targetSubs.Count, ($targetSubs -join ', '))

#endregion

#region 2. 공휴일 목록 로딩 및 업무일 판정

# Automation 변수에서 공휴일 목록을 읽습니다. 조회에 실패하면 잡을 중단합니다.
try {
    $holidayRaw = Get-AutomationVariable -Name $HolidayVariableName -ErrorAction Stop
} catch {
    throw ("Automation 변수 '{0}' 조회 실패. 변수와 권한을 확인하십시오. 원인: {1}" -f `
        $HolidayVariableName, $_.Exception.Message)
}
$holidayRaw ??= ''

$holidayDates = [System.Collections.Generic.HashSet[string]]::new()
$rejected     = [System.Collections.Generic.List[string]]::new()

# 쉼표·세미콜론·줄바꿈으로 나눈 뒤, yyyy-MM-dd 로 파싱되는 값만 등록하고 나머지는 따로 모읍니다.
foreach ($token in ($holidayRaw -split '[,;\r\n]+' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($token, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref] $d)) {
        [void] $holidayDates.Add($token)
    } else {
        $rejected.Add($token)
    }
}

# 파싱되지 않은 값이 있으면 설정에 따라 중단하거나 경고만 남깁니다.
if ($rejected.Count -gt 0) {
    $msg = ("공휴일 목록 형식 오류(yyyy-MM-dd 필요): {0}" -f ($rejected -join ', '))
    if ($StrictHolidayParsing) { throw $msg }
    Write-Log $msg -Level WARN
}

# 오늘이 주말이거나 공휴일 목록에 있으면 업무일이 아닙니다.
$isHoliday = $holidayDates.Contains($todayYmd)
$isBizDay  = -not (@('Saturday', 'Sunday') -contains $dayOfWeek -or $isHoliday)

Write-Log ("공휴일 {0}건 / IsHoliday={1} / IsBusinessDay={2}" -f $holidayDates.Count, $isHoliday, $isBizDay)

#endregion

#region 3. 대상 서버 수집

# 태그 시각 문자열을 파싱해 이번 슬롯과 일치하는지 판정합니다.
# 형식 오류이거나 분이 30 단위가 아니면 경고를 남기고 $false 를 반환합니다.
# $slotText, $SlotMinutes 는 상단 스코프를 그대로 참조합니다.
function Test-SlotMatch {
    param([string] $TimeText, [string] $TagName, [string] $Label)

    if ([string]::IsNullOrWhiteSpace($TimeText)) { return $false }

    [string[]] $formats = @('HH:mm', 'H:mm')
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($TimeText.Trim(), $formats, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref] $parsed)) {
        Write-Log "$Label : $TagName 형식 오류 '$TimeText' (HH:mm 필요)" -Level WARN
        return $false
    }

    if ($parsed.Minute % $SlotMinutes -ne 0) {
        Write-Log "$Label : $TagName='$TimeText' 은 ${SlotMinutes}분 단위가 아니어서 실행되지 않습니다." -Level WARN
        return $false
    }

    return ($parsed.ToString('HH:mm') -eq $slotText)
}

# 서버 객체에서 태그 값을 대소문자 구분 없이 읽습니다.
# 모듈 버전에 따라 속성 이름이 Tag 또는 Tags 로 달라져 양쪽을 모두 확인합니다.
function Get-TagValue {
    param($Server, [string] $Key)

    $bag = if ($null -ne $Server.Tag) { $Server.Tag } else { $Server.Tags }
    if ($null -eq $bag) { return $null }

    foreach ($k in $bag.Keys) {
        if ($k -ieq $Key) { return [string]$bag[$k] }
    }
    return $null
}

# 관리 ID 로 로그인합니다. 컨텍스트는 프로세스 범위로만 유지합니다.
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

$targets = [System.Collections.Generic.List[object]]::new()

foreach ($subId in $targetSubs) {

    # 구독 내 서버 목록을 한 번에 조회합니다. 응답에 태그와 상태가 함께 담깁니다.
    # 컨텍스트 전환 대신 -SubscriptionId 를 직접 지정합니다.
    try {
        $servers = @(Get-AzPostgreSqlFlexibleServer -SubscriptionId $subId -ErrorAction Stop)
    } catch {
        Write-Log ("구독 {0} 서버 조회 실패로 건너뜁니다: {1}" -f $subId, $_.Exception.Message) -Level WARN
        continue
    }

    $matched = 0
    $skipped = 0
    foreach ($server in $servers) {

        # 리소스 ID 에서 리소스 그룹 이름을 추출합니다.
        $rgName = ($server.Id -split '/')[4]
        $label  = "{0}/{1}" -f $rgName, $server.Name

        # 두 태그에서 시각을 읽습니다. 둘 다 없으면 이 서버는 대상이 아닙니다.
        $startVal = Get-TagValue $server $StartTagName
        $stopVal  = Get-TagValue $server $StopTagName
        if (-not $startVal -and -not $stopVal) { continue }

        # 각 태그가 이번 슬롯과 일치하는지 판정합니다. 기동은 업무일에만 성립합니다.
        $doStart = (Test-SlotMatch $startVal $StartTagName $label) -and $isBizDay
        $doStop  =  Test-SlotMatch $stopVal  $StopTagName  $label

        # 기동과 중지가 동시에 성립하면 경고를 남기고 이 서버를 건너뜁니다.
        if ($doStart -and $doStop) {
            Write-Log "$label : $StartTagName 과 $StopTagName 이 같은 시각($slotText)입니다. 태그를 확인하십시오." -Level WARN
            continue
        }
        if (-not $doStart -and -not $doStop) { continue }

        $action  = $doStop ? 'Stop' : 'Start'
        $tagTime = $doStop ? $stopVal : $startVal
        $state   = [string]$server.State

        # 중지는 Ready, 기동은 Stopped 상태에서만 수행할 수 있습니다.
        # 전이 중이거나 이미 목표 상태이면 명령을 보내지 않습니다.
        $canRun = if ($action -eq 'Stop') { $state -eq 'Ready' } else { $state -eq 'Stopped' }

        Write-Log ("{0} : {1}({2}) State={3} -> {4}" -f `
            $label, $action, $tagTime, $state, ($canRun ? '대상' : '제외'))

        if (-not $canRun) { $skipped++; continue }

        # 실행에 필요한 정보와 현재 상태를 담아 대상 목록에 추가합니다.
        $matched++
        $targets.Add([PSCustomObject]@{
            SubscriptionId = $subId
            ResourceGroup  = $rgName
            Name           = $server.Name
            Action         = $action
            TagTime        = $tagTime
            PreState       = $state
        })
    }

    Write-Log ("구독 {0}: 전체 {1}대 / 슬롯 일치 {2}대 / 실행 불가 {3}대" -f `
        $subId, $servers.Count, ($matched + $skipped), $skipped)
}

Write-Log ("실행 대상 {0}대" -f $targets.Count)
if ($targets.Count -eq 0) { return }

#endregion

#region 4. 병렬 실행

# 대상 서버를 최대 $ThrottleLimit 개씩 동시에 처리하고, 서버 하나당 결과 객체 하나를 반환합니다.
# 모든 cmdlet 에 -SubscriptionId 를 직접 지정하므로 런스페이스 간 컨텍스트 충돌이 없습니다.
$executionResults = $targets | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {

    $target = $_
    $action = $target.Action
    $subId  = $target.SubscriptionId
    $isDryRun = $using:DryRun

    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'

    $label  = '[{0}/{1}]' -f $target.ResourceGroup, $target.Name
    $result = [PSCustomObject]@{
        Name = $target.Name; ResourceGroup = $target.ResourceGroup; Subscription = $subId
        Action = $action; TagTime = $target.TagTime
        PreState = $target.PreState; PostState = $null; Result = 'Unknown'; Message = ''
    }

    try {
        # 런스페이스는 모듈을 물려받지 않으므로 이 안에서 다시 임포트합니다.
        Import-Module Az.Accounts   -ErrorAction Stop
        Import-Module Az.PostgreSql -ErrorAction Stop

        # 이 런스페이스에 Az 컨텍스트가 없으면 관리 ID 로 로그인합니다.
        # 실패하면 2초, 4초 간격으로 최대 3회까지 재시도합니다.
        if (-not (Get-AzContext)) {
            Disable-AzContextAutosave -Scope Process | Out-Null
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try { Connect-AzAccount -Identity -ErrorAction Stop | Out-Null; break }
                catch {
                    if ($attempt -eq 3) { throw }
                    Start-Sleep -Seconds (2 * $attempt)
                }
            }
        }

        # DryRun 이면 대상만 기록하고 실제 조작 없이 반환합니다.
        if ($isDryRun) {
            $result.Result = 'DryRun'; $result.PostState = $target.PreState
            Write-Output "$label [DRYRUN] $action 대상 (State=$($target.PreState))"
            return $result
        }

        Write-Output "$label $action 시작 (State=$($target.PreState))"

        # 기동 또는 중지를 실행하고 완료될 때까지 대기합니다. 실패하면 예외가 발생합니다.
        $opArgs = @{
            SubscriptionId    = $subId
            ResourceGroupName = $target.ResourceGroup
            Name              = $target.Name
            ErrorAction       = 'Stop'
        }
        if ($action -eq 'Stop') { Stop-AzPostgreSqlFlexibleServer  @opArgs | Out-Null }
        else                    { Start-AzPostgreSqlFlexibleServer @opArgs | Out-Null }

        # 실행 후 상태를 다시 조회해 결과에 기록합니다.
        $after = Get-AzPostgreSqlFlexibleServer -SubscriptionId $subId `
            -ResourceGroupName $target.ResourceGroup -Name $target.Name -ErrorAction Stop
        $result.PostState = [string]$after.State
        $result.Result    = 'Succeeded'
        Write-Output "$label $action 완료 (State=$($result.PostState))"
    }
    catch {
        # 예외가 나면 결과에 사유를 남기고, 다른 서버 처리는 계속 진행됩니다.
        $result.Result  = 'Failed'
        $result.Message = $_.Exception.Message
        Write-Output "$label [ERROR] $action 실패: $($_.Exception.Message)"
    }

    $result
}

#endregion

#region 5. 결과 요약

$results = @($executionResults)

# 결과를 표로 출력합니다.
$view = $results | Sort-Object Result, Name | ForEach-Object {
    [PSCustomObject]@{
        Server = "{0}/{1}" -f $_.ResourceGroup, $_.Name
        Action = $_.Action
        Tag    = $_.TagTime
        Before = $_.PreState
        After  = $_.PostState
        Result = $_.Result
    }
}
Write-Output (($view | Format-Table -AutoSize | Out-String).Trim())

# 실패한 서버의 사유를 표 아래에 한 줄씩 출력합니다.
foreach ($r in $results.Where({ $_.Result -eq 'Failed' })) {
    Write-Output ("  ! {0}/{1} : {2}" -f $r.ResourceGroup, $r.Name, $r.Message)
}

Write-Log ("결과 요약 - {0}" -f (($results | Group-Object Result |
    ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }) -join ', '))

# 실패가 있으면 사유를 담아 예외를 발생시켜 잡을 Failed 로 종료합니다.
$failed = @($results.Where({ $_.Result -eq 'Failed' }))
if ($failed.Count -gt 0) {
    throw ("{0}건 실패 - {1}" -f $failed.Count, (($failed | ForEach-Object {
        "{0}/{1}({2}): {3}" -f $_.ResourceGroup, $_.Name, $_.Action, $_.Message
    }) -join ' | '))
}

Write-Log '런북 정상 종료'

#endregion