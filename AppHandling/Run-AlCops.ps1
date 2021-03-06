﻿<# 
 .Synopsis
  Run AL Cops
 .Description
  Run AL Cops
 .Parameter containerName
  Name of the validation container. Default is bcserver.
 .Parameter credential
  These are the credentials used for the container. If not provided, the Run-AlValidation function will generate a random password and use that.
 .Parameter previousApps
  Array or comma separated list of previous version of apps to use for AppSourceCop validation and upgrade test
 .Parameter apps
  Array or comma separated list of apps to validate
 .Parameter affixes
  Array or comma separated list of affixes to use for AppSourceCop validation
 .Parameter supportedCountries
  Array or comma separated list of supportedCountries to use for AppSourceCop validation
 .Parameter useLatestAlLanguageExtension
  Include this switch if you want to use the latest AL Extension from marketplace instead of the one included in 
 .Parameter appPackagesFolder
  Folder in which symbols and apps will be cached. The folder must be shared with the container.
 .Parameter enableAppSourceCop
  Include this switch to enable AppSource Cop
 .Parameter enableCodeCop
  Include this switch to enable Code Cop
 .Parameter enableUICop
  Include this switch to enable UI Cop
 .Parameter enablePerTenantExtensionCop
  Include this switch to enable Per Tenant Extension Cop
 .Parameter failOnError
  Include this switch if you want to fail on the first error instead of returning all errors to the caller
 .Parameter ignoreWarnings
  Include this switch if you want to ignore Warnings
 .Parameter rulesetFile
  Filename of the ruleset file for Compile-AppInBcContainer
 .Parameter CompileAppInBcContainer
  Override function parameter for Compile-AppInBcContainer
