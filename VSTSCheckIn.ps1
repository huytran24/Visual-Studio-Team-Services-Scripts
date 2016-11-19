param([string]$buildRunAsUserPassword = $args[0]) 

Write-Host "=========== VSTSCheckin.ps1 started... ==========="

if (-not $buildRunAsUserPassword)
{
	Write-Error "This script needs $(BuildRunAsUserPassword) variable to work"
	exit 1
}

if (-not $env:BuildRunAsUserName)
{
	Write-Error "This script needs $(BuildRunAsUserName) variable to work"
	exit 1
}


$agentWorkerModulesPath = "$($env:AGENT_HOMEDIRECTORY)\externals\vstshost"
$agentDistributedTaskInternalModulePath = "$agentWorkerModulesPath\Microsoft.TeamFoundation.DistributedTask.Task.Internal"
$agentDistributedTaskCommonModulePath = "$agentWorkerModulesPath\Microsoft.TeamFoundation.DistributedTask.Task.Common"

Write-Host "Modifying the PSModulePath..."

$env:PSModulePath = $env:PSModulePath + ";$($agentWorkerModulesPath)"
$env:PSModulePath = $env:PSModulePath + ";$($agentDistributedTaskInternalModulePath)"
$env:PSModulePath = $env:PSModulePath + ";$($agentDistributedTaskCommonModulePath)"

Write-Host "=========== This script uses the below environment variables ==========="

Write-Host "    PSModulePath: $($env:PSModulePath) "
Write-Host "    BUILD_REPOSITORY_PROVIDER: $($env:BUILD_REPOSITORY_PROVIDER) "
Write-Host "    BUILD_SOURCESDIRECTORY: $($env:BUILD_SOURCESDIRECTORY) "
Write-Host "    SYSTEM_TEAMPROJECTID: $($env:SYSTEM_TEAMPROJECTID) "
Write-Host "    BUILD_REPOSITORY_URI : $($env:BUILD_REPOSITORY_URI) "
Write-Host "    BUILD_REPOSITORY_TFVC_WORKSPACE : $($env:BUILD_REPOSITORY_TFVC_WORKSPACE) "
Write-Host "========================================================================"

Write-Host "Importing VSTS Module: Microsoft.TeamFoundation.DistributedTask.Task.Internal"
Import-Module "Microsoft.TeamFoundation.DistributedTask.Task.Internal"

Write-Host "Importing VSTS Module: Microsoft.TeamFoundation.DistributedTask.Task.Common"
Import-Module "Microsoft.TeamFoundation.DistributedTask.Task.Common"

Add-Type -AssemblyName "System.Net"
Add-Type -Path "$($agentWorkerModulesPath)\Microsoft.TeamFoundation.Client.dll"
Add-Type -Path "$($agentWorkerModulesPath)\Microsoft.TeamFoundation.Common.dll"
Add-Type -Path "$($agentWorkerModulesPath)\Microsoft.TeamFoundation.VersionControl.Client.dll"
Add-Type -Path "$($agentWorkerModulesPath)\Microsoft.TeamFoundation.WorkItemTracking.Client.dll"
Add-Type -Path "$($agentWorkerModulesPath)\Microsoft.TeamFoundation.Diff.dll"

function Get-SourceProvider {

    Write-Debug "Entering Get-SourceProvider"
    $provider = @{
        Name = $env:BUILD_REPOSITORY_PROVIDER
        SourcesRootPath = $env:BUILD_SOURCESDIRECTORY
        TeamProjectId = $env:SYSTEM_TEAMPROJECTID
    }
    $success = $false
    try {
        if ($provider.Name -eq 'TfsVersionControl') {

			$tfsServer = New-Object System.Uri($env:BUILD_REPOSITORY_URI)
			$netCred = New-Object System.Net.NetworkCredential($env:BuildRunAsUserName, $buildRunAsUserPassword)
			$basicCred = New-Object Microsoft.TeamFoundation.Client.BasicAuthCredential($netCred)
			$tfsCred = New-Object Microsoft.TeamFoundation.Client.TfsClientCredentials($basicCred)
			$tfsCred.AllowInteractive = $false

            $provider.TfsTeamProjectCollection = New-Object Microsoft.TeamFoundation.Client.TfsTeamProjectCollection(
                $tfsServer,
				$tfsCred)

			$provider.TfsTeamProjectCollection.EnsureAuthenticated()

            $versionControlServer = $provider.TfsTeamProjectCollection.GetService([Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer])
            $versionControlServer.add_NonFatalError($OnNonFatalError)
            $provider.VersionControlServer = $versionControlServer
			$provider.Workspace = Get-Workspace $versionControlServer

			if (-not $provider.Workspace)
			{
				Write-Warning "Failed to determine workspace ..."
				return
			}
            $provider.Workspace.Refresh()

            $success = $true
            return New-Object psobject -Property $provider
        }

        Write-Warning ("Only TfsVersionControl source providers are supported for TFVC tasks. Repository type: $provider")
		
		return
    } finally {
        if (-not $success) {
            Invoke-ProviderCleanup -Provider $provider
        }
        Write-Debug "Leaving Get-SourceProvider"
    }

}

