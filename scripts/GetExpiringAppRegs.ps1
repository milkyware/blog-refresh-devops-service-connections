<#
.SYNOPSIS
    Retrieve a list of expiring Azure App Registrations
.PARAMETER AppRegName
    Regex to filter Azure App Registrations display name by
.PARAMETER WarningThreshold
    Configure the number of days before a secret expires to retrieving "expiring" Azure App Registrations. Defaults to 30 days
.PARAMETER IncludeOwners
    Lookup owner details for each App Registration. This results in additional requests to AAD which impacts performance
.EXAMPLE
    .\GetExpiringAppRegs.ps1
    Retrieves a list of Azure App Registrations with secrets expiring within the default 30 days

    .\GetExpiringAppRegs.ps1 -WarningThreshold 60
    Retrieves a list of Azure App Registrations with secrets expiring within a customised window of 60 days

    .\GetExpiringAppRegs.ps1 -AppRegName "^devops-"
    Retrieves a list of Azure App Registrations with secrets expiring within the default 30 days matching "^devops-"

    .\GetExpiringAppRegs.ps1 -IncludeOwners
    Retrieves a list of Azure App Registrations with secrets expiring within the default 30 days along with the owners of the affected App Registrations
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$AppRegName,
    [Parameter()]
    [int]$WarningThreshold = 30,
    [Parameter()]
    [switch]$IncludeOwners
)
begin {
    $name = @{Name="Name"; Expression={$_.displayName}}
    $objectId = @{Name="ObjectId"; Expression={$_.id}}
    $appId = @{Name="AppId"; Expression={$_.appId}}
    $notes = @{Name="Notes"; Expression={$_.notes}}
    $expiresOn = @{Name="ExpiresOn"; Expression={
        ($_.passwordCredentials | Sort-Object -Property startDateTime -Top 1).endDateTime
    }}

    $ownerName = @{Name="Name"; Expression={$_.displayName}}
    $ownerObjectId = @{Name="ObjectId"; Expression={$_.id}}
    $ownerEmail = @{Name="Email"; Expression={$_.mail}}
    $ownerAppId = @{Name="AppId"; Expression={[string]$_.appId}}
}
process {
    Write-Information "Getting expired/expiring app registrations"

    $thresholdDate = [datetime]::Today.AddDays($WarningThreshold)
    Write-Verbose "thresholdDate=$thresholdDate"

    Write-Debug "Filtering app regs with expired/expiring secrets"
    $appRegs = az ad app list --all | ConvertFrom-Json
        | Where-Object {$_.displayName -match $AppRegName}
        | Where-Object {$_.passwordCredentials.Count -gt 0}
        | Where-Object {
            $expiringCreds = ($_.passwordCredentials | Where-Object {($_.endDateTime -lt $thresholdDate)}).Count -gt 0
            $newCreds = ($_.passwordCredentials | Where-Object {$_.endDateTime -gt $thresholdDate}).Count -gt 0
            $expiringCreds -and -not $newCreds
        } 
        | Sort-Object -Property displayName 
        | Select-Object -Property $name,$objectId,$appId,$notes,$expiresOn
    
    Write-Verbose "appRegCount=$($appRegs.Count)"
    if (-not $IncludeOwners)
    {
        return $appRegs
    }

    Write-Debug "Getting app reg owners"
    $appRegsWithOwners = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

    $appRegs | ForEach-Object -Parallel {
        $InformationPreference = $using:InformationPreference
        $DebugPreference = $using:DebugPreference
        $VerbosePreference = $using:VerbosePreference

        Write-Debug "Getting owners for $($_.Name)"
        $owners = az ad app owner list --id "$($_.ObjectId)" | ConvertFrom-Json | Select-Object $using:ownerName,$using:ownerObjectId,$using:ownerEmail,$using:ownerAppId

        $_ | Add-Member -MemberType NoteProperty -Name "Owners" -Value $owners
        ($using:appRegsWithOwners).Add($_) | Out-Null
    }

    return $appRegsWithOwners
}