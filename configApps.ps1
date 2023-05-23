#####################################################################
# Initialize the environment
#####################################################################
$AgConfig = Import-PowerShellDataFile -Path $Env:AgConfigPath
$AgToolsDir = $AgConfig.AgDirectories["AgToolsDir"]
$AgIconsDir = $AgConfig.AgDirectories["AgIconDir"]
$AgAppsRepo = $AgConfig.AgDirectories["AgAppsRepo"]
$githubAccount = $env:githubAccount
$githubBranch = $env:githubBranch
$githubUser = $env:githubUser
$githubPat = $env:GITHUB_TOKEN
$resourceGroup = $env:resourceGroup
$azureLocation = $env:azureLocation
$spnClientId = $env:spnClientId
$spnClientSecret = $env:spnClientSecret
$spnTenantId = $env:spnTenantId
$adminUsername = $env:adminUsername
$acrName = $Env:acrName.ToLower()
$cosmosDBName = $Env:cosmosDBName
$cosmosDBEndpoint = $Env:cosmosDBEndpoint
$templateBaseUrl = $env:templateBaseUrl
$appClonedRepo = "https://github.com/$githubUser/jumpstart-agora-apps"
$adxClusterName = $env:adxClusterName
$namingGuid = $env:namingGuid
$appsRepo = "jumpstart-agora-apps"
$adminPassword = $env:adminPassword
$gitHubAPIBaseUri = "https://api.github.com"

#####################################################################
# Installing flux extension on clusters
#####################################################################
Write-Host "[$(Get-Date -Format t)] INFO: Installing flux extension on clusters (Step 9/15)" -ForegroundColor DarkGreen
$retryCount = 0
$maxRetries = 3
$resourceTypes = @($AgConfig.ArcK8sResourceType, $AgConfig.AksResourceType)
$resources = Get-AzResource -ResourceGroupName $env:resourceGroup | Where-Object { $_.ResourceType -in $resourceTypes }

$jobs = @()

foreach ($resource in $resources) {
    $resourceName = $resource.Name
    $resourceType = $resource.Type
    Write-Host "[$(Get-Date -Format t)] INFO: Installing flux extension on $resourceName" -ForegroundColor Gray
    if ($resourceType -eq $AgConfig.ArcK8sResourceType) {
        $job = Start-Job -ScriptBlock {
            param($resourceName, $resourceType)
            az k8s-extension create --name flux `
                --extension-type Microsoft.flux `
                --scope cluster `
                --cluster-name $resourceName `
                --resource-group $env:resourceGroup `
                --cluster-type connectedClusters `
                --auto-upgrade false
            
            $provisioningState = az k8s-extension show --cluster-name $resourceName `
                --resource-group $env:resourceGroup `
                --cluster-type connectedClusters `
                --name flux `
                --query provisioningState `
                --output tsv

            [PSCustomObject]@{
                ResourceName = $resourceName
                ResourceType = $resourceType
                ProvisioningState = $provisioningState
            }
        } -ArgumentList $resourceName, $resourceType

        $jobs += $job
    }
    else {
        $job = Start-Job -ScriptBlock {
            param($resourceName, $resourceType)

            az k8s-extension create --name flux `
                --extension-type Microsoft.flux `
                --scope cluster `
                --cluster-name $resourceName `
                --resource-group $env:resourceGroup `
                --cluster-type managedClusters `
                --auto-upgrade false

            $provisioningState = az k8s-extension show --cluster-name $resourceName `
                --resource-group $env:resourceGroup `
                --cluster-type managedClusters `
                --name flux `
                --query provisioningState `
                --output tsv

            [PSCustomObject]@{
                ResourceName = $resourceName
                ResourceType = $resourceType
                ProvisioningState = $provisioningState
            }
        } -ArgumentList $resourceName, $resourceType
     
        $jobs += $job
    }
}

# Wait for all jobs to complete
$null = $jobs | Wait-Job

# Check provisioning states for each resource
foreach ($job in $jobs) {
    $result = Receive-Job -Job $job
    $resourceName = $result.ResourceName
    $resourceType = $result.ResourceType
    $provisioningState = $result.ProvisioningState

    if ($provisioningState -ne "Succeeded") {
        Write-Host "[$(Get-Date -Format t)] INFO: flux extension is not ready yet for $resourceName. Retrying in 10 seconds..." -ForegroundColor Gray
        Start-Sleep -Seconds 10
        $retryCount++
    }
    else {
        Write-Host "[$(Get-Date -Format t)] INFO: flux extension installed successfully on $resourceName" -ForegroundColor Gray
    }
}

