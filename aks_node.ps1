<#
=====================================================================================
 런북명   : Set-AksNodePoolSchedule.ps1
 버전     : v1.2
 목적     : AKS 노드풀의 NodeCount 를 시간대별로 조정합니다.
 실행환경 : PowerShell 7.6 Runtime environment / Az.Accounts / 시스템 할당 관리 ID
 -------------------------------------------------------------------------------------
 파라미터 : Action(ScaleOut/ScaleIn), SubscriptionId. 시각은 Automation 스케줄이 결정합니다.
 규칙     : ScheduleRules 키는 "클러스터명/노드풀명" 이며, 위에서부터 처음 매칭되는
            규칙 하나만 적용됩니다. 매칭되는 규칙이 없으면 변경하지 않습니다.
 일시예외 : 클러스터 태그로 처리하며 재게시가 필요 없습니다.
            AutoScaleScheduleUntil = yyyy-MM-dd  -> 그 날짜까지 제외 후 자동 복귀
            AutoScaleSchedule      = Disabled    -> 해제할 때까지 제외
 자동제외 : System 모드, GPU, Autoscaler 활성 노드풀은 규칙과 무관하게 제외됩니다.
 dev/stg  : 런북을 환경별로 따로 두며, 차이는 상수 블록의 "환경별 설정" 구간뿐입니다.
 구현     : Az.Aks cmdlet 대신 ARM REST API 를 직접 호출합니다. cmdlet 이 내부에서 부르는
            주소를 그대로 호출하는 것이라 동작은 같으며, 병렬 러너스페이스마다 모듈을
            다시 로드하지 않기 위한 선택입니다. 각 호출부에 대응하는 cmdlet 을 주석으로
            적어 두었으므로, 무슨 동작인지는 그 줄을 보시면 됩니다.
=====================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ScaleOut', 'ScaleIn')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# =====================================================================================
# 0. 설정 블록
# =====================================================================================

# true 이면 실제 변경 없이 계획만 출력합니다.
$DryRun = $false

$Const = @{

    # ═════════════════════════════════════════════════════════════════════════
    # ▼▼▼ 환경별 설정 — dev / stg 런북이 서로 다른 부분은 여기뿐입니다 ▼▼▼
    # ═════════════════════════════════════════════════════════════════════════

    # 이 런북이 담당하는 구독과 리소스 그룹입니다.
    # 다른 구독 ID 로 실행되면 즉시 중단되므로, stg 스케줄이 dev 런북에
    # 잘못 연결되는 사고를 여기서 막습니다.
    SubscriptionMap = @{
        '' = @('cm-hea-dev-genai-rg')
    }

    # 스케줄 규칙. 키는 반드시 "클러스터명/노드풀명" 형식이며 양쪽 모두 와일드카드가 됩니다.
    # 위에서부터 확인해 처음 매칭되는 규칙 하나만 적용되므로,
    # 구체적인 규칙을 위에, 공통 규칙을 아래에 둡니다.
    # 값이 'Skip' 이면 해당 노드풀을 건드리지 않습니다.
    # 어느 규칙에도 걸리지 않으면 Unmanaged 로 기록만 하고 변경하지 않습니다.
    ScheduleRules = [ordered]@{

        # ── 개별 지정 : 노드풀 명이 같아도 클러스터가 다르면 값을 따로 줍니다 ──
        'training01/llmtr01' = @{ ScaleOut = 1; ScaleIn = 1 }
        'training02/llmtr01' = @{ ScaleOut = 1; ScaleIn = 0 }

        # ── 상시 제외 ────────────────────────────────────────────────────────
        '*/devops'           = 'Skip'
        # 'training01/*'     = 'Skip'      # 특정 클러스터 전체를 장기간 뺄 때 사용합니다

        # ── 공통 규칙 ────────────────────────────────────────────────────────
        '*/fabrix*'          = @{ ScaleOut = 7; ScaleIn = 1 }
        '*/mgmtsol*'         = @{ ScaleOut = 4; ScaleIn = 0 }
        '*/portal*'          = @{ ScaleOut = 4; ScaleIn = 0 }
        '*/mgmtsv*'          = @{ ScaleOut = 2; ScaleIn = 0 }
        '*/mgmttr*'          = @{ ScaleOut = 2; ScaleIn = 0 }
        '*/llmsv01*'         = @{ ScaleOut = 1; ScaleIn = 0 }
    }

    # ═════════════════════════════════════════════════════════════════════════
    # ▲▲▲ 환경별 설정 끝 — 아래는 dev / stg 런북이 동일합니다 ▲▲▲
    # ═════════════════════════════════════════════════════════════════════════

    # 클러스터 통째로 제외합니다. 목록 조회 직후 적용되어 노드풀을 들여다보지 않습니다.
    # ScheduleRules 와 분리해 둔 이유는, 이쪽이 먼저 걸러져야 불필요한 판정을 건너뛸 수 있고
    # 규칙 우선순위와 섞이지 않아 읽기 쉽기 때문입니다.
    ClusterExcludePatterns = @('*restore*')

    ScheduleTagName   = 'AutoScaleSchedule'         # 값이 Disabled/Off/False/No 면 클러스터 전체 제외
    UntilTagName      = 'AutoScaleScheduleUntil'    # yyyy-MM-dd 까지 제외
    HolidayVariable   = 'HolidayList'               # 공휴일 목록 Automation 변수
    ApiVersion        = '2024-09-01'
    ThrottleLimit     = 8                           # 동시 처리 클러스터 수
    OperationTimeout  = 1800                        # 비동기 작업 대기 상한(초)
    SkipSystemPool    = $true
    SkipGpuPool       = $true
    GpuVmSizePattern  = '^Standard_N'               # NC/ND/NV/NG 계열이 모두 해당합니다
    WaitForCompletion = $false                      # 마지막 노드풀까지 완료 확인할지 여부
}

