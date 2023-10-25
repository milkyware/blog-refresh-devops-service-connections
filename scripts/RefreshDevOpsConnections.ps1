<#
.SYNOPSIS
    Retrieves a list of expiring Azure App Registrations and automates refreshing the associated DevOps service connections
.DESCRIPTION
    This is a wrapper around the "GetExpiringAppRegs.ps1" and "DeployDevOpsConnections.ps1" scripts. A list of expiring App Regs is retrieved and looped through. If specified, App Regs not meeting a naming convention are ignored then the AppId of the AppReg is used to check for associated service connections. The Azure subscription for the related service connections is then resolved and the refresh of these connections is then triggered.

    This script uses Az CLI to perform actions with the account being used required to read and modify Azure App Regs as well as the token having the "Endpoint Administrators" permission for the given Team Project. If the Azure Pipeline service token is used the "Build Service" will need this permission.
.PARAMETER Organisation
    Url to the Azure DevOps organisation
.PARAMETER Project
    Name of the Azure DevOps project to refresh the service connection in
.PARAMETER Token
    A PAT (Personal Access Token) with permissions to recreate service connections
.PARAMETER AppRegNamingConvention
    If a naming convention is used, this filters out expiring App Regs not meeting the convention using Regex to improve performance
.PARAMETER WarningThreshold
    Configure the number of days before a secret expires to retrieving "expiring" Azure App Registrations. Defaults to 30 days
.EXAMPLE
    .\RefreshDevOpsConnections.ps1 -Organisation "https://dev.azure.com/devopsorg" -Project "DevOpsProject" -Token $token
    Retrieves a list of Azure App Registrations with secrets expiring within the default 30 days, evaluates if they have service connections associated and recreates

    .\RefreshDevOpsConnections.ps1 -Organisation "https://dev.azure.com/devopsorg" -Project "DevOpsProject" -Token $token -WarningThreshold 60
    Retrieves a list of Azure App Registrations with secrets expiring within 360 days, evaluates if they have service connections associated and recreates

    .\RefreshDevOpsConnections.ps1 -Organisation "https://dev.azure.com/devopsorg" -Project "DevOpsProject" -Token $token -AppRegNamingConvention "devops-"
    Retrieves a list of Azure App Registrations with secrets expiring within the default 30 days. To help with performance, App Regs not meeting the "devops-" naming convention are filtered out immediately
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param (
    [Parameter(Mandatory=$true)]
    [ValidateScript({$_.StartsWith("https://dev.azure.com/")})]
    [string]$Organisation,
    [Parameter(Mandatory=$true)]
    [string]$Project,
    [Parameter(Mandatory=$true)]
    [string]$Token,
    [Parameter()]
    [string]$AppRegNamingConvention,
    [Parameter()]
    [int]$WarningThreshold = 30
)
process {
    Write-Information "Refreshing service connections for expired/expiring App Regs"

    Write-Verbose "organisation=$Organisation"
    Write-Verbose "project=$Project"

    $appRegs = . "$PSScriptRoot\GetExpiringAppRegs.ps1" -AppRegName $AppRegNamingConvention -WarningThreshold $WarningThreshold

    if ($appRegs.Count -eq 0)
    {
        Write-Information "No expired/expiring App Regs found"
        return;
    }

    Write-Debug "Logging into DevOps using Pipeline token"
    [System.Environment]::SetEnvironmentVariable("AZURE_DEVOPS_EXT_PAT", $Token)

    foreach ($ar in $appRegs)
    {
        Write-Debug "Getting service connections for $($ar.Name)"
        Write-Verbose "appId=$($ar.AppId)"
        $serviceConnections = az devops service-endpoint list --organization $Organisation --project $Project | ConvertFrom-Json | Where-Object {$_.authorization.parameters.serviceprincipalid -eq $ar.AppId}
        Write-Verbose "serviceConnectionCount=$($serviceConnections.Count)"

        if ($serviceConnections.Count -eq 0)
        {
            Write-Debug "No service connections found for $($ar.Name)"
            continue;
        }

        $subscriptions = $serviceConnections.data.subscriptionName
        Write-Verbose "subscriptions=$subscriptions"

        $deployDevOpsConnectionParams = @{
            Organisation = $Organisation
            Project = $Project
            Token = $Token
            AppReg = $($ar.Name)
            Subscriptions = $subscriptions
        }
        Write-Information "$($ar.Name) expires on $($ar.ExpiresOn), refreshing service connections"
        . "$PSScriptRoot\DeployDevOpsConnections.ps1" @deployDevOpsConnectionParams
    }
}