if ($retryCount -eq $maxRetries) {
    Write-Host "[$(Get-Date -Format t)] ERROR: Retry limit reached. Exiting..." -ForegroundColor White -BackgroundColor Red
}

# Clean up jobs
$jobs | Remove-Job


#####################################################################
# Setup Azure Container registry pull secret on clusters
#####################################################################
Write-Host "[$(Get-Date -Format t)] INFO: Configuring secrets on clusters (Step 10/15)" -ForegroundColor DarkGreen
foreach ($cluster in $AgConfig.SiteConfig.GetEnumerator()) {
    $clusterName = $cluster.Name.ToLower()
    $namespace = $cluster.value.posNamespace
    Write-Host "[$(Get-Date -Format t)] INFO: Configuring Azure Container registry on $clusterName"
    kubectx $clusterName | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\ClusterSecrets.log")
    kubectl create secret docker-registry acr-secret `
        --namespace $namespace `
        --docker-server="$acrName.azurecr.io" `
        --docker-username="$env:spnClientId" `
        --docker-password="$env:spnClientSecret" | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\ClusterSecrets.log")
}

#####################################################################
# Create secrets for GitHub actions
#####################################################################
Write-Host "[$(Get-Date -Format t)] INFO: Creating Kubernetes secrets" -ForegroundColor Gray
$cosmosDBKey = $(az cosmosdb keys list --name $cosmosDBName --resource-group $resourceGroup --query primaryMasterKey --output tsv)
foreach ($cluster in $AgConfig.SiteConfig.GetEnumerator()) {
    $clusterName = $cluster.Name.ToLower()
    Write-Host "[$(Get-Date -Format t)] INFO: Creating Cosmos DB Kubernetes secrets on $clusterName" -ForegroundColor Gray
    kubectx $cluster.Name.ToLower() | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\ClusterSecrets.log")
    kubectl create secret generic postgrespw --from-literal=POSTGRES_PASSWORD='Agora123!!' --namespace $cluster.value.posNamespace | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\ClusterSecrets.log")
    kubectl create secret generic cosmoskey --from-literal=COSMOS_KEY=$cosmosDBKey --namespace $cluster.value.posNamespace | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\ClusterSecrets.log")
    Write-Host "[$(Get-Date -Format t)] INFO: Creating GitHub personal access token Kubernetes secret on $clusterName" -ForegroundColor Gray
    kubectl create secret generic github-token --from-literal=token=$githubPat --namespace $cluster.value.posNamespace | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\ClusterSecrets.log")
}
Write-Host "[$(Get-Date -Format t)] INFO: Cluster secrets configuration complete." -ForegroundColor Green
Write-Host