# =====================================================================================
# 1. 로깅 헬퍼
#    병렬 구간에서는 각 러너스페이스가 자기 로그를 모았다가 한 번에 출력합니다.
#    그래야 클러스터별 로그가 뒤섞이지 않고 이어서 읽힙니다.
# =====================================================================================
function Get-KstNow {
    # Windows 샌드박스는 'Korea Standard Time', Linux 워커는 'Asia/Seoul' 을 사용합니다.
    foreach ($zoneId in @('Korea Standard Time', 'Asia/Seoul')) {
        try {
            return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,
                   [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId))
        }
        catch { continue }
    }
    return [DateTime]::UtcNow.AddHours(9)   # 두 ID 모두 없으면 오프셋으로 계산
}

function Format-LogLine {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('INFO','STEP','OK','SKIP','WARN','ERROR','DRY')][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Scope = ''
    )
    $ts = (Get-KstNow).ToString('yyyy-MM-dd HH:mm:ss')
    $sc = if ([string]::IsNullOrWhiteSpace($Scope)) { '' } else { " [$Scope]" }
    return ("{0} [{1,-5}]{2} {3}" -f $ts, $Level, $sc, $Message)
}

function Write-RunLog {
    # 부모 러너스페이스 전용. 즉시 출력합니다.
    param(
        [Parameter(Mandatory = $true)][string]$Level,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][string]$Scope = ''
    )
    $line = Format-LogLine -Level $Level -Message $Message -Scope $Scope
    if ($Level -in @('WARN', 'ERROR')) { Write-Warning $line } else { Write-Output $line }
}

$totalWatch = [System.Diagnostics.Stopwatch]::StartNew()

Write-Output "====================================================================="
Write-Output " AKS 노드풀 스케줄링 런북 시작 (v1.2)"
Write-Output "====================================================================="
Write-RunLog -Level 'INFO' -Message "Action=$Action / SubscriptionId=$SubscriptionId"

if ($DryRun) {
    Write-Warning "*** DryRun 모드입니다. 실제 노드 수는 변경되지 않습니다. ***"
    Write-Warning "*** 검증이 끝나면 스크립트의 DryRun 변수를 false 로 되돌리고 재게시해야 합니다. ***"
}

# =====================================================================================
# 2. 구독 유효성 확인
# =====================================================================================
Write-RunLog -Level 'STEP' -Message '1/6 구독 유효성 확인'

if (-not $Const.SubscriptionMap.ContainsKey($SubscriptionId)) {
    throw "[ERROR] SubscriptionMap 에 등록되지 않은 구독입니다: $SubscriptionId"
}
$targetResourceGroups = @($Const.SubscriptionMap[$SubscriptionId])
Write-RunLog -Level 'OK' -Message "대상 리소스 그룹 $($targetResourceGroups.Count)개: $($targetResourceGroups -join ', ')"

# =====================================================================================
# 3. 인증 및 ARM 토큰 발급
# =====================================================================================
Write-RunLog -Level 'STEP' -Message '2/6 인증 및 토큰 발급'

Import-Module Az.Accounts -ErrorAction Stop

# 병렬 러너스페이스가 컨텍스트 파일을 공유하며 서로의 구독을 덮어쓰는 문제를 막습니다.
Disable-AzContextAutosave -Scope Process | Out-Null

try {
    # Automation 계정의 시스템 할당 관리 ID 로 로그인합니다.
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Write-RunLog -Level 'OK' -Message '시스템 할당 관리 ID 인증 완료'
}
catch {
    throw "[ERROR] Azure 로그인 실패: $($_.Exception.Message)"
}

# ARM 호출에 쓸 액세스 토큰을 발급받습니다. REST 호출 시 Authorization 헤더에 들어가며,
# 로그인한 관리 ID 의 권한을 증명하는 값입니다.
# 부모에서 1회만 발급받아 각 병렬 러너스페이스에 문자열로 전달하므로,
# 러너스페이스마다 Az 컨텍스트를 만들지 않아 기동 오버헤드와 컨텍스트 오염이 없습니다.
$tokenParams = @{ ResourceUrl = 'https://management.azure.com/'; ErrorAction = 'Stop' }
if ((Get-Command Get-AzAccessToken).Parameters.ContainsKey('AsSecureString')) {
    $tokenParams['AsSecureString'] = $true   # Az.Accounts 4.x 이상은 SecureString 을 반환합니다
}
$tokenResult = Get-AzAccessToken @tokenParams

