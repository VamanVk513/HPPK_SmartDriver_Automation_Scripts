
$currentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
$testadmin = $currentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if ($testadmin -eq $false) {
Start-Process powershell.exe -Verb RunAs -ArgumentList ('-ExecutionPolicy Unrestricted -noprofile -noexit -file "{0}" -elevated' -f ($myinvocation.MyCommand.Definition))
exit $LASTEXITCODE
}

# Get our script path
try
{
    $ScriptPath = (Get-Variable MyInvocation).Value.MyCommand.Path
    $ScriptDir = Split-Path -Parent $ScriptPath
    $portName = "HPSmartPrintingPort"
    $printDriverName = "HP Smart Printing"
    $printDriverNameDebug = "HP Smart Printing (Debug)"
	$regRoamQueuePortName = "RoamQueuePortName"
	$Global:FileName = null
}
catch 
{
}

#
# Launches an elevated process running the current script to perform tasks
# that require administrative privileges.  This function waits until the
# elevated process terminates.
#

function InstallTestCertificatesFromDriver
{
	Param(
		[string] $DriverRootPath
	)

	$Result = $false
	$CertificateAdded = @{}
	
	$CertStore = Get-Item "cert:\LocalMachine\Root"
	$CertStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

	$CertificatesToAdd = (Get-AuthenticodeSignature (Join-Path $DriverRootPath "*.cat")).SignerCertificate
	if($CertificatesToAdd -and ($CertificatesToAdd.Count -gt 0))
	{
		$CertificatesToAdd | ForEach-Object {
			$CertKey = $_.Subject
			if(-not $CertificateAdded.ContainsKey($CertKey))
			{
				Write-Host "[InstallTestCertificatesFromDriver]: Adding certificate $CertKey to Root"
				$CertificateAdded[$CertKey] = $true
				$CertStore.Add($_)
				$Result = $true
			}
		}		
	}
	else
	{
		Write-Host "[InstallTestCertificatesFromDriver]: Could not extract certificate from driver. Make sure the driver is signed" -ForegroundColor Yellow
	}
	$CertStore.Close()

	return $Result
}

function InstallTestCertificatesFromFile
{
	Param(
		[string] $CertificatesRootPath
	)
	
	$Result = $false
	$CertificatesToAdd = (Get-ChildItem -Recurse -Path $CertificatesRootPath -Filter "*.cer")		
	if($CertificatesToAdd -and ($CertificatesToAdd.Count -gt 0))
	{
		$CertificatesToAdd | ForEach-Object {
			Write-Host "[InstallTestCertificatesFromFile]: Adding certificate $_.Name to Root"
			certutil.exe -addstore "Root" $_.FullName
		}
		$Result = $true
	}

	return $Result	
}

function InstallTestCertificates
{
	Param(
		[string] $DriverRootPath
	)
	
	$Result = $false
	$IsDriverTestCertificatesInstalled = InstallTestCertificatesFromDriver $DriverRootPath
	$IsFileTestCertificatesInstalled = InstallTestCertificatesFromFile $DriverRootPath

	if((-not $IsDriverTestCertificatesInstalled) -and (-not $IsFileTestCertificatesInstalled))
	{
		Write-Host "[Smart Driver] Wher are the certificate files[certificates directory]?:" -ForegroundColor Red -NoNewLine
		$CertificatesRootPath = Read-Host
		$IsFileTestCertificatesInstalled = InstallTestCertificatesFromFile $CertificatesRootPath
	}

	$Result = $IsDriverTestCertificatesInstalled -or $IsFileTestCertificatesInstalled

	if(-not $Result)
	{
		Write-Host "[InstallTestCertificates]: Failed to add any certificates to store after multiple attempts.", -ForegroundColor Red -NoNewLine
		Write-Host "Either provide the correct path to .cat file(s) or .cer file(s) or add them manually if driver installation fails." -ForegroundColor Red		
	}

	return $Result
}

