param(
	[string] $projectName,
	[string] $sourceRoot = 'D:\SourceCode\')

# Arrange
$solution = $DTE.Solution
$solutionDirectory = Split-Path $solution.FileName
$projectDirectory = Join-Path $solutionDirectory $projectName
$organizationPrefix = $projectName.Split('.')[0]

$templatesPath = Join-Path $sourceRoot "$organizationPrefix\$organizationPrefix.Build\Conventions\VisualStudio2017ProjectTemplates"
$templatePathClassLibrary = Join-Path $templatesPath "ClassLibrary\csClassLibrary.vstemplate"
$templatePathTestLibrary = Join-Path $templatesPath "ClassLibraryTest\csClassLibrary.vstemplate"

$packageIdBaseAssemblySharing = "OBeautifulCode.Type"
$packageIdAnalyzer = "$organizationPrefix.Build.Analyzers"
$packageIdBootstrapperDomain = "$organizationPrefix.Bootstrapper.Domain"
$packageIdBootstrapperFeature = "$organizationPrefix.Bootstrapper.Feature"
$packageIdBootstrapperTest = "$organizationPrefix.Bootstrapper.Test"
$packageIdBootstrapperSqlServer = "$organizationPrefix.Bootstrapper.SqlServer"

# Act
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$templateFilePath = ''
$packages = New-Object 'System.Collections.Generic.List[String]'

if ($projectName.Contains('.Bootstrapper.'))
{
	$templateFilePath = $templatePathClassLibrary
	$packages.Add($packageIdAnalyzer)
	$packages.Add($packageIdBaseAssemblySharing)
}
elseif ($projectName.EndsWith('.Domain'))
{
	$templateFilePath = $templatePathClassLibrary
	$packages.Add($packageIdBootstrapperDomain)

}
elseif ($projectName.Contains('.Feature.'))
{
	$templateFilePath = $templatePathClassLibrary
	$packages.Add($packageIdBootstrapperFeature)
}
elseif ($projectName.EndsWith('.Test') -or $projectName.EndsWith('.Tests'))
{
	$templateFilePath = $templatePathTestLibrary
	$packages.Add($packageIdBootstrapperTest)
}
else
{
	Throw "No known setup for: $projectName."
}

Write-Host "Using template file $templateFilePath."
Write-Host "Creating $projectDirectory for $organizationPrefix."
$project = $solution.AddFromTemplate($templatePathClassLibrary, $projectDirectory, $projectName, $false)

$packages | %{
	Write-Host "Installing bootstrapper package: $_."
	Install-Package -Id $_ -ProjectName $projectName
}

$stopwatch.Stop()
Write-Host "-----======>>>>>FINISHED - Total time: $($stopwatch.Elapsed) to add $projectName."