# SecureString 으로 받은 경우 REST 헤더에 넣기 위해 평문 문자열로 되돌립니다.
# (Az.Accounts 버전에 따라 반환 형식이 다르므로 두 경우를 모두 처리합니다)
$armToken = if ($tokenResult.Token -is [System.Security.SecureString]) {
                [System.Net.NetworkCredential]::new('', $tokenResult.Token).Password
            } else { [string]$tokenResult.Token }

Write-RunLog -Level 'OK' -Message "ARM 토큰 발급 완료 (만료: $($tokenResult.ExpiresOn))"

# =====================================================================================
# 4. 주말 / 공휴일 판정
#    주말·공휴일에는 ScaleOut 을 수행하지 않고, ScaleIn 은 매일 수행합니다.
# =====================================================================================
Write-RunLog -Level 'STEP' -Message '3/6 주말·공휴일 판정'

$kstNow   = Get-KstNow
$todayKst = $kstNow.Date
$isWeekend = $kstNow.DayOfWeek -in @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday)
$isHoliday = $false

try {
    # Automation 계정 > 공유 리소스 > 변수 에 등록한 값을 읽습니다.
    # 값 형식은 ["2026-09-24","2026-10-03"] 같은 JSON 배열 문자열입니다.
    $holidayRaw = Get-AutomationVariable -Name $Const.HolidayVariable -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($holidayRaw)) {
        $isHoliday = (@($holidayRaw | ConvertFrom-Json)) -contains $todayKst.ToString('yyyy-MM-dd')
    }
    Write-RunLog -Level 'OK' -Message "공휴일 변수 조회 완료 (오늘=$($todayKst.ToString('yyyy-MM-dd')), 주말=$isWeekend, 공휴일=$isHoliday)"
}
catch {
    # 공휴일 변수 조회 실패로 런북을 중단하지 않고 주말 판정만 적용합니다.
    Write-RunLog -Level 'WARN' -Message "공휴일 변수 '$($Const.HolidayVariable)' 조회 실패. 주말 판정만 적용합니다. ($($_.Exception.Message))"
}

if ($Action -eq 'ScaleOut' -and ($isWeekend -or $isHoliday)) {
    Write-RunLog -Level 'SKIP' -Message '주말·공휴일이므로 ScaleOut 을 수행하지 않고 종료합니다.'
    Write-Output "====================================================================="
    return
}

# =====================================================================================
# 5. 공통 헬퍼 함수
#    ForEach-Object -Parallel 안에서는 부모의 함수가 보이지 않으므로,
#    함수 본문을 문자열로 추출해 두었다가 각 러너스페이스에 주입합니다.
# =====================================================================================

function Invoke-ArmRequest {
    <#
      ARM REST 호출 래퍼입니다. 이 런북의 모든 Azure 호출이 이 함수를 거칩니다.
      Az cmdlet 이 내부에서 하는 재시도 처리를 직접 구현한 부분입니다.
      - 429(요청 과다) 는 Retry-After 헤더를 우선 존중하고, 없으면 지수 백오프합니다.
      - 5xx 등 일시적 오류도 동일하게 재시도합니다.
      - 그 외 4xx 는 설정 오류일 가능성이 높아 즉시 예외를 던집니다.
      반환값: @{ Content = 응답본문; Headers = 응답헤더; StatusCode = int }
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $false)]$Body = $null,
        [Parameter(Mandatory = $false)][int]$MaxRetry = 5
    )

    $headers = @{ Authorization = "Bearer $AccessToken"; 'Content-Type' = 'application/json' }

    for ($attempt = 1; $attempt -le $MaxRetry; $attempt++) {
        try {
            $p = @{
                Uri = $Uri; Method = $Method; Headers = $headers
                ResponseHeadersVariable = 'respHeaders'
                StatusCodeVariable      = 'statusCode'
                ErrorAction             = 'Stop'
            }
            if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 30 -Compress) }

            $content = Invoke-RestMethod @p
            return @{ Content = $content; Headers = $respHeaders; StatusCode = $statusCode }
        }
        catch {
            $status = 0; $retryAfter = 0
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                $ra = $_.Exception.Response.Headers | Where-Object { $_.Key -eq 'Retry-After' }
                if ($ra) { $retryAfter = [int]($ra.Value | Select-Object -First 1) }
            }

            $isRetryable = ($status -eq 429) -or ($status -ge 500) -or ($status -eq 0)
            if (-not $isRetryable -or $attempt -eq $MaxRetry) {
                throw "ARM 호출 실패 ($Method $Uri) [HTTP $status] : $($_.Exception.Message)"
            }
            $waitSec = if ($retryAfter -gt 0) { $retryAfter }
                       else { [Math]::Pow(2, $attempt) + (Get-Random -Minimum 0 -Maximum 3) }
            Start-Sleep -Seconds ([int]$waitSec)
        }
    }
}