function CheckOSArchitecture
{
	$OSArch = (Get-WmiObject -Class Win32_OperatingSystem | Select-Object    OSArchitecture -ErrorAction Stop).OSArchitecture
	Write-Host "Required Driver for platform $OSArch"
	if ($OSArch -match '64') {
		$Arch = "x64"
	}	
	elseif (($OSArch -match '32')) {
		$Arch = "x86"
	}	
	$Global:FileName = "HPOneDriver_SPD_*" + $Arch + "*.inf"
	# Write-Host $Global:FileName	
}

function IsDebugDriver
{
	Param(
		[string] $inffilepath = ""
	)
	$Result = $false
	$FoundInFile = $false
	
	if($inffilepath -and (Test-Path $inffilepath))
	{
		Write-Host "[IsDebugDriver]: Parsing $inffilepath"
        (Get-Content $inffilepath) | ForEach-Object {
			if(-not $FoundInFile)
			{
				if($_ -match '("HP Smart)([^"]*)Debug([^"]*)(")')
				{
					$FoundInFile = $true;
					$Result = $true;
				}
				elseif($_ -match '("HP Smart)([^"]*)(")')
				{
					$FoundInFile = $true;
					$Result = $false;
				}
			}
		}
	}
	
	if(-not $FoundInFile)
	{
		Write-Host "[Smart Driver]" -NoNewLine
		Write-Host "Is Debug Driver [yes/no]?" -ForegroundColor "Red" -NoNewLine
		Write-Host ":" -NoNewline
		$IsDriverTypeDebug = Read-Host
		if (($IsDriverTypeDebug -ieq "yes") -or ($IsDriverTypeDebug -ieq "y")) 
		{
			$Result = $true
		}
	}

	return $Result
}

function DoInstallSmartDriver
{
	# Get driver root path from user
	Write-Host "[Smart Driver] Where is the driver stored? " -NoNewline
	Write-Host " (Directory of INF file)" -ForegroundColor Red -NoNewline
	Write-Host ":" -NoNewline
	$DriverRootPath = Read-Host

	if($DriverRootPath)
	{
		$IsTestCertificatesInstalled = InstallTestCertificates $DriverRootPath
		if(-not $IsTestCertificatesInstalled)
		{
			Write-Host "[DoInstallSmartDriver]: Could not install test certificates. Continuing with driver installation." -ForegroundColor Yellow
		}
		
		# Make INF file path
		$infPath = ""
		$infPathPattern = Join-Path $DriverRootPath $Global:FileName
		$infPaths = (Get-ChildItem $infPathPattern)
		if($infPaths -and ($infPaths.Count -gt 0))
		{
			$infPath = $infPaths[0]
		}
	
		if($infPath)
		{
			Write-Host "[DoInstallSmartDriver]: Installing: $infPath"
			
			$isDD = IsDebugDriver $infPath
			if($isDD)
			{
				$printDriverName = $printDriverNameDebug
			}

			# Read DriverVer from INF file
			$pattern = 'DriverVer\s*=\s*(?:\d+/\d+/\d+,)?(.*)'
			$driverVer = Select-String -Pattern $pattern -Path $infPath |
				select -Expand Matches -First 1 |
				% { $_.Groups[1].Value }
			
			Write-Host "[DoInstallSmartDriver]: DriverName: $printDriverName, DriverVersion: $driverVer"
		
			# Check port
			$portExists = Get-Printerport -Name $portname -ErrorAction SilentlyContinue
			if (-not $portExists) 
			{
			  Add-PrinterPort -name $portName
			}
			else 
			{
				Write-Host "[DoInstallSmartDriver]: Port $portname already exists" -ForegroundColor Yellow
			}
			# Check printer queue
			$printerExists = Get-Printer -name $printDriverName -ErrorAction SilentlyContinue
			if ($printerExists) 
			{
				Write-Host "[DoInstallSmartDriver]: Removing existing queues"
				Remove-Printer -Name $printDriverName
				Write-Host "[DoInstallSmartDriver]: Removed existing queues"
			}
			# Check printer driver
			$printDriverExists = Get-PrinterDriver -name $printDriverName -ErrorAction SilentlyContinue
			if ($printDriverExists) 
			{
				Write-Host "[DoInstallSmartDriver]: Removing existing drivers"
				Remove-PrinterDriver -Name $printDriverName -RemoveFromDriverStore
				Write-Host "[DoInstallSmartDriver]: Removed existing queues"
			}
		
			# Add driverstore using pnputil.exe
			Write-Host "[DoInstallSmartDriver]: Staging smart driver"
			pnputil.exe -i -a $infPath
			Write-Host "[DoInstallSmartDriver]: Staged smart driver"

			# Add printer driver
			Write-Host "[DoInstallSmartDriver]: Installing smart driver"
			Add-PrinterDriver -Name $printDriverName
			Write-Host "[DoInstallSmartDriver]: Installed smart driver"

			# Add printer queue
			Write-Host "[DoInstallSmartDriver]: Installing smart printing queue"
			Add-Printer -Name $printDriverName -PortName $portName -DriverName $printDriverName
			Write-Host "[DoInstallSmartDriver]: Installed smart printing queue"
		
			# Set 'Print spooled documents first' as true
			$Printer = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$printDriverName'"
			if($Printer)
			{
				$Printer.DoCompleteFirst = $true
				Set-CimInstance -InputObject $Printer
			}
			else
			{
				Write-Host "[DoInstallSmartDriver]: Failed to find smart printing queue while attempting to set properties" -ForegroundColor Red
			}
			
			# Set 'RoamQueuePortName' value in DsDriver
			$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers\" + $printDriverName + "\DsDriver"
			Set-Itemproperty -path $regPath -Name $regRoamQueuePortName -Value $portname
			
			Write-Host "[DoInstallSmartDriver]: Successfully installed smart driver" -ForegroundColor Green
		}
		else
		{
			Write-Host "[DoInstallSmartDriver]: Failed to install smart driver as no inf found in $DriverRootPath" -ForegroundColor Red
		}
	}
	else
	{
		Write-Host "[DoInstallSmartDriver]: Failed to install smart driver as no driver folder specified" -ForegroundColor Red
	}
}

