$visualStudioConstants = @{
	Bootstrappers = @{
		Bootstrapper = 'Bootstrapper';
		Domain = 'Domain';
		Feature = 'Feature';
		Recipe = 'Recipe';
		Test = 'Test';
	}
}

function VisualStudio-PreCommit()
{
    $packagesConfigFileName = 'packages.config'
    $solution = $DTE.Solution
    $solutionFilePath = $solution.FileName
    $solutionDirectory = Split-Path $solutionFilePath
    $solutionName = Split-Path $solution.FileName -Leaf
    $organizationPrefix = $solutionName.Split('.')[0]
    Write-Output "Adding any root files in ($solutionDirectory) as 'Solution Items'."
    Write-Output ''
    $repoRootFiles = ls $solutionDirectory | ?{ $(-not $_.PSIsContainer) -and $(-not $_.FullName.Contains('sln'))  } | %{$_.FullName}
    $repoRootFiles | %{
        $filePath = $_
        $solutionItemsFolderName = 'Solution Items'
        $solutionItemsProject = $solution.Projects | ?{$_.ProjectName -eq $solutionItemsFolderName}
        if ($solutionItemsProject -eq $null)
        {
            $solutionItemsProject = $solution.AddSolutionFolder($solutionItemsFolderName)
        }

        $solutionItemsProject.ProjectItems.AddFromFile($filePath) | Out-Null
    }
    Write-Output ''
    Write-Output ''

    Write-Output "Running RepoConfig on ($solutionDirectory)."
    Write-Output ''
    VisualStudio-RepoConfig
    Write-Output ''
    Write-Output ''

    Write-Output "Updating critical packages for all projects in solution '$solutionName' ($solutionFilePath)."
    Write-Output ''
    $solution.Projects | ?{-not [String]::IsNullOrWhitespace($_.FullName)} | %{
        $projectName = $_.ProjectName
        $projectFilePath = $_.FullName
        $projectDirectory = Split-Path $projectFilePath
        Write-Output "    - '$projectName' ($projectDirectory)"
        $packagesConfigFile = Join-Path $projectDirectory $packagesConfigFileName
        [xml] $packagesConfigXml = Get-Content $packagesConfigFile
        $packagesConfigXml.packages.package | %{
            $packageId = $_.Id
            $packageShouldBeAutoUpdated = $false
            if ($packageId.StartsWith($organizationPrefix))
            {
                if ($packageId -eq "$organizationPrefix.Build.Analyzers")
                {
                    $packageShouldBeAutoUpdated = $true
                }
                if ($packageId -eq "$organizationPrefix.Build.Conventions.ReSharper")
                {
                    $packageShouldBeAutoUpdated = $true
                }
                if ($packageId.StartsWith("$organizationPrefix.Bootstrapper"))
                {
                    $packageShouldBeAutoUpdated = $true
                }
            }
            
            if ($packageShouldBeAutoUpdated)
            {
                Write-Output "        - Package '$packageId' should be checked for updates."
                Install-Package -Id $packageId -ProjectName $projectName
                Write-Output ''
            }
        }
        
        Write-Output ''
    }
    
    Write-Output ''
    VisualStudio-CheckNuGetPackageDependencies

    Write-Output "Updating recipe NuSpec dependency versions to match packages for all projects in solution '$solutionName' ($solutionFilePath)."
    $solution.Projects | ?{-not [String]::IsNullOrWhitespace($_.FullName)} | %{
        $projectName = $_.ProjectName
        $projectFilePath = $_.FullName
        $projectDirectory = Split-Path $projectFilePath
        Write-Output "    - '$projectName' ($projectDirectory)"
        $packagesConfigPath = Join-Path $projectDirectory 'packages.config'
        [xml] $packagesConfigContents = Get-Content $packagesConfigPath
        $recipeNuSpecs = ls $projectDirectory -Filter "*.$($nuGetConstants.FileExtensionsWithoutDot.RecipeNuspec)" -Recurse
        $recipeNuSpecs | %{
            $recipeNuSpecPath = $_.FullName
            [xml] $recipeNuSpecContents = Get-Content $recipeNuSpecPath
            $recipeNuSpecContents.package.metadata.dependencies.dependency | %{
                $id = $_.id
                $version = $_.version
                $matchingPackagesConfigNode = $packagesConfigContents.packages.package | ?{$_.id -eq $id}
                if ($matchingPackagesConfigNode -ne $null)
                {
                    $newVersion = $matchingPackagesConfigNode.version
                    #figure out how to update with the ( [ , etc...
                    $splitChars = ,'[',']','(',')',','
                    $splitOutVersion = $version.Split($splitChars, [System.StringSplitOptions]::RemoveEmptyEntries)
                    $currentVersion = $null
                    if ($splitOutVersion.Length -eq 1)
                    {
                        $currentVersion = $splitOutVersion[0]
                    }
                    elseif ($splitOutVersion.Length -eq 2)
                    {
                        $currentVersion = $splitOutVersion[1]
                    }
                    else
                    {
                        throw "Version of package id '$id' ($version) in $packagesConfigPath was not a recognized structure."
                    }
                    
                    $_.SetAttribute('version', $version.Replace($currentVersion, $newVersion))
                }
                
            }
            
            Write-Output "      - Updating one or more versions in ($recipeNuSpecPath)."
            $recipeNuSpecContents.Save($(Resolve-Path $recipeNuSpecPath))
        }
    }

    Write-Output ''
    Write-Output 'Building Release with Code Analysis'
    Write-Output ''
	$msBuildReleasePropertiesDictionary = New-Object "System.Collections.Generic.Dictionary``2[[System.String], [System.String]]"
	$msBuildReleasePropertiesDictionary.Add('Configuration', 'release')
	$msBuildReleasePropertiesDictionary.Add('DebugType', 'pdbonly')
	$msBuildReleasePropertiesDictionary.Add('TreatWarningsAsErrors', $true)
	$msBuildReleasePropertiesDictionary.Add('RunCodeAnalysis', $true)
	$msBuildReleasePropertiesDictionary.Add('CodeAnalysisTreatWarningsAsErrors', $true)
	MsBuild-Custom -customBuildFilePath $solutionFilePath -target 'Build' -customPropertiesDictionary $msBuildReleasePropertiesDictionary

    Write-Output ''
    Write-Output 'Finished PreCommit checks, all is good.'
}