function Test-TagExclusion {
    <#
      클러스터 태그로 제외 여부를 판정합니다.
      반환값: 제외 사유 문자열(제외 대상) 또는 $null(대상 아님)
    #>
    param(
        [Parameter(Mandatory = $false)]$Tags,
        [Parameter(Mandatory = $true)][string]$TagName,
        [Parameter(Mandatory = $true)][string]$UntilTagName,
        [Parameter(Mandatory = $true)][datetime]$TodayKst,
        [Parameter(Mandatory = $false)][ref]$WarnRef = $null
    )

    if ($null -eq $Tags) { return $null }

    # 태그 키는 대소문자를 구분하지 않으므로 실제 키를 찾아 사용합니다.
    $names       = $Tags.PSObject.Properties.Name
    $keyDisabled = $names | Where-Object { $_ -ieq $TagName }      | Select-Object -First 1
    $keyUntil    = $names | Where-Object { $_ -ieq $UntilTagName } | Select-Object -First 1

    if ($keyDisabled) {
        $val = ([string]$Tags.$keyDisabled).Trim()
        if ($val -imatch '^(disabled|off|false|no)$') {
            return "태그 $keyDisabled=$val 로 제외된 클러스터입니다."
        }
    }

    if ($keyUntil) {
        $val = ([string]$Tags.$keyUntil).Trim()
        $until = [datetime]::MinValue
        $ok = [datetime]::TryParseExact($val, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
                                        [System.Globalization.DateTimeStyles]::None, [ref]$until)
        if ($ok) {
            if ($TodayKst -le $until.Date) {
                return "태그 $keyUntil=$val 기준 제외 기간입니다."
            }
            # 기간이 지난 태그는 자동 복귀시키되 정리하도록 경고를 남깁니다.
            if ($null -ne $WarnRef) { $WarnRef.Value = "만료된 제외 태그가 남아 있습니다. 삭제를 권장합니다. ($keyUntil=$val)" }
        }
        else {
            if ($null -ne $WarnRef) { $WarnRef.Value = "제외 태그 값이 yyyy-MM-dd 형식이 아닙니다. 무시하고 진행합니다. ($keyUntil=$val)" }
        }
    }
    return $null
}

function Wait-ArmOperation {
    <#
      노드풀 변경 요청은 즉시 끝나지 않고 "접수" 만 되며, Azure 가 백그라운드에서 처리합니다.
      이때 응답 헤더 Azure-AsyncOperation(없으면 Location) 에 진행 상태를 조회할 주소가 담겨
      오는데, 그 주소를 10초 간격으로 조회해 Succeeded/Failed 가 나올 때까지 기다립니다.
      Update-AzAksNodePool 을 -AsJob 없이 실행했을 때 cmdlet 내부에서 하는 일과 같습니다.
      AKS 는 클러스터당 동시에 1건의 변경만 허용하므로, 같은 클러스터의 다음 노드풀을
      건드리기 전에 반드시 이 대기를 거쳐야 409 충돌이 발생하지 않습니다.
    #>
    param(
        [Parameter(Mandatory = $true)]$ResponseHeaders,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $opUrl = $null
    foreach ($key in @('Azure-AsyncOperation', 'Location')) {
        if ($ResponseHeaders.ContainsKey($key)) { $opUrl = @($ResponseHeaders[$key])[0]; break }
    }
    if ([string]::IsNullOrWhiteSpace($opUrl)) { return 'Succeeded' }   # 헤더가 없으면 동기 완료로 간주

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10   # 폴링 간격. 너무 짧으면 ARM 스로틀링에 걸립니다.
        $state = (Invoke-ArmRequest -Uri $opUrl -Method 'GET' -AccessToken $AccessToken).Content.status
        if ($state -in @('Succeeded', 'Failed', 'Canceled')) { return $state }
    }
    return 'Timeout'
}

# 위 함수들의 본문을 문자열로 꺼내 둡니다. 병렬 블록 안에서는 부모의 함수가 보이지 않으므로,
# 이 문자열을 각 러너스페이스의 function: 드라이브에 다시 등록해 사용합니다.
$fnInvokeArm   = ${function:Invoke-ArmRequest}
$fnTestTag     = ${function:Test-TagExclusion}
$fnWaitArm     = ${function:Wait-ArmOperation}
$fnGetKstNow   = ${function:Get-KstNow}
$fnFormatLog   = ${function:Format-LogLine}

# =====================================================================================
# 6. 클러스터 목록 조회 (리소스 그룹당 1회 + 페이징)
#    [대응 cmdlet] Get-AzAksCluster -ResourceGroupName $rg
#    이 응답 하나에 태그, agentPoolProfiles(노드풀별 count/mode/vmSize/autoscaling),
#    provisioningState 가 모두 들어 있습니다. 따라서 클러스터마다 Get-AzAksNodePool 을
#    다시 부를 필요가 없고, 호출 횟수가 "클러스터 수 + 1" 에서 1 로 줄어듭니다.
# =====================================================================================
Write-RunLog -Level 'STEP' -Message '4/6 클러스터 목록 조회'

$allClusters = [System.Collections.Generic.List[object]]::new()

