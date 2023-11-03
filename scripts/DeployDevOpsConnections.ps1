<#
.SYNOPSIS
    Automate the provisioning of Azure DevOps Service Connections for a a given App Registration
.DESCRIPTION
    Upserts Azure Service Connections to the specified Azure DevOps Team Project for the given App Registration. A service connection is created for each of the provided Azure subscriptions.

    This script uses Az CLI to perform actions with the account being used required to read and modify Azure App Regs as well as the token having the "Endpoint Administrators" permission for the given Team Project. If the Azure Pipeline service token is used the "Build Service" will need this permission.

    App Reg metadata is retrieved as well as a secret which is then used to upsert service connections in the given DevOps org and project for each of the stated Azure subscriptions. Created service connections are in the format of appreg-subscription. Existing service connection(s) associated with an App Reg, these are updated with the new secret
.PARAMETER Organisation
    Url to the Azure DevOps organisation
.PARAMETER Project
    Name of the Azure DevOps project to create the service connection in
.PARAMETER Token
    A PAT (Personal Access Token) with permissions to create service connections
.PARAMETER AppReg
    Name of the Azure App Registration which the service connections will authenticate as
.PARAMETER Subscriptions
    An array of Azure Subscription names which will each have a service connection created for it using the App Registration
.EXAMPLE
    .\DeployDevOpsConnections.ps1 -Organisation "https://dev.azure.com/devopsorg" -Project "DevOpsProject" -Token $token -AppReg $appReg -Subscriptions "azure-001","azure-002"
    This will retrieve necessary metadata for "appreg" and reset a secret. This metadata and secret will then be used to create service connections in the given DevOps org and project for each of the stated Azure subscriptions. The created service connections are in the format of appreg-subscription. If there are already service connection(s) associated with the App Reg, these are updated with the new secret
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
    [Parameter(Mandatory=$true)]
    [string]$AppReg,
    [Parameter()]
    [string[]]$Subscriptions
)
process {
    function UpsertServiceConnection {
        [CmdletBinding(SupportsShouldProcess=$true)]
        param (
            [string]$Organisation,
            [string]$Project,
            [string]$SubscriptionId,
            [string]$SubscriptionName,
            [string]$AppRegId,
            [string]$AppRegName,
            [string]$AppTenantId,
            [string]$AppRegSecret
        )
        process {
            Write-Information "Deploying service connection for $AppRegName to $SubscriptionName"

            Write-Debug "Checking for existing service connection for $AppRegName to $SubscriptionName"
            $serviceConnection = az devops service-endpoint list --organization $Organisation --project $Project | ConvertFrom-Json | Where-Object {$_.authorization.parameters.serviceprincipalid -match "$AppRegId" -and $_.data.subscriptionName -eq $SubscriptionName}
            if ($serviceConnection) 
            {
                $serviceConnectionFile = [System.IO.Path]::GetTempFileName()
                Write-Verbose "serviceConnectionFile=$serviceConnectionFile"
                try {
                    Write-Debug "Adding updated secret to service connection definition"
                    $serviceConnection.authorization.parameters | Add-Member -MemberType NoteProperty -Name "serviceprincipalkey" -Value $AppRegSecret

                    Write-Debug "Temp exporting service connection definition"
                    $serviceConnection | ConvertTo-Json -Depth 10 | Set-Content -Path $serviceConnectionFile

                    Write-Debug "Updating service connection $($serviceConnection.name)"
                    if ($PSCmdlet.ShouldProcess("Updated service connection $($serviceConnection.name)"))
                    {
                        az devops invoke --org $Organisation --http-method PUT --area serviceendpoint --resource endpoints --route-parameters "project=$Project" "endpointId=$($serviceConnection.id)" -o json --in-file $serviceConnectionFile | Out-Null
                        Write-Information "Updated service connection $($serviceConnection.name) successfully"
                    }
                }
                finally {
                    Write-Debug "Removing service connection update file"
                    Remove-Item -Path $serviceConnectionFile -Force -WhatIf:$false
                }
                return
            }

            $serviceConnectionName = "$AppRegName-$SubscriptionName"
            Write-Debug "Creating service connection `"$serviceConnectionName`""
            if ($PSCmdlet.ShouldProcess("Created service connection $serviceConnectionName"))
            {
                $env:AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY = $AppRegSecret

                $serviceConnection = az devops service-endpoint azurerm create --organization $Organisation --project $Project --name $serviceConnectionName --azure-rm-service-principal-id $AppRegId --azure-rm-subscription-id $SubscriptionId --azure-rm-subscription-name $SubscriptionName --azure-rm-tenant-id $AppTenantId | ConvertFrom-Json
                Write-Information "Created service connection $serviceConnectionName successfully"
            }
        }
    }

    Write-Information "Deploying service connection(s)"

    Write-Verbose "Organisation=$Organisation"
    Write-Verbose "Project=$Project"
    Write-Verbose "AppReg=$AppReg"

    Write-Debug "Logging into DevOps using Pipeline token"
    $env:AZURE_DEVOPS_EXT_PAT = $Token

    $appRegObj = az ad app list --query "[?displayName == '$AppReg']" --all | ConvertFrom-Json
    if (-not $appRegObj) 
    {
        throw "Failed to find app reg $AppReg"
    }
    Write-Verbose "appRegObjectId=$($appRegObj.id)"
    Write-Verbose "appRegAppId=$($appRegObj.appId)"

    Write-Debug "Resetting secret for $AppReg"
    if ($PSCmdlet.ShouldProcess("$AppReg password reset"))
    {
        $appRegCreds = az ad app credential reset --id $appRegObj.id | ConvertFrom-Json
        Write-Verbose "secret=$($appRegCreds.password)"
    }
    else
    {
        $appRegCreds = @{
            password = "password"
            tenant = [guid]::Empty.ToString()
        }
    }

    foreach ($s in $Subscriptions.ToLower())
    {
        Write-Debug "Retrieving subscription"
        $subscription = az account list --query "[?name=='$s']" --all | ConvertFrom-Json
        if (-not $subscription)
        {
            Write-Warning "Unable to find subscription $s"
            continue;
        }
        Write-Verbose "subscriptionId=$($subscription.id)"

        $serviceConnParams = @{
            Organisation = $Organisation
            Project = $Project
            SubscriptionId = $subscription.id
            SubscriptionName = $s
            AppRegId = $appRegObj.appId
            AppRegName = $AppReg
            AppTenantId = $appRegCreds.tenant
            AppRegSecret = $appRegCreds.password
        }

        UpsertServiceConnection @serviceConnParams
    }   
}