#####################################################################
# Configuring applications on the clusters using GitOps
#####################################################################
Write-Host "[$(Get-Date -Format t)] INFO: Configuring GitOps. (Step 12/15)" -ForegroundColor DarkGreen
foreach ($app in $AgConfig.AppConfig.GetEnumerator()) {
    foreach ($cluster in $AgConfig.SiteConfig.GetEnumerator()) {
        Write-Host "[$(Get-Date -Format t)] INFO: Creating GitOps config for pos application on $($cluster.Value.ArcClusterName+"-$namingGuid")" -ForegroundColor Gray
        $store = $cluster.value.Branch.ToLower()
        $clusterName = $cluster.value.ArcClusterName+"-$namingGuid"
        $branch = $cluster.value.Branch.ToLower()
        $configName = $app.value.GitOpsConfigName.ToLower()
        $clusterType = $cluster.value.Type
        $namespace = $app.value.Namespace
        $appName = $app.Value.KustomizationName
        $appPath= $app.Value.KustomizationPath

        if($clusterType -eq "AKS"){
            $type = "managedClusters"
            $clusterName= $cluster.value.ArcClusterName
        }else{
            $type = "connectedClusters"
        }
        if($branch -eq "main"){
            $store = "dev"
        }

while ($workflowStatus.status -ne "completed") {
    Write-Host "INFO: Waiting for pos-app-initial-images-build workflow to complete" -ForegroundColor Gray
    Start-Sleep -Seconds 10
    $workflowStatus = (gh run list --workflow=pos-app-initial-images-build.yml --json status) | ConvertFrom-Json
}

foreach ($cluster in $AgConfig.SiteConfig.GetEnumerator()) {
    Start-Job -Name gitops -ScriptBlock {
        $AgConfig = $using:AgConfig
        $cluster = $using:cluster
        $namingGuid = $using:namingGuid
        $resourceGroup = $using:resourceGroup
        $appClonedRepo = $using:appClonedRepo
        $AgConfig.AppConfig.GetEnumerator() | sort-object -Property @{Expression = { $_.value.Order }; Ascending = $true } | ForEach-Object {
            $app = $_
            $store = $cluster.value.Branch.ToLower()
            $clusterName = $cluster.value.ArcClusterName + "-$namingGuid"
            $branch = $cluster.value.Branch.ToLower()
            $configName = $app.value.GitOpsConfigName.ToLower()
            $clusterType = $cluster.value.Type
            $namespace = $app.value.Namespace
            $appName = $app.Value.KustomizationName
            $appPath = $app.Value.KustomizationPath
            Write-Host "[$(Get-Date -Format t)] INFO: Creating GitOps config for $configName on $($cluster.Value.ArcClusterName+"-$namingGuid")" -ForegroundColor Gray
            if ($clusterType -eq "AKS") {
                $type = "managedClusters"
                $clusterName = $cluster.value.ArcClusterName
            }
            else {
                $type = "connectedClusters"
            }
            if ($branch -eq "main") {
                $store = "dev"
            }

            kubectx $cluster.Name.ToLower() | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\GitOps-$clusterName.log")
            # Wait for Kubernetes API server to become available
            $apiServer = kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
            $apiServerAddress = $apiServer -replace '.*https://| .*$'
            $apiServerFqdn = ($apiServerAddress -split ":")[0]
            $apiServerPort = ($apiServerAddress -split ":")[1]

            do {
                $result = Test-NetConnection -ComputerName $apiServerFqdn -Port $apiServerPort -WarningAction SilentlyContinue
                if ($result.TcpTestSucceeded) {
                    Write-Host "[$(Get-Date -Format t)] INFO: Kubernetes API server $apiServer is available" -ForegroundColor Gray
                    break
                }
                else {
                    Write-Host "[$(Get-Date -Format t)] INFO: Kubernetes API server $apiServer is not yet available. Retrying in 5 seconds..." -ForegroundColor Gray
                    Start-Sleep -Seconds 5
                }
            } while ($true)

            az k8s-configuration flux create `
                --cluster-name $clusterName `
                --resource-group $resourceGroup `
                --name $configName `
                --cluster-type $type `
                --url $appClonedRepo `
                --branch $Branch `
                --sync-interval 5s `
                --kustomization name=$appName path=$appPath/$store prune=true `
                --timeout 30m `
                --namespace $namespace `
                --only-show-errors `
            | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\GitOps-$clusterName.log")

            do {
                $configStatus = $(az k8s-configuration flux show --name $configName --cluster-name $clusterName --cluster-type $type --resource-group $resourceGroup -o json) | convertFrom-JSON
                if ($configStatus.ComplianceState -eq "Compliant") {
                    Write-Host "[$(Get-Date -Format t)] INFO: GitOps configuration $configName is compliant on $clusterName" -ForegroundColor DarkGreen | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\GitOps-$clusterName.log")
                }
                else {
                    Write-Host "[$(Get-Date -Format t)] INFO: GitOps configuration $configName is not yet ready on $clusterName...waiting 45 seconds" -ForegroundColor Gray | Out-File -Append -FilePath ($AgConfig.AgDirectories["AgLogsDir"] + "\GitOps-$clusterName.log")
                    Start-Sleep -Seconds 45
                }
            } until ($configStatus.ComplianceState -eq "Compliant")
        }
    }
}

    while ($(Get-Job -Name gitops).State -eq 'Running') {
        #Write-Host "[$(Get-Date -Format t)] INFO: Waiting for GitOps configuration to complete on all clusters...waiting 60 seconds" -ForegroundColor Gray
        Receive-Job -Name gitops -WarningAction SilentlyContinue
        Start-Sleep -Seconds 60
    }

    Get-Job -name gitops | Remove-Job
    Write-Host "[$(Get-Date -Format t)] INFO: GitOps configuration complete." -ForegroundColor Green
    Write-Host