foreach ($rg in $targetResourceGroups) {

    # 아래 주소는 Get-AzAksCluster 가 내부에서 호출하는 ARM REST 엔드포인트입니다.
    # 형식: /subscriptions/{구독}/resourceGroups/{리소스그룹}/providers/{리소스종류}?api-version={버전}
    $listUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rg" +
               "/providers/Microsoft.ContainerService/managedClusters?api-version=$($Const.ApiVersion)"

    $rgCount = 0
    # ARM 목록 API 는 결과가 많으면 여러 페이지로 나눠 주며, 다음 페이지 주소를 nextLink 에 담습니다.
    # nextLink 가 비면 마지막 페이지이므로 반복이 끝납니다.
    while (-not [string]::IsNullOrWhiteSpace($listUri)) {
        $page = (Invoke-ArmRequest -Uri $listUri -Method 'GET' -AccessToken $armToken).Content
        foreach ($c in @($page.value)) { $allClusters.Add($c); $rgCount++ }   # value 에 클러스터 배열이 담깁니다
        $listUri = $page.nextLink
    }
    Write-RunLog -Level 'OK' -Message "클러스터 $rgCount개 조회" -Scope $rg
}

# 클러스터 이름 기준 상시 제외를 여기서 먼저 걸러 냅니다.
$targets = @()
foreach ($c in $allClusters) {
    $matched = $Const.ClusterExcludePatterns | Where-Object { $c.name -like $_ } | Select-Object -First 1
    if ($matched) {
        Write-RunLog -Level 'SKIP' -Message "제외 패턴 '$matched' 에 해당하여 건너뜁니다." -Scope $c.name
        continue
    }
    $targets += $c
}

Write-RunLog -Level 'OK' -Message "전체 $($allClusters.Count)개 중 처리 대상 $($targets.Count)개"

if ($targets.Count -eq 0) {
    Write-RunLog -Level 'INFO' -Message '처리할 클러스터가 없습니다. 종료합니다.'
    Write-Output "====================================================================="
    return
}

# =====================================================================================
# 7. 클러스터 단위 병렬 처리
#    - 클러스터끼리는 병렬, 같은 클러스터 내 노드풀은 순차
#    - 각 러너스페이스는 자기 로그를 모았다가 마지막에 한 번에 출력합니다.
#      그래야 Automation 로그에서 클러스터별 흐름이 끊기지 않고 읽힙니다.
# =====================================================================================
Write-RunLog -Level 'STEP' -Message "5/6 노드풀 조정 시작 (동시 처리 $($Const.ThrottleLimit)개)"

# ConcurrentBag 은 여러 스레드가 동시에 추가해도 안전한 목록입니다.
# 일반 배열(@())은 동시에 추가하면 값이 유실될 수 있어 사용하지 않습니다.
$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

