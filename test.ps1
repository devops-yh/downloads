#Requires -Version 7.6

param(
    [Parameter(Mandatory = $true)]
    [string] $SubscriptionId
)

Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

$s = Get-AzPostgreSqlFlexibleServer -SubscriptionId $SubscriptionId -ErrorAction Stop | Select-Object -First 1

Write-Output "===== 속성 목록 ====="
Write-Output (($s | Get-Member -MemberType Property, NoteProperty |
    Select-Object Name, MemberType | Format-Table -AutoSize | Out-String).Trim())

Write-Output "`n===== 주요 값 ====="
Write-Output "Name  = $($s.Name)"
Write-Output "Id    = $($s.Id)"
Write-Output "State = $($s.State)"
Write-Output "RG    = $($s.ResourceGroupName)"
Write-Output "Tag   = $($s.Tag  | ConvertTo-Json -Compress)"
Write-Output "Tags  = $($s.Tags | ConvertTo-Json -Compress)"