#>
function Run-AlCops {
    Param(
        $containerName = "bcserver",
        [PSCredential] $credential,
        $previousApps,
        $apps,
        $affixes,
        $supportedCountries,
        $appPackagesFolder = (Join-Path $bcContainerHelperConfig.hostHelperFolder ([Guid]::NewGuid().ToString())),
        [switch] $enableAppSourceCop,
        [switch] $enableCodeCop,
        [switch] $enableUICop,
        [switch] $enablePerTenantExtensionCop,
        [switch] $failOnError,
        [switch] $ignoreWarnings,
        [string] $rulesetFile = "",
        [scriptblock] $CompileAppInBcContainer
    )

    if ($previousApps                   -is [String]) { $previousApps = @($previousApps.Split(',').Trim() | Where-Object { $_ }) }
    if ($apps                           -is [String]) { $apps = @($apps.Split(',').Trim()  | Where-Object { $_ }) }
    if ($affixes                        -is [String]) { $affixes = @($affixes.Split(',').Trim() | Where-Object { $_ }) }
    if ($supportedCountries             -is [String]) { $supportedCountries = @($supportedCountries.Split(',').Trim() | Where-Object { $_ }) }
    $supportedCountries = $supportedCountries | Where-Object { $_ } | ForEach-Object { getCountryCode -countryCode $_ }

    if ($CompileAppInBcContainer) {
        Write-Host -ForegroundColor Yellow "CompileAppInBcContainer override"; Write-Host $CompileAppInBcContainer.ToString()
    }
    else {
        $CompileAppInBcContainer = { Param([Hashtable]$parameters) Compile-AppInBcContainer @parameters }
    }

    if ($enableAppSourceCop -and $enablePerTenantExtensionCop) {
        throw "You cannot run AppSourceCop and PerTenantExtensionCop at the same time"
    }
     
    $appsFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder ([Guid]::NewGuid().ToString())
    New-Item -Path $appsFolder -ItemType Directory | Out-Null
    $apps = Sort-AppFilesByDependencies -appFiles @(CopyAppFilesToFolder -appFiles $apps -folder $appsFolder) -WarningAction SilentlyContinue
    
    $appPackFolderCreated = $false
    if (!(Test-Path $appPackagesFolder)) {
        New-Item -Path $appPackagesFolder -ItemType Directory | Out-Null
        $appPackFolderCreated = $true
    }
    
    if ($enableAppSourceCop -and $previousApps) {
        $previousAppVersions = @{}
        Write-Host "Copying previous apps to packages folder"
        $appList = CopyAppFilesToFolder -appFiles $previousApps -folder $appPackagesFolder
        $previousApps = Sort-AppFilesByDependencies -appFiles $appList
        $previousApps | ForEach-Object {
            $appFile = $_
            $tmpFolder = Join-Path $ENV:TEMP ([Guid]::NewGuid().ToString())
            try {
                Extract-AppFileToFolder -appFilename $appFile -appFolder $tmpFolder -generateAppJson
                $xappJsonFile = Join-Path $tmpFolder "app.json"
                $xappJson = Get-Content $xappJsonFile | ConvertFrom-Json
                Write-Host "$($xappJson.Publisher)_$($xappJson.Name) = $($xappJson.Version)"
                $previousAppVersions += @{ "$($xappJson.Publisher)_$($xappJson.Name)" = $xappJson.Version }
            }
            catch {
                throw "Cannot use previous app $([System.IO.Path]::GetFileName($appFile)), it might be a runtime package."
            }
            finally {
                Remove-Item $tmpFolder -Recurse -Force
            }
        }
    }

    $global:_validationResult = @()
    $apps | % {
        $appFile = $_
    
        $tmpFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder ([Guid]::NewGuid().ToString())
        try {
            $artifactUrl = Get-BcContainerArtifactUrl -containerName $containerName

            Extract-AppFileToFolder -appFilename $appFile -appFolder $tmpFolder -generateAppJson
            $appJson = Get-Content (Join-Path $tmpFolder "app.json") | ConvertFrom-Json

            $ruleset = $null

            if ("$rulesetFile" -ne "" -or $enableAppSourceCop) {
                $ruleset = [ordered]@{
                    "name" = "Run-AlCops RuleSet"
                    "description" = "Generated by Run-AlCops"
                    "includedRuleSets" = @()
                }
            }

            if ($rulesetFile) {
                $ruleset.includedRuleSets += @(@{ 
                    "action" = "Default"
                    "path" = $ruleSetFile
                })
            }

            if ($enableAppSourceCop) {
                Write-Host "Analyzing: $([System.IO.Path]::GetFileName($appFile))"
                Write-Host "Using affixes: $([string]::Join(',',$affixes))"
                Write-Host "Using supportedCountries: $([string]::Join(',',$supportedCountries))"
                $appSourceCopJson = @{
                    "mandatoryAffixes" = @($affixes)
                    "supportedCountries" = @($supportedCountries)
                }
                if ($previousAppVersions.ContainsKey("$($appJson.Publisher)_$($appJson.Name)")) {
                    $previousVersion = $previousAppVersions."$($appJson.Publisher)_$($appJson.Name)"
                    $appSourceCopJson += @{
                        "Publisher" = $appJson.Publisher
                        "Name" = $appJson.Name
                        "Version" = $previousVersion
                    }
                    Write-Host "Using previous app: $($appJson.Publisher)_$($appJson.Name)_$previousVersion.app"
                }
                $appSourceCopJson | ConvertTo-Json -Depth 99 | Set-Content (Join-Path $tmpFolder "appSourceCop.json")

                $appSourceRulesetFile = Join-Path $tmpFolder "appsource.default.ruleset.json"
                Download-File -sourceUrl "https://bcartifacts.azureedge.net/rulesets/appsource.default.ruleset.json" -destinationFile $appSourceRulesetFile
                $ruleset.includedRuleSets += @(@{ 
                    "action" = "Default"
                    "path" = $appSourceRulesetFile
                })

                Write-Host "AppSourceCop.json content:"
                get-content  (Join-Path $tmpFolder "appSourceCop.json") | Out-Host
            }
            Remove-Item -Path (Join-Path $tmpFolder '*.xml') -Force
            $length = $global:_validationResult.Length
            $Parameters = @{
                "containerName" = $containerName
                "credential" = $credential
                "appProjectFolder" = $tmpFolder
                "appOutputFolder" = $tmpFolder
                "appSymbolsFolder" = $appPackagesFolder
                "EnableAppSourceCop" = $enableAppSourceCop
                "EnableUICop" = $enableUICop
                "EnableCodeCop" = $enableCodeCop
                "EnablePerTenantExtensionCop" = $enablePerTenantExtensionCop
                "outputTo" = { Param($line) 
                    Write-Host $line
                    if ($line -like "$($tmpFolder)*" -and $line -notlike "*: info AL1027*") {
                        $global:_validationResult += $line.SubString($tmpFolder.Length+1)
                    }
                }
            }
            if (!$failOnError) {
                $Parameters += @{ "ErrorAction" = "SilentlyContinue" }
            }

            if ($ruleset) {
                $rulesetFile = Join-Path $tmpFolder "ruleset.json"
                $ruleset | ConvertTo-Json -Depth 99 | Set-Content $rulesetFile
                $Parameters += @{
                    "ruleset" = $rulesetFile
                }
                Write-Host "Ruleset.json content:"
                get-content  $rulesetFile | Out-Host
            }

            Invoke-Command -ScriptBlock $CompileAppInBcContainer -ArgumentList ($Parameters) | Out-Null

            if ($ignoreWarnings) {
                Write-Host "Ignoring warnings"
                $global:_validationResult = $global:_validationResult | Where-Object { $_ -notlike "*: warning *" }
            }

            $lines = $global:_validationResult.Length - $length
            if ($lines -gt 0) {
                $i = 0
                $global:_validationResult = $global:_validationResult | ForEach-Object { 
                    if ($i++ -eq $length) {
                        "$lines $(if ($ignoreWarnings) { "errors" } else { "errors/warnings"}) found in $([System.IO.Path]::GetFileName($appFile)) on $($artifactUrl.Split('?')[0]):"
                    }
                    $_
                }
                $global:_validationResult += ""
            }
            Copy-Item -Path $appFile -Destination $appPackagesFolder -Force
        }
        finally {
            Remove-Item -Path $tmpFolder -Recurse -Force
        }
    }
    if ($appPackFolderCreated) {
        Remove-Item $appPackagesFolder -Recurse -Force
    }
    Remove-Item $appsFolder -Recurse -Force

    $global:_validationResult
    Clear-Variable -Scope global -Name "_validationResult"
}
Export-ModuleMember -Function Run-AlCops