# -Parallel 은 클러스터마다 별도의 러너스페이스(독립된 PowerShell 환경)에서 블록을 실행합니다.
# -ThrottleLimit 은 동시에 돌릴 개수입니다.
$targets | ForEach-Object -ThrottleLimit $Const.ThrottleLimit -Parallel {

    # --- 러너스페이스 초기화 ------------------------------------------------------
    # 러너스페이스는 부모의 함수와 변수를 물려받지 않습니다.
    # ${function:이름} = 문자열  은 그 문자열을 함수로 등록하는 문법이며,
    # $using:변수 는 부모 러너스페이스의 변수를 읽어 오는 문법입니다.
    ${function:Invoke-ArmRequest}  = $using:fnInvokeArm
    ${function:Test-TagExclusion}  = $using:fnTestTag
    ${function:Wait-ArmOperation}  = $using:fnWaitArm
    ${function:Get-KstNow}         = $using:fnGetKstNow
    ${function:Format-LogLine}     = $using:fnFormatLog

    $token  = $using:armToken
    $const  = $using:Const
    $act    = $using:Action
    $dryRun = $using:DryRun
    $today  = $using:todayKst
    $bag    = $using:results

    $cluster = $_
    $cName   = $cluster.name
    $watch   = [System.Diagnostics.Stopwatch]::StartNew()

    # 이 클러스터 전용 로그 버퍼입니다.
    $log = [System.Collections.Generic.List[string]]::new()
    $log.Add((Format-LogLine -Level 'STEP' -Message '처리 시작' -Scope $cName))

    # 결과 기록과 로그 남기기를 한 번에 처리하는 스크립트 블록입니다.
    # 호출할 때는 함수처럼 쓰지 않고 & 연산자로 실행합니다.  예) & $record 'pool1' 'Updated' '메시지' 'OK'
    $record = {
        param($pool, $status, $message, $level)
        $bag.Add([pscustomobject]@{
            Cluster = $cName; NodePool = $pool; Status = $status; Message = $message
        })
        $log.Add((Format-LogLine -Level $level -Message "$pool : $message" -Scope $cName))
    }

    try {
        # --- 7-1. 태그 기반 제외 판정 ---------------------------------------------
        $tagWarn = ''
        $tagReason = Test-TagExclusion -Tags $cluster.tags -TagName $const.ScheduleTagName `
                        -UntilTagName $const.UntilTagName -TodayKst $today -WarnRef ([ref]$tagWarn)
        if (-not [string]::IsNullOrWhiteSpace($tagWarn)) {
            $log.Add((Format-LogLine -Level 'WARN' -Message $tagWarn -Scope $cName))
        }
        if ($tagReason) {
            & $record '-' 'Excluded' $tagReason 'SKIP'
            $log.Add((Format-LogLine -Level 'INFO' -Message "처리 종료 ($([int]$watch.Elapsed.TotalSeconds)초)" -Scope $cName))
            Write-Output ($log -join "`n")
            return
        }

        # --- 7-2. 클러스터 상태 확인 -----------------------------------------------
        # 다른 작업이 진행 중이거나 중지 상태면 변경 요청이 409 로 실패합니다.
        if ($cluster.properties.provisioningState -ne 'Succeeded') {
            & $record '-' 'Skipped' "provisioningState=$($cluster.properties.provisioningState) (다른 작업 진행 중)" 'SKIP'
            Write-Output ($log -join "`n"); return
        }
        if ($cluster.properties.powerState.code -eq 'Stopped') {
            & $record '-' 'Skipped' '클러스터가 Stopped 상태입니다.' 'SKIP'
            Write-Output ($log -join "`n"); return
        }

        # cluster.id 는 "/subscriptions/../resourceGroups/../providers/../managedClusters/이름" 형태의
        # 전체 리소스 경로입니다. 앞에 호스트만 붙이면 이 클러스터의 REST 주소가 됩니다.
        $baseUri  = "https://management.azure.com$($cluster.id)"

        # 목록 조회 응답에 이미 들어 있는 노드풀 정보입니다. 추가 조회가 필요 없습니다.
        $profiles = @($cluster.properties.agentPoolProfiles)
        $log.Add((Format-LogLine -Level 'INFO' -Message "노드풀 $($profiles.Count)개 확인" -Scope $cName))

        # --- 7-3. 노드풀별 판정 후 변경 대상만 확정합니다 --------------------------
        #          여기서 미리 확정해야 "이 클러스터의 마지막 변경"을 정확히 알 수 있어
        #          불필요한 완료 대기를 하지 않습니다.
        $plan = [System.Collections.Generic.List[object]]::new()

        foreach ($pool in $profiles) {
            $pName = $pool.name
            $key   = "$cName/$pName"

            # (1) System 모드 노드풀은 kube-system 파드를 수용하므로 제외합니다.
            if ($const.SkipSystemPool -and $pool.mode -eq 'System') {
                & $record $pName 'Excluded' 'System 모드 노드풀입니다.' 'SKIP'; continue
            }

            # (2) GPU 노드풀은 예약 인스턴스와 드라이버 재설치 영향이 있어 제외합니다.
            if ($const.SkipGpuPool -and $pool.vmSize -match $const.GpuVmSizePattern) {
                & $record $pName 'Excluded' "GPU 노드풀입니다. (vmSize=$($pool.vmSize))" 'SKIP'; continue
            }

            # (3) Autoscaler 가 켜져 있으면 count 지정이 무시되므로 변경하지 않습니다.
            if ($pool.enableAutoScaling -eq $true) {
                & $record $pName 'Excluded' 'Cluster Autoscaler 활성 노드풀입니다.' 'SKIP'; continue
            }

            # (4) 규칙 조회. "클러스터명/노드풀명" 으로 비교하므로 training01/llmtr01 과
            #     training02/llmtr01 이 서로 다른 규칙에 걸립니다.
            #     위에서부터 확인해 처음 매칭되는 규칙 하나만 쓰고 빠져나옵니다.
            $rule = $null; $rulePattern = ''
            foreach ($pattern in $const.ScheduleRules.Keys) {
                if ($key -like $pattern) { $rule = $const.ScheduleRules[$pattern]; $rulePattern = $pattern; break }
            }

            if ($null -eq $rule) {
                # 규칙이 없으면 건드리지 않습니다. 새 노드풀이 밤사이 0 으로 내려가는 것을 막습니다.
                & $record $pName 'Unmanaged' '매칭되는 규칙이 없어 변경하지 않았습니다. 규칙 추가 여부를 검토하시기 바랍니다.' 'WARN'
                continue
            }

            # (5) 값이 'Skip' 이면 상시 제외 대상입니다.
            if ($rule -is [string]) {
                if ($rule -ieq 'Skip') {
                    & $record $pName 'Excluded' "규칙 '$rulePattern' 에 따라 제외되었습니다." 'SKIP'; continue
                }
                # 'Skip' 이 아닌 문자열은 오타일 가능성이 높으므로 조용히 넘기지 않습니다.
                & $record $pName 'Failed' "규칙 '$rulePattern' 의 값이 올바르지 않습니다. (값=$rule)" 'ERROR'; continue
            }

            # 해당 Action 의 목표 값이 정의되어 있는지 확인합니다.
            if (-not $rule.ContainsKey($act)) {
                & $record $pName 'Failed' "규칙 '$rulePattern' 에 $act 목표 값이 없습니다." 'ERROR'; continue
            }
            $target = [int]$rule[$act]

            # (6) 멱등 처리: 이미 목표 노드 수면 호출 자체를 생략합니다.
            if ([int]$pool.count -eq $target) {
                & $record $pName 'NoChange' "이미 목표 노드 수입니다. (count=$target, 규칙=$rulePattern)" 'INFO'
                continue
            }

            $plan.Add([pscustomobject]@{ Name = $pName; Current = $pool; Target = $target; Pattern = $rulePattern })
        }

        if ($plan.Count -eq 0) {
            $log.Add((Format-LogLine -Level 'INFO' -Message "변경 대상 없음. 처리 종료 ($([int]$watch.Elapsed.TotalSeconds)초)" -Scope $cName))
            Write-Output ($log -join "`n"); return
        }
        $log.Add((Format-LogLine -Level 'INFO' -Message "변경 대상 $($plan.Count)개 확정" -Scope $cName))

        # --- 7-4. 확정된 대상만 순차 변경합니다 ------------------------------------
        $idx = 0
        foreach ($item in $plan) {
            $idx++
            $pName = $item.Name
            $cur   = $item.Current
            $desc  = "count $($cur.count) -> $($item.Target) (규칙=$($item.Pattern))"

            if ($dryRun) { & $record $pName 'DryRun' $desc 'DRY'; continue }

            # [대응 cmdlet] Update-AzAksNodePool -ResourceGroupName .. -ClusterName .. -Name .. -NodeCount ..
            # agentPools 는 PATCH 를 지원하지 않아 전체 교체(PUT)만 가능합니다. 즉 바꿀 값만
            # 보내는 것이 아니라 노드풀 설정 전체를 다시 보내야 하며, 빠뜨린 항목은 지워집니다.
            # 그래서 목록 조회로 확보한 현재 프로파일을 그대로 본문으로 쓰고 count 만 덮어씁니다.
            # ConvertTo-Json | ConvertFrom-Json 은 원본 객체를 건드리지 않기 위한 깊은 복사입니다.
            $body = $cur | ConvertTo-Json -Depth 30 | ConvertFrom-Json

            # Azure 가 직접 채우는 읽기 전용 항목은 본문에 있으면 400 오류가 나므로 제거합니다.
            foreach ($ro in @('name','provisioningState','powerState','currentOrchestratorVersion','nodeImageVersion')) {
                if ($body.PSObject.Properties.Name -contains $ro) { $body.PSObject.Properties.Remove($ro) }
            }
            $body.count = [int]$item.Target

            # 방어 검증: PUT 은 전체 교체이므로 본문에서 태그가 빠지면 노드풀 태그가 삭제됩니다.
            $srcTag = if ($cur.PSObject.Properties.Name -contains 'tags'  -and $cur.tags)  { @($cur.tags.PSObject.Properties).Count }  else { 0 }
            $dstTag = if ($body.PSObject.Properties.Name -contains 'tags' -and $body.tags) { @($body.tags.PSObject.Properties).Count } else { 0 }
            if ($dstTag -lt $srcTag) {
                & $record $pName 'Failed' "노드풀 태그 유실 위험이 감지되어 변경을 중단했습니다. (원본 $srcTag개 -> 본문 $dstTag개)" 'ERROR'
                continue
            }

            $log.Add((Format-LogLine -Level 'INFO' -Message "$pName : 변경 요청 ($idx/$($plan.Count)) $desc" -Scope $cName))

            # 변경 대상 주소는 "클러스터 리소스 ID + /agentPools/노드풀명" 입니다.
            # $baseUri 는 목록 조회 응답의 id 값으로 만들었으므로 구독·리소스그룹이 이미 포함됩니다.
            # `? 의 백틱은 PowerShell 이 ?를 변수 구분자로 해석하지 않게 하는 이스케이프입니다.
            $res = Invoke-ArmRequest -Uri "$baseUri/agentPools/$pName`?api-version=$($const.ApiVersion)" `
                                     -Method 'PUT' -AccessToken $token -Body @{ properties = $body }

            # 같은 클러스터에 남은 노드풀이 있으면 완료를 기다립니다(동시 작업 1건 제약).
            # 마지막 노드풀은 WaitForCompletion 이 true 일 때만 기다려 총 실행 시간을 줄입니다.
            if (($idx -lt $plan.Count) -or $const.WaitForCompletion) {
                $state = Wait-ArmOperation -ResponseHeaders $res.Headers -AccessToken $token -TimeoutSeconds $const.OperationTimeout
                if ($state -eq 'Succeeded') { & $record $pName 'Updated' "$desc (완료)" 'OK' }
                else                        { & $record $pName 'Failed'  "$desc (작업 결과: $state)" 'ERROR' }
            }
            else {
                & $record $pName 'Accepted' "$desc (요청 접수, 백그라운드 진행)" 'OK'
            }
        }

        $log.Add((Format-LogLine -Level 'STEP' -Message "처리 완료 ($([int]$watch.Elapsed.TotalSeconds)초)" -Scope $cName))
    }
    catch {
        & $record '-' 'Failed' $_.Exception.Message 'ERROR'
        $log.Add((Format-LogLine -Level 'ERROR' -Message "처리 중단 ($([int]$watch.Elapsed.TotalSeconds)초)" -Scope $cName))
    }

    # 이 클러스터의 로그를 한 덩어리로 출력합니다.
    Write-Output ($log -join "`n")
}

# =====================================================================================
# 8. 결과 집계
#    실패가 하나라도 있으면 예외를 던져 Automation 작업이 Failed 로 표시되게 합니다.
# =====================================================================================
Write-RunLog -Level 'STEP' -Message '6/6 결과 집계'

$summary = @($results) | Sort-Object Cluster, NodePool
$totalWatch.Stop()

Write-Output ""
Write-Output "====================================================================="
Write-Output " 실행 결과 상세"
Write-Output "====================================================================="
Write-Output ("{0,-10} {1,-28} {2,-14} {3}" -f 'STATUS', 'CLUSTER', 'NODEPOOL', 'MESSAGE')
Write-Output ("-" * 110)
foreach ($r in $summary) {
    Write-Output ("{0,-10} {1,-28} {2,-14} {3}" -f $r.Status, $r.Cluster, $r.NodePool, $r.Message)
}

Write-Output ""
Write-Output "====================================================================="
Write-Output " 상태별 집계"
Write-Output "====================================================================="
foreach ($g in ($summary | Group-Object Status | Sort-Object Name)) {
    Write-Output ("  {0,-10} : {1}건" -f $g.Name, $g.Count)
}

$failCount = @($summary | Where-Object { $_.Status -eq 'Failed' }).Count
$okCount   = @($summary | Where-Object { $_.Status -in @('Updated','Accepted') }).Count
$unmanaged = @($summary | Where-Object { $_.Status -eq 'Unmanaged' }).Count

Write-Output ""
Write-RunLog -Level 'INFO' -Message "총 $($summary.Count)건 / 변경 $okCount건 / 실패 $failCount건 / 소요 $([int]$totalWatch.Elapsed.TotalSeconds)초"

if ($unmanaged -gt 0) {
    Write-RunLog -Level 'WARN' -Message "규칙에 없는 노드풀이 $unmanaged개 있습니다. ScheduleRules 추가 여부를 검토하시기 바랍니다."
}
if ($DryRun) {
    Write-Warning "*** DryRun 모드로 실행되어 실제 변경은 없었습니다. DryRun 값을 확인하시기 바랍니다. ***"
}

Write-Output "====================================================================="

if ($failCount -gt 0) {
    throw "[ERROR] $failCount 건의 노드풀 스케줄링이 실패했습니다. 위 상세 로그를 확인합니다."
}

<#
=====================================================================================
 [Automation 스케줄 구성]
 런북마다 스케줄 2개를 연결하고, 파라미터에 그 런북이 담당하는 구독 ID 를 저장합니다.
 시각은 환경별로 다르게 잡아도 코드는 동일합니다.
   dev 런북 : 08:30 Action=ScaleOut / 20:00 Action=ScaleIn
   stg 런북 : 09:00 Action=ScaleOut / 21:00 Action=ScaleIn
 입력 폼에 뜨는 칸은 Action 과 SubscriptionId 둘뿐입니다.

 [부하테스트 등 이벤트성 제외]
 Azure Portal > 대상 AKS 클러스터 > 태그 메뉴에서 처리합니다.
   기간이 정해진 경우 : AutoScaleScheduleUntil = 2026-10-20
                        해당 날짜까지 제외되고 다음 날부터 자동 복귀합니다.
   기간이 미정인 경우 : AutoScaleSchedule = Disabled  (작업 종료 후 태그 삭제)
 런북과 스케줄은 수정하지 않습니다.

 [ScheduleRules 작성 규칙]
 키는 "클러스터명/노드풀명" 이며 양쪽 모두 와일드카드가 됩니다.
 위에서부터 확인해 처음 매칭되는 규칙 하나만 적용되므로 순서가 중요합니다.
   'training01/llmtr01' = @{ ScaleOut = 1; ScaleIn = 1 }   # 개별 지정
   '*/devops'           = 'Skip'                            # 상시 제외
   'training03/*'       = 'Skip'                            # 클러스터 전체 제외
   '*/fabrix*'          = @{ ScaleOut = 7; ScaleIn = 1 }   # 공통 규칙
 개별 지정과 제외를 공통 규칙보다 위에 두어야 의도대로 동작합니다.

 [관리 ID 및 권한]
 Automation 계정 > 설정 > ID > 시스템 할당 탭에서 상태를 켬으로 둡니다.
 해당 ID(개체)에 대상 리소스 그룹 범위로 아래 권한을 부여합니다.
   Microsoft.ContainerService/managedClusters/read
   Microsoft.ContainerService/managedClusters/agentPools/read
   Microsoft.ContainerService/managedClusters/agentPools/write
 대상 구독이 Automation 계정과 다른 구독이면, 그 구독 쪽 리소스 그룹에도 같은 권한이 필요합니다.

 [IaC 사용 시 주의]
 AKS 를 Terraform/Bicep 으로 관리하는 경우, Portal 에서 붙인 제외 태그가 다음 apply 때
 사라질 수 있습니다. 해당 태그 키를 IaC 에서 무시하도록 설정해야 합니다.
=====================================================================================
#>