#
# Main script entry point
#
CheckOSArchitecture
DoInstallSmartDriver

# SIG # Begin signature block
# MIIakgYJKoZIhvcNAQcCoIIagzCCGn8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCVPa5qkJ3nMdRD
# lgi2gDDGecdGK4vj1BHqCWjkC1ya3qCCCnAwggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggU4MIIEIKADAgECAhABJEgQqjRE/Y7t3bYCbgAkMA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMjAxMjE1MDAwMDAw
# WhcNMjExMjE5MjM1OTU5WjB1MQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZv
# cm5pYTESMBAGA1UEBxMJUGFsbyBBbHRvMRAwDgYDVQQKEwdIUCBJbmMuMRkwFwYD
# VQQLExBIUCBDeWJlcnNlY3VyaXR5MRAwDgYDVQQDEwdIUCBJbmMuMIIBIjANBgkq
# hkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAl5j2SOcJ6mcQEOc4cdAaaXYn/1jdk4sg
# 6bu/CttkCGXRaXMBoH2ELr5aq6RYVkv5AGgaiGtTeKHX+Iwe0/WsBtsbZitCw/W/
# IZ3V7RHc13Tkspumo5oHRp3UUge2YcbMoErEWI6fk8R3BNDhYCCD4kct1RWKL3hW
# Fr1lcaq+/c4gdQHi1bj0xDLdfFoeYn5W0M0aNSyavShROmeWBvo5tupPNG0x4/NP
# QoZx3/vSg1xn0XgzgDu/Yke84v5bH+JrhCIDAK6CP/LkNt0z0tEMcpABv3d9NcjR
# Qy9LmiFobsJOhmRleaqwk+TBGdUA0721uv0/V/8V9UX5J2Jrs0Z0LQIDAQABo4IB
# xTCCAcEwHwYDVR0jBBgwFoAUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHQYDVR0OBBYE
# FIOren8y5k+m4UdvNDVHef39kfd9MA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAK
# BggrBgEFBQcDAzB3BgNVHR8EcDBuMDWgM6Axhi9odHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vc2hhMi1hc3N1cmVkLWNzLWcxLmNybDA1oDOgMYYvaHR0cDovL2NybDQu
# ZGlnaWNlcnQuY29tL3NoYTItYXNzdXJlZC1jcy1nMS5jcmwwTAYDVR0gBEUwQzA3
# BglghkgBhv1sAwEwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQu
# Y29tL0NQUzAIBgZngQwBBAEwgYQGCCsGAQUFBwEBBHgwdjAkBggrBgEFBQcwAYYY
# aHR0cDovL29jc3AuZGlnaWNlcnQuY29tME4GCCsGAQUFBzAChkJodHRwOi8vY2Fj
# ZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRTSEEyQXNzdXJlZElEQ29kZVNpZ25p
# bmdDQS5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAQEA5MCGaB4m
# oGNM8slQyEXnGkkCK1c3YTVVOmSpmeHijOk5b45lxaHka2f3aoSVuGKiDcKUCYyl
# xYO9BbdkrVcBVlDypOCCYhwK7tHiyqbLdguBT3jlmvPVoisdtMGocrH+jVKjVAHD
# Ba+rQ82A2lo0+aPQWjcNvvTr9I/HxGQm4ZYT3mjBWw7k3s4mVTRiW/f/MUAFgFo6
# 6Lfpra4/Xd0qob9N44Tv60eVUORBy1Dnj+HAqnmtu0IMHdSSbqkQDE6cPOWYvUxJ
# xoOpDWNtosBDTdpm5CnkPlJeTATL91haxJOdnXoJcBJbeXt8OP2VAv3/zRKyQ4cc
# nL7W1/q4ue7vGjGCD3gwgg90AgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNV
# BAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0ECEAEk
# SBCqNET9ju3dtgJuACQwDQYJYIZIAWUDBAIBBQCgfDAQBgorBgEEAYI3AgEMMQIw
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYK
# KwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgODobyohjnChSPyHS17yYEQLE/uOl
# NAeGHKqAis97gUAwDQYJKoZIhvcNAQEBBQAEggEAM8nmlGe00VkuX/XYVSLqju5t
# +Ht0GTQbjAc5pepIgw2bBvAx1BaZjadAd+CR7VeURvez5AkZr9u0uJoTcKJdIlIX
# mCOnhFnT72YV/xFXEppOcuJVgrNxNN4H7FUOD/yFm+WEXndm8v5J/2v7GfB1lC3L
# M/44qzBmC51tghBN7hkH4VQG/bItMjqAk00H3Ob2BDQYhyPUaetMBGThdlP4zuNA
# 5HY1BAQ1BN/oaLYmdvb7RCJ30opgSw2wy6BAK6b6qEDkvUiQllFe/Cu0j0hnhejx
# pZFbgEAJE/EPRM5KeQlhy40Fnhy9+okhivVbKUVoRgA5EijYD1s4vO7sTYZcAaGC
# DUQwgg1ABgorBgEEAYI3AwMBMYINMDCCDSwGCSqGSIb3DQEHAqCCDR0wgg0ZAgED
# MQ8wDQYJYIZIAWUDBAIBBQAwdwYLKoZIhvcNAQkQAQSgaARmMGQCAQEGCWCGSAGG
# /WwHATAxMA0GCWCGSAFlAwQCAQUABCDmarFj0bqF8WHiaiMK9euGp/uvCYlTjYxU
# 8by4A9vXsgIQLgdD6c54tXAWxZPSaOVr+RgPMjAyMTAzMzEyMzE2MThaoIIKNzCC
# BP4wggPmoAMCAQICEA1CSuC+Ooj/YEAhzhQA8N0wDQYJKoZIhvcNAQELBQAwcjEL
# MAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3
# LmRpZ2ljZXJ0LmNvbTExMC8GA1UEAxMoRGlnaUNlcnQgU0hBMiBBc3N1cmVkIElE
# IFRpbWVzdGFtcGluZyBDQTAeFw0yMTAxMDEwMDAwMDBaFw0zMTAxMDYwMDAwMDBa
# MEgxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjEgMB4GA1UE
# AxMXRGlnaUNlcnQgVGltZXN0YW1wIDIwMjEwggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDC5mGEZ8WK9Q0IpEXKY2tR1zoRQr0KdXVNlLQMULUmEP4dyG+R
# awyW5xpcSO9E5b+bYc0VkWJauP9nC5xj/TZqgfop+N0rcIXeAhjzeG28ffnHbQk9
# vmp2h+mKvfiEXR52yeTGdnY6U9HR01o2j8aj4S8bOrdh1nPsTm0zinxdRS1LsVDm
# QTo3VobckyON91Al6GTm3dOPL1e1hyDrDo4s1SPa9E14RuMDgzEpSlwMMYpKjIjF
# 9zBa+RSvFV9sQ0kJ/SYjU/aNY+gaq1uxHTDCm2mCtNv8VlS8H6GHq756WwogL0sJ
# yZWnjbL61mOLTqVyHO6fegFz+BnW/g1JhL0BAgMBAAGjggG4MIIBtDAOBgNVHQ8B
# Af8EBAMCB4AwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDBB
# BgNVHSAEOjA4MDYGCWCGSAGG/WwHATApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3
# LmRpZ2ljZXJ0LmNvbS9DUFMwHwYDVR0jBBgwFoAU9LbhIB3+Ka7S5GGlsqIlssgX
# NW4wHQYDVR0OBBYEFDZEho6kurBmvrwoLR1ENt3janq8MHEGA1UdHwRqMGgwMqAw
# oC6GLGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9zaGEyLWFzc3VyZWQtdHMuY3Js
# MDKgMKAuhixodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVkLXRz
# LmNybDCBhQYIKwYBBQUHAQEEeTB3MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5k
# aWdpY2VydC5jb20wTwYIKwYBBQUHMAKGQ2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydFNIQTJBc3N1cmVkSURUaW1lc3RhbXBpbmdDQS5jcnQwDQYJ
# KoZIhvcNAQELBQADggEBAEgc3LXpmiO85xrnIA6OZ0b9QnJRdAojR6OrktIlxHBZ
# vhSg5SeBpU0UFRkHefDRBMOG2Tu9/kQCZk3taaQP9rhwz2Lo9VFKeHk2eie38+dS
# n5On7UOee+e03UEiifuHokYDTvz0/rdkd2NfI1Jpg4L6GlPtkMyNoRdzDfTzZTlw
# S/Oc1np72gy8PTLQG8v1Yfx1CAB2vIEO+MDhXM/EEXLnG2RJ2CKadRVC9S0yOIHa
# 9GCiurRS+1zgYSQlT7LfySmoc0NR2r1j1h9bm/cuG08THfdKDXF+l7f0P4TrweOj
# SaH6zqe/Vs+6WXZhiV9+p7SOZ3j5NpjhyyjaW4emii8wggUxMIIEGaADAgECAhAK
# oSXW1jIbfkHkBdo2l8IVMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUw
# EwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20x
# JDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xNjAxMDcx
# MjAwMDBaFw0zMTAxMDcxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxE
# aWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMT
# KERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBUaW1lc3RhbXBpbmcgQ0EwggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC90DLuS82Pf92puoKZxTlUKFe2I0rE
# DgdFM1EQfdD5fU1ofue2oPSNs4jkl79jIZCYvxO8V9PD4X4I1moUADj3Lh477sym
# 9jJZ/l9lP+Cb6+NGRwYaVX4LJ37AovWg4N4iPw7/fpX786O6Ij4YrBHk8JkDbTuF
# fAnT7l3ImgtU46gJcWvgzyIQD3XPcXJOCq3fQDpct1HhoXkUxk0kIzBdvOw8YGqs
# LwfM/fDqR9mIUF79Zm5WYScpiYRR5oLnRlD9lCosp+R1PrqYD4R/nzEU1q3V8mTL
# ex4F0IQZchfxFwbvPc3WTe8GQv2iUypPhR3EHTyvz9qsEPXdrKzpVv+TAgMBAAGj
# ggHOMIIByjAdBgNVHQ4EFgQU9LbhIB3+Ka7S5GGlsqIlssgXNW4wHwYDVR0jBBgw
# FoAUReuir/SSy4IxLVGLp6chnfNtyA8wEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNV
# HQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgweQYIKwYBBQUHAQEEbTBr
# MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYBBQUH
# MAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJ
# RFJvb3RDQS5jcnQwgYEGA1UdHwR6MHgwOqA4oDaGNGh0dHA6Ly9jcmw0LmRpZ2lj
# ZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwOqA4oDaGNGh0dHA6
# Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmww
# UAYDVR0gBEkwRzA4BgpghkgBhv1sAAIEMCowKAYIKwYBBQUHAgEWHGh0dHBzOi8v
# d3d3LmRpZ2ljZXJ0LmNvbS9DUFMwCwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUA
# A4IBAQBxlRLpUYdWac3v3dp8qmN6s3jPBjdAhO9LhL/KzwMC/cWnww4gQiyvd/Mr
# HwwhWiq3BTQdaq6Z+CeiZr8JqmDfdqQ6kw/4stHYfBli6F6CJR7Euhx7LCHi1lss
# FDVDBGiy23UC4HLHmNY8ZOUfSBAYX4k4YU1iRiSHY4yRUiyvKYnleB/WCxSlgNcS
# R3CzddWThZN+tpJn+1Nhiaj1a5bA9FhpDXzIAbG5KHW3mWOFIoxhynmUfln8jA/j
# b7UBJrZspe6HUSHkWGCbugwtK22ixH67xCUrRwIIfEmuE7bhfEJCKMYYVs9BNLZm
# XbZ0e/VWMyIvIjayS6JKldj1po5SMYICTTCCAkkCAQEwgYYwcjELMAkGA1UEBhMC
# VVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0
# LmNvbTExMC8GA1UEAxMoRGlnaUNlcnQgU0hBMiBBc3N1cmVkIElEIFRpbWVzdGFt
# cGluZyBDQQIQDUJK4L46iP9gQCHOFADw3TANBglghkgBZQMEAgEFAKCBmDAaBgkq
# hkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTIxMDMzMTIz
# MTYxOFowKwYLKoZIhvcNAQkQAgwxHDAaMBgwFgQU4deCqOGRvu9ryhaRtaq0lKYk
# m/MwLwYJKoZIhvcNAQkEMSIEIElK3g43Z7GRWEZU9vIk+yo9J4riHC/dIfDxik4e
# lgVEMA0GCSqGSIb3DQEBAQUABIIBAKKfYTRViyYXhr0gVOaaZYJRO+NjIupKdIdc
# SOD+7UzUhGs6pfD56hrxraQH8csL1mOTYXP+XclRwhrxqZUAAXoVhq06HuN+G2Pf
# /m9qtEvNtRjPCkc816sntyzS7KaJkSu6nnwPu71ruLyljR8PYcqHdxMBy73uMKyK
# ujRvEppFmgyfi5zwrZtAAoLjFi8+ZMA3BLX0qaIQkXG45s7V029eZ/rv1OlWQaKD
# Qibddv437ggPKd+oFoManrdwZGqi83AFPmdQQOx+n3pFxdS7hTOJlJbjFsOKL1gz
# YTiwd1slqhoyoSGFTqXxfwUskpZTIuzihJiNh9g5lnEK1gbbGO4=
# SIG # End signature block
