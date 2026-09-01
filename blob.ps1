# ==========================================================
# 런북명(예): Get-BlobCapacityBySubscription
# 파라미터: SubscriptionId (필수)
# 인증: 시스템 할당 관리 ID
# 권한: 대상 구독에 Reader
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId
)

Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
$sub = Get-AzSubscription -SubscriptionId $SubscriptionId

Write-Output "===== TARGET: $($sub.Name) / $SubscriptionId ====="

$startTime = (Get-Date).AddDays(-3)
$endTime   = Get-Date

$result = New-Object System.Collections.Generic.List[object]

$accounts = Get-AzStorageAccount

foreach ($acc in $accounts) {

    $blobResourceId = "$($acc.Id)/blobServices/default"
    $blobGB = $null

    try {
        $metric = Get-AzMetric -ResourceId $blobResourceId `
                               -MetricName "BlobCapacity" `
                               -AggregationType Average `
                               -StartTime $startTime `
                               -EndTime $endTime `
                               -TimeGrain 01:00:00 `
                               -WarningAction SilentlyContinue `
                               -ErrorAction Stop

        $latest = $metric.Data |
                  Where-Object { $null -ne $_.Average } |
                  Sort-Object TimeStamp -Descending |
                  Select-Object -First 1

        if ($latest) { $blobGB = [math]::Round($latest.Average / 1GB, 2) }
    }
    catch {
        Write-Warning "메트릭 조회 실패: $($acc.StorageAccountName)"
    }

    $result.Add([PSCustomObject]@{
        Subscription   = $sub.Name
        ResourceGroup  = $acc.ResourceGroupName
        StorageAccount = $acc.StorageAccountName
        Location       = $acc.PrimaryLocation
        Sku            = $acc.Sku.Name
        BlobGB         = $blobGB
    })
}

# ---------- 출력 1: 상세 (CSV 형식) ----------
Write-Output "===== DETAIL (CSV) ====="
$result |
    Sort-Object @{Expression='BlobGB'; Descending=$true} |
    ConvertTo-Csv -NoTypeInformation |
    ForEach-Object { Write-Output $_ }

# ---------- 출력 2: 구독 합계 ----------
$totalGB = [math]::Round((($result | Measure-Object BlobGB -Sum).Sum), 2)

Write-Output ""
Write-Output "===== SUMMARY ====="
Write-Output "Subscription,AccountCount,TotalGB,TotalTB"
Write-Output "$($sub.Name),$($result.Count),$totalGB,$([math]::Round($totalGB / 1024, 4))"