function VisualStudio-CheckNuGetPackageDependencies([string] $projectName = $null, [boolean] $uninstall = $false)
{
    if (($projectName -ne $null) -and ($projectName.StartsWith('.\')))
    {
        # compensate for if auto complete was used which will do the directory in context of the solution folder (strictly a convenience).
        $projectName = $projectName.SubString(2, $projectName.Length - 2)
    }
    
    Write-Output ''
    # Arrange
    $solution = $DTE.Solution
    $solutionFilePath = $solution.FileName
    $solutionName = Split-Path $solution.FileName -Leaf
    $organizationPrefix = $solutionName.Split('.')[0]
    $solutionDirectory = Split-Path $solutionFilePath

	$projectDirectories = New-Object 'System.Collections.Generic.List[String]'
    if ([String]::IsNullOrWhitespace($projectName))
    {
        Write-Output "Identified following projects to check from solution '$(Split-Path $solutionFilePath -Leaf)' ($solutionFilePath)."
        Write-Output ''
        $solution.Projects | ?{-not [String]::IsNullOrWhitespace($_.FullName)} | %{
            $projectName = $_.ProjectName
            $projectFilePath = $_.FullName
            $projectDirectory = Split-Path $projectFilePath
            $projectDirectories.Add($projectDirectory)
            Write-Output "    - '$projectName' ($projectDirectory)"
        }
    }
    else
    {
        $projectDirectory = Join-Path $solutionDirectory $projectName
        $projectDirectories.Add($projectDirectory)
        Write-Output "Checking the following specified project from solution '$(Split-Path $solutionFilePath -Leaf)' ($solutionFilePath)."
        Write-Output ''
        Write-Output "    - '$projectName' ($projectDirectory)"
    }

    Write-Output ''
    
    $regexPrefixToken = 'regex:'

    $projectDirectories | %{
        $projectDirectory = $_
        File-ThrowIfPathMissing -path $projectDirectory
        
        $projectName = Split-Path $projectDirectory -Leaf
        Write-Output "Checking '$projectName'"
        Write-Output ''

        $packagesConfigFileName = 'packages.config'
        $packagesConfigFile = Join-Path $projectDirectory $packagesConfigFileName
        [xml] $packagesConfigXml = Get-Content $packagesConfigFile
        $expectedPackageIdsFromProjectReferences = New-Object 'System.Collections.Generic.List[String]'
        $packageIdsInProject = New-Object 'System.Collections.Generic.List[String]'
        $packagesConfigXml.packages.package | %{
            $packageIdsInProject.Add($_.Id)
        }
        
        $projectFilePath = (ls $projectDirectory -filter '*.csproj').FullName
        $allReferencedProjects = MsBuild-GetProjectReferences -projectFilePath $projectFilePath -recursive $true
        $allReferencedProjects | %{
            $projectPackageFilePath = Join-Path (Split-Path $_) $packagesConfigFileName
            [xml] $projectPackageFileXml = Get-Content $projectPackageFilePath
            $projectPackageFileXml.packages.package | %{
                if (-not $_.Id.Contains('.Recipe'))
                {
                    $expectedPackageIdsFromProjectReferences.Add($_.Id)
                }
            }
        }
        
        Write-Output "    - Confirm all non-recipe NuGet packages in project references are referenced directly."
        $allReferencedProjects | %{
            $referencedProjectFileName = (Split-Path $_ -Leaf).Replace('.csproj', '')
            Write-Output "        - '$referencedProjectFileName' ($_)"
        }
        
        $expectedPackageIdsFromProjectReferences | %{
            if (-not $packageIdsInProject.Contains($_))
            {
                throw "    Expected a NuGet reference to $_"
            }
        }
        
        $bootstrapperPrefix = "$organizationPrefix.Bootstrapper"
        $bootstrapperPackages = $packagesConfigXml.packages.package | ?{$_.Id.StartsWith($bootstrapperPrefix)}
        
        Write-Output "    - Confirm at least one bootstrapper package is installed, prefixed by '$bootstrapperPrefix'."
        if ((-not $projectName.StartsWith($bootstrapperPrefix)) -and ($bootstrapperPackages.Count -eq 0))
        {
            throw "      Did not find any 'bootstrapper' packages in ($packagesConfigFile)."
        }

        $nugetPackageBlacklistTextFileName = 'NuGetPackageBlacklist.txt'
        Write-Output "    - Confirm that all bootstrapper packages have a '$nugetPackageBlacklistTextFileName' file."
        $blacklistFiles = New-Object 'System.Collections.Generic.List[String]'
        $bootstrapperPackages | %{
            $blacklistFile = Join-Path $solutionDirectory $("packages\$($_.Id).$($_.Version)\$nugetPackageBlacklistTextFileName")
            Write-Output "        - Checking '$($_.Id)'"
            File-ThrowIfPathMissing -path $blacklistFile -because "bootstrapper packages should have a 'blacklist file' named '$nugetPackageBlacklistTextFileName'."
            
            $blacklistFiles.Add($blacklistFile)
        }
        
        Write-Output '    - Create consolidated NuGet package blacklist.'
        $bootstrapperToBlacklistMap = New-Object 'System.Collections.Generic.Dictionary[String,Object]'
        $blacklistFiles | %{
            $blacklistFile = $_
            $blacklistFileContents = Get-Content $blacklistFile
            $blacklistLines = $blacklistFileContents.Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)
            $blacklist = New-Object 'System.Collections.Generic.Dictionary[String,String]'
            $blacklistLines | %{
                $blacklistLine = $_
                if ($(-not $blacklistLine.StartsWith('#')) -and (-not [String]::IsNullOrWhitespace($blacklistLine)))
                {
                    $blacklistReplacement = $null
                    
                    if (-not $blacklistLine.StartsWith($regexPrefixToken))
                    {
                        $arrowSplit = $blacklistLine.Split('>')
                        $blacklistName = $arrowSplit[0]
                        if ($arrowSplit.Length -gt 1)
                        {
                            $blacklistReplacement = $arrowSplit[1]
                        }
                    }
                    else
                    {
                        $blacklistName = $blacklistLine
                    }
                    
                    if (-not $blacklist.ContainsKey($blacklistName))
                    {
                        $blacklist.Add($blacklistName, $blacklistReplacement)
                    }
                }
            }

            $bootstrapper = $(Split-Path $(Split-Path $blacklistFile) -Leaf)
            $bootstrapperToBlacklistMap.Add("$bootstrapper|$blacklistFile", $blacklist)
        }

        #TODO: find and merge all projectrefblacklists/projectrefwhitelists
        
        Write-Output "    - Confirm no blacklist matches in ($packagesConfigFile)."
        $uninstallPackages = New-Object 'System.Collections.Generic.List[String]'
        $replacementPackages = New-Object 'System.Collections.Generic.List[String]'
        $projectPackages = New-Object 'System.Collections.Generic.List[String]'
        $bootstrapperToBlacklistMap.Keys | %{
            $bootstrapperKey = $_
            $blacklist = $bootstrapperToBlacklistMap[$bootstrapperKey]
            $bootstrapperKeySplitOnPipe = $bootstrapperKey.Split('|')
            $bootstrapper = $bootstrapperKeySplitOnPipe[0]
            $blacklistFile = $bootstrapperKeySplitOnPipe[1]
            Write-Output "        - Checking installed packages against blacklist in '$bootstrapper' ($blacklistFile)."
            $packagesConfigXml.packages.package | %{
                $packageId = $_.Id
                $blacklist.Keys | %{
                    $blackListKey = $_
                    if ($($blackListKey.StartsWith($regexPrefixToken) -and $($packageId -match $blackListKey.Replace($regexPrefixToken, '')) -or $($packageId -eq $blackListKey)))
                    {
                        $blacklistEntry = $blacklist[$blackListKey]
                        if ($uninstall -eq $true)
                        {
                            $uninstallPackages.Add($packageId)
                            if ($blacklistEntry -ne $null)
                            {
                                $replacementPackages.Add($blacklistEntry)
                            }

                            #throw "Project - $projectName contains blacklisted package (ID: $($_.Id), Version: $($_.Version))"
                        }
                        else
                        {
                            throw "          Installed package '$packageId' matches blacklist entry '$blacklistKey'."
                        }
                    }
                }
            }
        }
        
        $projectName = Split-Path $projectDirectory -Leaf
        
        if ($uninstall -eq $true)
        {
            if ($uninstallPackages.Count -gt 0)
            {
                Write-Output "    - Uninstall detected blacklist packages."
                $uninstallPackages | %{
                    if (-not [String]::IsNullOrWhitespace($_))
                    {
                        Uninstall-Package -Id $_ -ProjectName $projectName
                    }
                }
            }
            
            if ($replacementPackages.Count -gt 0)
            {
                Write-Output "    - Install replacement packages for detected blacklisted packages."
                $replacementPackages | %{
                    if (-not [String]::IsNullOrWhitespace($_))
                    {
                        Install-Package -Id $_ -ProjectName $projectName
                    }
                }
            }
        }
        
        Write-Output ''
        Write-Output 'Completed NuGet Package Dependency checks - no issues found.'
        Write-Output ''
    }
}

function VisualStudio-RunCodeGenForModels([string] $projectName, [string] $testProjectName = $null)
{    
    if ([string]::IsNullOrWhitespace($projectName))
    {
        throw 'Specify Project Name to operate on.'
    }
    
    if ($projectName.StartsWith('.\'))
    {
        # compensate for if auto complete was used which will do the directory in context of the solution folder (strictly a convenience).
        $projectName = $projectName.SubString(2, $projectName.Length - 2)
    }
    
    if ($testProjectName.StartsWith('.\'))
    {
        # compensate for if auto complete was used which will do the directory in context of the solution folder (strictly a convenience).
        $testProjectName = $testProjectName.SubString(2, $testProjectName.Length - 2)
    }
    
    if ([string]::IsNullOrWhitespace($testProjectName))
    {
        $testProjectName = $projectName + ".Test"
    }

    $solution = $DTE.Solution
    $solutionDirectory = Split-Path $solution.FileName
    $projectDirectory = Join-Path $solutionDirectory $projectName
    $testProjectDirectory = Join-Path $solutionDirectory $testProjectName
    File-ThrowIfPathMissing -path $projectDirectory
    File-ThrowIfPathMissing -path $testProjectDirectory
    
    $projectFilePath = (ls $projectDirectory -Filter '*.csproj').FullName
    $testProjectFilePath = (ls $testProjectDirectory -Filter '*.csproj').FullName
    
    File-ThrowIfPathMissing -path $projectFilePath
    File-ThrowIfPathMissing -path $testProjectFilePath

    $codeGenTempDirectory = Join-Path $([System.IO.Path]::GetTempPath()) 'ObcCodeGenNuGetStaging'
    $codeGenConsolePackageName = 'OBeautifulCode.CodeGen.Console'
    &$NuGetExeFilePath install $codeGenConsolePackageName -OutputDirectory $codeGenTempDirectory
    $codeGenConsoleDirObjects = ls $codeGenTempDirectory -Filter "$codeGenConsolePackageName*"
    $codeGenConsoleDirPaths = New-Object 'System.Collections.Generic.List[String]'
    if ($codeGenConsoleDirObjects.PSIsContainer)
    {
        $codeGenConsoleDirObjects | %{ $_.FullName } | Sort-Object -Descending | %{ $codeGenConsoleDirPaths.Add($_) }
    }
    else
    {
        # only one directory present.
        $codeGenConsoleDirPaths = $codeGenConsoleDirPaths.Add($codeGenConsoleDirObjects)
    }
   
    if (($codeGenConsoleDirPaths -eq $null) -or ($codeGenConsoleDirPaths.Count -eq 0))
    {
        throw "Expected to find an installed package '$codeGenConsolePackageName' at ($codeGenTempDirectory); nothing was returned."
    }
    
    $codeGenConsoleLatestVersionRootDirectory = $codeGenConsoleDirPaths[0]
    if ([String]::IsNullOrWhitespace($codeGenConsoleLatestVersionRootDirectory))
    {
        throw "Expected to find an installed package '$codeGenConsolePackageName' at ($codeGenTempDirectory); first entry was empty."
    }
    
    $project = VisualStudio-GetProjectFromSolution -projectFilePath $projectFilePath
    $testProject = VisualStudio-GetProjectFromSolution -projectFilePath $testProjectFilePath
    
    $projectOutputRelativePath = $project.ConfigurationManager.ActiveConfiguration.Properties.Item('OutputPath').Value.ToString()
    $projectOutputDirectory = Join-Path $projectDirectory $projectOutputRelativePath
    
    $codeGenConsoleFilePath = Join-Path $codeGenConsoleLatestVersionRootDirectory 'packagedConsoleApp/OBeautifulCode.CodeGen.Console.exe'
    File-ThrowIfPathMissing -path $codeGenConsoleFilePath -because "Package should contain the OBC.CodeGen.Console.exe at ($codeGenConsoleFilePath)."

    &$codeGenConsoleFilePath model /projectDirectory=$projectDirectory /testProjectDirectory=$testProjectDirectory /projectOutputDirectory=$projectOutputDirectory

    $projectFilesFromCsproj = VisualStudio-GetFilePathsFromProject -projectFilePath $projectFilePath
    $testProjectFilesFromCsproj = VisualStudio-GetFilePathsFromProject -projectFilePath $testProjectFilePath
    
    $projectSouceFiles = ls $projectDirectory -filter '*.cs' -recurse | %{ $_.FullName } | ?{-not $_.Contains('\obj\')}
    $testProjectSourceFiles = ls $testProjectDirectory -filter '*.cs' -recurse | %{ $_.FullName } | ?{-not $_.Contains('\obj\')}
    
    $projectSouceFiles | ?{ -not $projectFilesFromCsproj.Contains($_) } | %{ $project.ProjectItems.AddFromFile($_) | Out-Null }
    $testProjectSourceFiles | ?{ -not $testProjectFilesFromCsproj.Contains($_) } | %{ $testProject.ProjectItems.AddFromFile($_) | Out-Null }
    
    Write-Output "Removing temporary directory ($codeGenTempDirectory)."
    Remove-Item $codeGenTempDirectory -Recurse -Force
}

function VisualStudio-RepoConfig([boolean] $PreRelease = $true)
{
    # Arrange
    $solution = $DTE.Solution
    $solutionDirectory = Split-Path $solution.FileName
    $solutionFileName = Split-Path $solution.FileName -Leaf
    $organizationPrefix = $solutionFileName.Split('.')[0]

    $repoConfigPackageId = "$organizationPrefix.Build.Conventions.RepoConfig"

    $tempDirectoryPrefix = "Naos.VsRepoConfig"
    $scriptStartTimeUtc = [System.DateTime]::UtcNow
    $scriptStartTime = $scriptStartTimeUtc.ToLocalTime()

    Write-Output "################################################################################################"
    Write-Output "------------------------------------------------------------------------------------------------"
    Write-Output "> Starting '$repoConfigPackageId' at $($scriptStartTime.ToString())"

    $alreadyUpToDate = $false
    $repoConfigPackageVersion = '1.0.0.0'
    $tempDirectory = File-CreateTempDirectory -prefix $tempDirectoryPrefix
    $instructionsFilePath = Join-Path $tempDirectory 'RepoConfigInstructions.ps1'
    $nugetLog = Join-Path $tempDirectory 'NuGet.log'

    $stateFilePath = Join-Path $solutionDirectory 'RepoConfig.state'
    if (-not (Test-Path $stateFilePath)) {
        Write-Output "------------------------------------------------------------------------------------------------"
        Write-Output " > No state file found"
        $defaultStateFileContent = ''
        $defaultStateFileContent += "<?xml version=`"1.0`"?>" + [Environment]::NewLine
        $defaultStateFileContent += "<repoConfigState>" + [Environment]::NewLine
        $defaultStateFileContent += "    <version></version>" + [Environment]::NewLine
        $defaultStateFileContent += "    <lastCheckedDateTimeUtc></lastCheckedDateTimeUtc>" + [Environment]::NewLine
        $defaultStateFileContent += "</repoConfigState>"
        $defaultStateFileContent | Out-File $stateFilePath
        Write-Output " - Created $stateFilePath"
        Write-Output " < No state file found"
    }
    else
    {
        Write-Output "------------------------------------------------------------------------------------------------"
        Write-Output " - Target Repository Path: $solutionDirectory"
        Write-Output " - State File Path: $stateFilePath"
    }

    $stateFilePath = Resolve-Path $stateFilePath
    [xml] $stateFileXml = Get-Content $stateFilePath

    [scriptblock] $updateState = {
        Write-Output "------------------------------------------------------------------------------------------------"
        Write-Output " > Updating State File"
        $stateFileXml.repoConfigState.lastCheckedDateTimeUtc = $scriptStartTimeUtc.ToString('yyyyMMdd-HHmmssZ')
        $stateFileXml.repoConfigState.version = $repoConfigPackageVersion
        $stateFileXml.Save($stateFilePath)
        Write-Output " - Changed $stateFilePath"
        Write-Output " < Updating State File"
    }

    [scriptblock] $cleanUp = {
        if (Test-Path $tempDirectory) {
            Write-Output "------------------------------------------------------------------------------------------------"
            Write-Output " > Removing working directory"
            rm $tempDirectory -Recurse -Force
            Write-Output " - Deleted $tempDirectory"
            Write-Output " < Removing working directory"
        }
    }

    # Download latest package                                                               #
    Write-Output "------------------------------------------------------------------------------------------------"
    Write-Output " > Installing NuGet package"
    if ($PreRelease) {
        &$NuGetExeFilePath install $repoConfigPackageId -OutputDirectory $tempDirectory -PreRelease | Out-File $nugetLog 2>&1
    }
    else{
        &$NuGetExeFilePath install $repoConfigPackageId -OutputDirectory $tempDirectory | Out-File $nugetLog 2>&1
    }
    Write-Output " - Package: $repoConfigPackageId"
    Write-Output " - Location: $tempDirectory"
    Write-Output " - Log: $nugetLog"
    Write-Output " < Installing NuGet package"

    #############################################################################################
    #     Check against state version and throw if $ThrowOnPendingUpdate is set and dont match  #
    #############################################################################################
    $packageFolder = ls $tempDirectory -Filter "$repoConfigPackageId*"
    if ($packageFolder -eq $null) {
        throw "Could not retrieve package $repoConfigPackageId or could not find $(Split-Path $instructionsFilePath -Leaf) in package"
    }
    else {
        $repoConfigPackageVersion = (Split-Path $packageFolder.FullName -Leaf).Replace("$repoConfigPackageId.", '')
        
        $instructionsFilePath = ls $packageFolder.FullName -Filter $(Split-Path $instructionsFilePath -Leaf) -Recurse
        if ($instructionsFilePath -eq $null) {
            throw "Could not find $(Split-Path $instructionsFilePath -Leaf) in $packageFolder"
        }
        
        $instructionsFilePath = $instructionsFilePath.FullName
    }

    $alreadyUpToDate = $stateFileXml.repoConfigState.version -eq $repoConfigPackageVersion

    # Run instructions and clean up                                                         #
    if ($alreadyUpToDate)
    {
        Write-Output "------------------------------------------------------------------------------------------------"
        Write-Output " - Installed version of $repoConfigPackageId ($repoConfigPackageVersion) is the latest version."
    }
    else
    {
        Write-Output "------------------------------------------------------------------------------------------------"
        Write-Output " > Running specific update instructions from version $repoConfigPackageVersion"
        Write-Output ''
        &$instructionsFilePath -RepositoryPath $solutionDirectory
        Write-Output ''
        Write-Output " - Executed $instructionsFilePath"
        Write-Output " < Running specific update instructions"

        &$updateState
    }

    &$cleanUp

    Write-Output "------------------------------------------------------------------------------------------------"
    Write-Output "< Finishing Script '$repoConfigPackageId' at $([System.DateTime]::Now.ToString())"
    Write-Output "################################################################################################"
}

function VisualStudio-PrintPackageReferencesAsDependencies([string] $projectName)
{
    if ([string]::IsNullOrWhitespace($projectName))
    {
        throw "Invalid projectName: '$projectName'."
    }
    
    $solution = $DTE.Solution
    $solutionDirectory = Split-Path $solution.FileName
    $projectDirectory = Join-Path $solutionDirectory $projectName
    $packagesConfigFile = Join-Path $projectDirectory 'packages.config'
    File-ThrowIfPathMissing -path $projectDirectory
    
    [xml] $packagesConfigXml = Get-Content $packagesConfigFile
    $packagesConfigXml.packages.package | % {
        Write-Host "<dependency id=`"$($_.Id)`" version=`"$($_.Version)`" />"
    }
}

function VisualStudio-GetFilePathsFromProject([string] $projectFilePath)
{
     [System.IO.File]::ReadAllLines($projectFilePath) | ?{$_.Contains('<Compile')} | %{$_ -match 'Include="((.*))"'|out-null;$matches[0]} | %{$_.Replace('Include="', '').Replace('"', '')} |
     %{Join-Path (Split-Path $projectFilePath) $_}
}

function VisualStudio-GetProjectFromSolution([string] $projectFilePath = $null, [string] $projectName = $null, [boolean] $throwIfNotFound = $true)
{
    $solution = $DTE.Solution
    $result = $null

    if ((-not [String]::IsNullOrWhitespace($projectFilePath)) -and (-not [String]::IsNullOrWhitespace($projectName)))
    {
        throw "Please only specify 'projectFilePath' ($projectFilePath) or 'projectName' ($projectName) but NOT both"
    }
    elseif ([String]::IsNullOrWhitespace($projectFilePath) -and [String]::IsNullOrWhitespace($projectName))
    {
        throw "Please only specify 'projectFilePath' ($projectFilePath) or 'projectName' ($projectName) but NOT both"
    }
    elseif ((-not [String]::IsNullOrWhitespace($projectFilePath)) -and [String]::IsNullOrWhitespace($projectName))
    {
        $projectByFilePath = $null
        $solution.Projects | %{
            if ($_.FullName -eq $projectFilePath)
            {
                $projectByFilePath = $_
            }
        }
        
        $result = $projectByFilePath
    }
    elseif ([String]::IsNullOrWhitespace($projectFilePath) -and (-not [String]::IsNullOrWhitespace($projectName)))
    {
        $projectByName = $null
        $solution.Projects | %{
            if ($_.ProjectName -eq $projectName)
            {
                $projectByName = $_
            }
        }
        
        $result = $projectByName
    }
    else
    {
        throw "Unexpected invalid input: 'projectFilePath' ($projectFilePath) or 'projectName' ($projectName)"
    }

    if (($throwIfNotFound -eq $true) -and ($result -eq $null))
    {
        throw "Could not find project by name ($projectName) or path ($projectFilePath) in solution ($($solution.FullName))."
    }
    else
    {
        return $result
    }
}

function VisualStudio-AddNewProjectAndConfigure([string] $projectName, [string] $projectKind, [boolean] $addTestProject = $true)
{
    if ([string]::IsNullOrWhitespace($projectName))
    {
        throw "Invalid projectName: '$projectName'."
    }
    
    $dotSplitProjectName = $projectName.Split('.')
    $organizationPrefix = $dotSplitProjectName[0]
    $subsystemName = $dotSplitProjectName[1]
    
    $solution = $DTE.Solution
    $solutionDirectory = Split-Path $solution.FileName
    $solutionName = (Split-Path $solution.FileName -Leaf).Replace('.sln', '')

    $projectDirectory = Join-Path $solutionDirectory $projectName
    

    $packageIdBootstrapper = "$organizationPrefix.Bootstrapper.Recipes.$projectKind"
    $packageIdTemplate = "$organizationPrefix.Build.Conventions.VisualStudioProjectTemplates.$projectKind"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # used to be 'Naos.VsAddProject', but caused a PathTooLongException with long $organizationPrefix and/or $projectKind
    $tempDirectoryPrefix = "Naos.Vs"
    
    # Files get locked so try and delete residue of previous runs.
    File-TryDeleteTempDirectories -prefix $tempDirectoryPrefix    
    $tempDirectory = File-CreateTempDirectory -prefix $tempDirectoryPrefix

    &$NuGetExeFilePath install $packageIdTemplate -OutputDirectory $tempDirectory -PreRelease

    $packageDirectory = (ls $tempDirectory).FullName # we can only do this b/c there are no dependencies and it will revert to the directory information
    $templateFilePath = Join-Path $packageDirectory "$projectKind\template.vstemplate"
    File-ThrowIfPathMissing -path $templateFilePath -because "'$packageIdTemplate' should contain the template."
    
    $packageDirectoryName = Split-Path $packageDirectory -Leaf
    $packageTemplateVersion = $packageDirectoryName.Replace("$packageIdTemplate.", '')
    
    $projectNameWithoutTestSuffix = $projectName
    if ($projectNameWithoutTestSuffix.EndsWith('.Test'))
    {
        $projectNameWithoutTestSuffix = $projectNameWithoutTestSuffix.SubString(0, $projectNameWithoutTestSuffix.Length - 5)
    }
    
    $projectNameWithoutSerializationSuffix = $projectName
    if ($projectNameWithoutSerializationSuffix.EndsWith('.Serialization.Bson') -or $projectNameWithoutSerializationSuffix.EndsWith('.Serialization.Json'))
    {
        $projectNameWithoutSerializationSuffix = $projectNameWithoutSerializationSuffix.SubString(0, $projectNameWithoutSerializationSuffix.Length - 19)
    }
    
    # Documented on StackOverflow:
    #    https://stackoverflow.com/questions/60250406/what-replacement-tokens-are-support-for-visual-studio-templates-in-naos-powershe
    $tokenReplacementList = New-Object 'System.Collections.Generic.Dictionary[String,String]'
    $tokenReplacementList.Add('[ORGANIZATION]', $organizationPrefix)
    $tokenReplacementList.Add('[SUBSYSTEM_NAME]', $subsystemName)
    $tokenReplacementList.Add('[PROJECT_NAME]', $projectName)
    $tokenReplacementList.Add('[PROJECT_NAME_WITHOUT_SERIALIZATION_SUFFIX]', $projectNameWithoutSerializationSuffix)
    $tokenReplacementList.Add('[PROJECT_NAME_WITHOUT_TEST_SUFFIX]', $projectNameWithoutTestSuffix)
    $tokenReplacementList.Add('[SOLUTION_NAME]', $solutionName)
    $tokenReplacementList.Add('[RECIPE_CONDITIONAL_COMPILATION_SYMBOL]', "$($solutionName.Replace('.', ''))RecipesProject")
    $tokenReplacementList.Add('[VISUAL_STUDIO_TEMPLATE_PACKAGE_ID]', $packageIdTemplate)
    $tokenReplacementList.Add('[VISUAL_STUDIO_TEMPLATE_PACKAGE_VERSION]', $packageTemplateVersion)

    $templateFiles = ls $packageDirectory -Recurse | ?{-not $_.PSIsContainer} | %{$_.FullName}

    $templateFiles | %{
        $file = $_
        $contents = [System.IO.File]::ReadAllText($file)
        $tokenReplacementList.Keys | %{
            $key = $_
            $replacementValue = $tokenReplacementList[$key]
            
            if ($file.Contains($key))
            {
                $file = $file.Replace($key, $replacementValue)
            }
            
            if ($contents.Contains($key))
            {
                $contents = $contents.Replace($key, $replacementValue)
            }
        }
        
        $contents | Out-File -LiteralPath $file -Encoding UTF8
    }
    
    Write-Host "Using template file $templateFilePath augmented at $packageDirectory."
    Write-Host "Creating $projectDirectory for $organizationPrefix."

    $isDomainProject = $false
    $project = $solution.AddFromTemplate($templateFilePath, $projectDirectory, $projectName, $false)
    if ($projectKind -eq 'Domain')
    {
        $isDomainProject = $true
    }
    else
    {
        # if there is a domain project then add a reference
        $domainProjectName = "$organizationPrefix.$subsystemName.Domain"
        $domainProject = VisualStudio-GetProjectFromSolution -projectName $domainProjectName -throwIfNotFound $false
        if ($domainProject -ne $null)
        {
			# need to refetch project because $project is null when we get here
			$project = VisualStudio-GetProjectFromSolution -projectName $projectName
            $project.Object.References.AddProject($domainProject) | Out-Null
        }
    }

    if (-not $projectName.Contains('Bootstrapper'))
    {
        Write-Host "Installing bootstrapper package: $packageIdBootstrapper."
        Install-Package -Id $packageIdBootstrapper -ProjectName $projectName
    }

    $stopwatch.Stop()
    Write-Host "-----======>>>>>FINISHED - Total time: $($stopwatch.Elapsed) to add $projectName."   
    
    if ($addTestProject -and (-not $projectName.EndsWith('.Test')) -and (-not $projectName.EndsWith('.Tests')))
    {
        # auto-create a Test project and add reference to the non-test project
        $testProjectName = "$projectName.Test"
        VisualStudio-AddNewProjectAndConfigure -projectName $testProjectName -projectKind "$projectKind.Test" -addTestProject $false
        $testProject = VisualStudio-GetProjectFromSolution -projectName $testProjectName
        
        if ($isDomainProject)
        {
            $bsonSuffix = '.Serialization.Bson'
            $jsonSuffix = '.Serialization.Json'
            $domainSuffix = '.Domain'
            
            # Domain projects also need a reference to the serialization configuration projects
            $bsonProjectName = $projectName
            if ($bsonProjectName.EndsWith($domainSuffix))
            {
                $bsonProjectName = $bsonProjectName.Replace($domainSuffix, $bsonSuffix)
            }
            else
            {
                $bsonProjectName = $bsonProjectName + $bsonSuffix
            }

            $jsonProjectName = $projectName
            if ($jsonProjectName.EndsWith($domainSuffix))
            {
                $jsonProjectName = $jsonProjectName.Replace($domainSuffix, $jsonSuffix)
            }
            else
            {
                $jsonProjectName = $jsonProjectName + $jsonSuffix
            }
            VisualStudio-AddNewProjectAndConfigure -projectName $bsonProjectName -projectKind 'Serialization.Bson' -addTestProject $false
            VisualStudio-AddNewProjectAndConfigure -projectName $jsonProjectName -projectKind 'Serialization.Json' -addTestProject $false

            $bsonProject = VisualStudio-GetProjectFromSolution -projectName $bsonProjectName
            $testProject.Object.References.AddProject($bsonProject) | Out-Null

            $jsonProject = VisualStudio-GetProjectFromSolution -projectName $jsonProjectName
            $testProject.Object.References.AddProject($jsonProject) | Out-Null
        }
        else
        {
            # Domain project will already be referenced but non-domain test projects will need a reference to their non-test version
			
			# need to refetch project because $project is null when we get here
			$project = VisualStudio-GetProjectFromSolution -projectName $projectName
			
			Write-Output "Adding reference to project ($($project.ProjectName)) in test project ($($testProject.ProjectName))."
			$testProject.Object.References.AddProject($project) | Out-Null
        }
    }
}