function Get-Workspace
{
	param ($versionControlServer)
	
	$workspace = $versionControlServer.TryGetWorkspace($env:BUILD_SOURCESDIRECTORY)

    if (-not $workspace) {
		Write-Host "Could not find workspace from BUILD_SOURCESDIRECTORY: $($env:BUILD_SOURCESDIRECTORY)"
        Write-Host "Trying to find workspace from local cache..."
        $workspaceInfos = [Microsoft.TeamFoundation.VersionControl.Client.Workstation]::Current.GetLocalWorkspaceInfoRecursively($env:BUILD_SOURCESDIRECTORY);
        if ($workspaceInfos) {
			foreach ($workspaceInfo in $workspaceInfos) {
				try {
					$workspace = $versionControlServer.GetWorkspace($workspaceInfo)
                    break
			    } 
			    catch {
					Write-Host "GetWorkspace exception: $_"
                }
			}
		}
	}

    if ((-not $workspace) -and $env:BUILD_REPOSITORY_TFVC_WORKSPACE) {
		Write-Host "Workspace not found in local cache..."
		Write-Host "Trying to find workspace by BUILD_REPOSITORY_TFVC_WORKSPACE: $env:BUILD_REPOSITORY_TFVC_WORKSPACE"
        try {
			$workspace = $versionControlServer.GetWorkspace($env:BUILD_REPOSITORY_TFVC_WORKSPACE, '.')
        } catch [Microsoft.TeamFoundation.VersionControl.Client.WorkspaceNotFoundException] {
			Write-Verbose "GetWorkspace:WorkspaceNotFoundException"
		} catch {
			Write-Verbose "GetWorkspace exception: $_"
        }
	}
	return $workspace
}

function Invoke-ProviderCleanup {
    param($Provider)
    Write-Host "Cleaning up provider object"

	if (-not $Provider)
	{
		return
	}
    
    if ($Provider.VersionControlServer)
    {
		$Provider.VersionControlServer.remove_NonFatalError($OnNonFatalError)
    }

    if ($Provider.TfsTeamProjectCollection) {
		Write-Verbose 'Disposing tfsTeamProjectCollection'
        $Provider.TfsTeamProjectCollection.Dispose()
        $Provider.TfsTeamProjectCollection = $null
    }
}

function Invoke-CheckIn
{
	param($provider, $dropFile)
	
	$Recursion = "Full"
	$RecursionType = [Microsoft.TeamFoundation.VersionControl.Client.RecursionType]$Recursion
	$pendingChanges = $provider.Workspace.GetPendingChanges($dropFile, $RecursionType)

	$checkInParameters = new-object Microsoft.TeamFoundation.VersionControl.Client.WorkspaceCheckInParameters(@($pendingChanges), "*** NO CI ***")
	$checkinParameters.Author = $env:BUILD_QUEUEDBY
	$checkInParameters.PolicyOverride = New-Object Microsoft.TeamFoundation.VersionControl.Client.PolicyOverrideInfo("Check-in from the build.", $null)
	$checkInParameters.QueueBuildForGatedCheckIn = $false
	$checkInParameters.OverrideGatedCheckIn = $true
	$checkInParameters.AllowUnchangedContent = $false
	$checkInParameters.NoAutoResolve = $false
	
	$changeset = $provider.Workspace.CheckIn($checkInParameters)

	if ($changeset)
	{
		Write-Host "Successfully checked in $($dropFile). Changeset number is: $($changeset)"
	}
	else
	{
		Write-Warning "Could not check in drop file"
	}
}

Write-Host "Retrieving build artifact info. Url : $($env:BUILD_REPOSITORY_URI)/TestBuild/_apis/build/builds/$($env:Build_BuildId)/artifacts/"

$headers = @{  Authorization = "Bearer $env:SYSTEM_ACCESSTOKEN"  }
$url = "$($env:BUILD_REPOSITORY_URI)/TestBuild/_apis/build/builds/$($env:Build_BuildId)/artifacts"
$response = Invoke-RestMethod $url -Method Get -Headers $headers

Write-Host "Build artifact info : $($response | ConvertTo-Json -Depth 1000)"

$downloadUrl = $response.value[0].resource.downloadUrl
Write-Host "Download url : $($downloadUrl)"

$dropZipFile = "$($env:BUILD_SOURCESDIRECTORY)\Drops\$($env:BUILD_BUILDNUMBER).zip"
$start_time = Get-Date

Write-Host "Downloading drop zip file to working directory..."

Invoke-WebRequest -Uri $downloadUrl -OutFile $dropZipFile -Headers $headers
Write-Output "Time taken to download: $((Get-Date).Subtract($start_time).Seconds) second(s)"

Write-Host "Adding $($env:BUILD_BUILDNUMBER).zip to pending changes"
tf vc add $dropZipFile

$provider = Get-SourceProvider

Write-Host "Checking in $($env:BUILD_BUILDNUMBER).zip ..."
Invoke-CheckIn -provider $provider -dropFile $dropZipFile


Write-Host "=========== VSTSCheckIn.ps1 completed ==========="
