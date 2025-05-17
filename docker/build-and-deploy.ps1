param (
    [switch]$buildOnly,
    [switch]$deployOnly,
    [switch]$feOnly,
    [switch]$beOnly
)

Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Definition)

# -----------------------------
# Environment setup
# -----------------------------
$dockerImage = "thingsboard-dev"
$containerName = "thingsboard-build"
$hostDir = "C:\GitHub\ti\thingsboard"
$containerMountPath = "/home/thingsboard"
$remoteHost = "192.168.86.122"
$remoteUser = "piadmin"
$remoteDir = "/usr/share/thingsboard/bin"
$tempPath = "/tmp/thingsboard.jar"
$sshUserHost = "${remoteUser}@${remoteHost}"
$plink = "C:\Program Files\PuTTY\plink.exe"
$pscp = "C:\Program Files\PuTTY\pscp.exe"
$ppk = "$HOME\.ssh\id_pi_nopass.ppk"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "build-deploy-$timestamp.log"
$startTime = Get-Date

# -----------------------------
# Logger function
# -----------------------------
function Log($msg) {
    $time = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "$time - $msg"
    $entry | Tee-Object -FilePath $logFile -Append
}

Log "==== Build and Deploy Script Started ===="

# -----------------------------
# Build Mode Routing
# -----------------------------
if ($feOnly -and $beOnly) {
    Log "⚙️ Both -feOnly and -beOnly specified → full build"
}
elseif (-not $feOnly -and -not $beOnly) {
    $feOnly = $true
    $beOnly = $true
    Log "🔁 No build scope specified → defaulting to full frontend + backend build"
}
elseif ($feOnly) {
    Log "🎨 Frontend-only build mode enabled"
}
elseif ($beOnly) {
    Log "🔧 Backend-only build mode enabled"
}

if ($buildOnly) {
    Log "⚙️ Build Only mode enabled"
}
elseif ($deployOnly) {
    Log "🚚 Deploy Only mode enabled"
}
else {
    Log "🔁 Full Build and Deploy mode"
}

# -----------------------------
# Step 1: Build using Docker
# -----------------------------
if (-not $deployOnly) {
    Log "Starting Docker build..."

    if (-not (docker images -q $dockerImage)) {
        Log "🛠 Building Docker image '$dockerImage'..."
        docker build -f "$hostDir\\Dockerfile-dev" -t $dockerImage "$hostDir"
        if ($LASTEXITCODE -ne 0) {
            Log "❌ Docker image build failed."
            exit 1
        }
    }

    if (docker ps -a --format '{{.Names}}' | Select-String "^$containerName$") {
        Log "Removing old container '$containerName'..."
        docker rm -f $containerName | Out-Null
    }

    Log "🚀 Launching container '$containerName'..."
    docker run -dit --name $containerName $dockerImage bash
    if ($LASTEXITCODE -ne 0) {
        Log "❌ Failed to start Docker container."
        exit 1
    }

    # Host-side summary
    $srcSummary = Get-ChildItem -Recurse $hostDir | Measure-Object -Property Length -Sum
    $fileCount = (Get-ChildItem -Recurse $hostDir -File).Count
    $dirCount = (Get-ChildItem -Recurse $hostDir -Directory).Count
    $totalSize = "{0:N0}" -f ($srcSummary.Sum)
    Log "📦 Preparing to copy $fileCount files and $dirCount directories (~$totalSize bytes) to container..."

    # Copy essential build sources
    docker cp "$hostDir\application" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\ui-ngx" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\pom.xml" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\netty-mqtt" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\common" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\rule-engine" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\dao" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\edqs" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\transport" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\tools" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\msa" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\rest-client" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\monitoring" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\packaging" "${containerName}:$containerMountPath/"
    docker cp "$hostDir\docker\Dockerfile.dev" "${containerName}:$containerMountPath/"
    if ($LASTEXITCODE -ne 0) {
        Log "❌ Failed to copy source files into container."
        exit 1
    }

    # Container-side summary
    # $summaryScript = "cd $containerMountPath && echo '📁 Container copy summary: Files: ' \$(find . -type f | wc -l) ', Dirs: ' \$(find . -type d | wc -l) ', Bytes: ' \$(du -sb . | cut -f1)"


    # Log "📊 Verifying copy inside container..."
    # docker exec $containerName bash -c "cd /home/thingsboard && echo '📁 Container copy summary: Files: \$(find . -type f | wc -l), Dirs: \$(find . -type d | wc -l), Bytes: \$(du -sb . | cut -f1)'"

    # Frontend build (if enabled)
    if ($feOnly) {
        Log "📦 Building Angular frontend..."
        $sysInfoCommand = "echo '=== System Info ===' && free -h && echo && echo '=== CPU Info ===' && lscpu | grep -E '^CPU\(s\)|Model name|Architecture' && echo && echo '=== Load & Uptime ===' && uptime"
        docker exec $containerName bash -c "$sysInfoCommand"
        
        docker exec $containerName bash -c "cd $containerMountPath/ui-ngx && npm install && npm run build"
        if ($LASTEXITCODE -ne 0) {
            Log "❌ Frontend build failed."
            exit 1
        }
        
        Log "📁 Copying compiled FE assets into Maven target path..."
        docker exec $containerName bash -c "rm -rf ui-ngx/target/generated-resources/public && mkdir -p ui-ngx/target/generated-resources/public && cp -r ui-ngx/dist/thingsboard/* ui-ngx/target/generated-resources/public/"
    }

    # Backend build (if enabled)
    if ($beOnly) {
        Log "🧱 Building backend with Maven (skipping UI rebuild)..."
        $sysInfoCommand = "echo '=== System Info ===' && free -h && echo && echo '=== CPU Info ===' && lscpu | grep -E '^CPU\(s\)|Model name|Architecture' && echo && echo '=== Load & Uptime ===' && uptime"
        docker exec $containerName bash -c "$sysInfoCommand"
        
        docker exec $containerName bash -c "cd $containerMountPath && mvn clean install -DskipTests -Dlicense.skip=true"
        if ($LASTEXITCODE -ne 0) {
            Log "❌ Backend build failed."
            exit 1
        }
    }

    Log "✅ Docker build complete. Container retained for inspection."
}

# -----------------------------
# Step 2: Deploy to Pi
# -----------------------------
if (-not $buildOnly) {
    Log "📤 Deploying to Raspberry Pi..."

    $backendJar = (Get-ChildItem "$hostDir\application\target\thingsboard-*-boot.jar" | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    if (-not $backendJar) { Log "❌ Backend JAR not found. Aborting."; exit 1 }

    Log "Uploading JAR via SCP..."
    & $pscp -batch -i $ppk "$backendJar" "${sshUserHost}:$tempPath"
    if ($LASTEXITCODE -ne 0) { Log "❌ Failed to upload JAR."; exit 1 }

    Log "Backing up current deployment..."
    & $plink -batch -i $ppk $sshUserHost "sudo cp '$remoteDir/thingsboard.jar' '$remoteDir/thingsboard_$timestamp.jar'"

    Log "Replacing with new JAR..."
    & $plink -batch -i $ppk $sshUserHost "sudo mv '$tempPath' '$remoteDir/thingsboard.jar'"

    Log "🔄 Restarting ThingsBoard service..."
    & $plink -batch -i $ppk $sshUserHost "sudo systemctl restart thingsboard"
    Start-Sleep -Seconds 5

    Log "🔍 Verifying service status..."
    $status = & $plink -batch -i $ppk $sshUserHost "systemctl is-active thingsboard"

    $logEntry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Deploy result: "
    $emailSubject = ""
    $emailMsg = ""

    if ($status -eq "active") {
        Log "✅ ThingsBoard is running."
        $logEntry += "Success"
        $emailSubject = "ThingsBoard Deployment Success"
        $emailMsg = "Deployment succeeded at $timestamp. ThingsBoard service is active."
    }
    else {
        Log "❌ Service failed to start. Manual review needed."
        $logEntry += "Failure"
        $emailSubject = "ThingsBoard Deployment FAILED"
        $emailMsg = "Deployment failed at $timestamp. ThingsBoard service did not start."
    }

    Log "Logging result to Pi..."
    & $plink -batch -i $ppk $sshUserHost "echo '$logEntry' | sudo tee -a '$remoteDir/deploy.log'" | Out-Null

    Log "Sending email to sysadmin..."
    & $plink -batch -i $ppk $sshUserHost "echo '$emailMsg' | mail -s '$emailSubject' sysadmin@telemetryinsights.com" | Out-Null

    Log "✅ Deployment process complete."
}

# -----------------------------
# Step 3: Wrap Up
# -----------------------------
$duration = (Get-Date) - $startTime
Log "==== Script Finished in $($duration.TotalSeconds) seconds ===="
# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block

# SIG # Begin signature block
# MIIF0gYJKoZIhvcNAQcCoIIFwzCCBb8CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA8sSu5AUxXdkI9
# BjzxnuM2SVw9gmRJD0gdrhhIV/YZDKCCAz8wggM7MIICI6ADAgECAhA3hBj1nxca
# jES1e6v+1hyyMA0GCSqGSIb3DQEBCwUAMCMxITAfBgNVBAMMGFBvd2VyU2hlbGwg
# TG9jYWwgU2lnbmluZzAeFw0yNTA1MTUxMjEwMDNaFw0yNjA1MTUxMjMwMDNaMCMx
# ITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZzCCASIwDQYJKoZIhvcN
# AQEBBQADggEPADCCAQoCggEBAKhml2bldOfWPsCw2z8u/bVtu8nyLfZYEWZfiQcN
# w7eoLHyatQPcozOLSfoVAiEqCX9kasZQyGmnZpiIW9vACdytAU7or6BfIRYozRQr
# BXv6ilphOolvgtcV7seR3y3NSYLBKNuTNp4ImcfKxi4c4SCQvmtkHvwdZlaYbL9o
# JDHxnhcowQTCudFdXpsApYvIxBv4361TI01cH7kk+kgaB65NV67ZIBtTxWQFszWk
# i4nK6Y+fayCQE4rHUoSmJ3YBa7VhLOsm2uek4Ka6TUOuRRdZ9CInwvFNKG4aRSjo
# 99qJhqyTJ56hjJsznACD3ZAt758sP2DPcynIrKt6prMbJc0CAwEAAaNrMGkwDgYD
# VR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMCMGA1UdEQQcMBqCGFBv
# d2VyU2hlbGwgTG9jYWwgU2lnbmluZzAdBgNVHQ4EFgQUs2sKi+OJdOdSFzhe8SNw
# 1moTZdAwDQYJKoZIhvcNAQELBQADggEBAJzu1DcSl95uL37BDrPkdONyPAjgHSQ0
# dll23gdq45zEeaaosgoqbTBu/mzi6SOnmuEKzC9Xx97HQRcTOfbkmBY0RrDbRbTc
# v4fRtZxuAYThy1WGnI5cSbHGuBDbSN2ghzAPfOZcs9hRKbR44wPuq8JGvhGYwEgP
# qL2nbKpjI2oGNs7sl2hS1+ZTsHNIOy/v8tdZK1U0VzDzWD4JQY7Pfy+6T3LpMxz+
# 6PB1zuaeq8BMOYXFMZP72zZvgvjxx0MekiT3DOyRjB3kKPUgbNkD8J4nEeZaqq47
# izDDGsVW4axpEWWO5EQND2Tn0n5wN3cuFT9pa6ke41FkXLlVSQKWb+ExggHpMIIB
# 5QIBATA3MCMxITAfBgNVBAMMGFBvd2VyU2hlbGwgTG9jYWwgU2lnbmluZwIQN4QY
# 9Z8XGoxEtXur/tYcsjANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQow
# CKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcC
# AQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDv0nrRTRCyZlWbHC0G
# 0F3I/JXNNpwRHJgw4zEIAXQKFDANBgkqhkiG9w0BAQEFAASCAQBnGHMkeqZCChsb
# Y4J03L9CDQDQWqp7qdO+gorY4M52NL8DEezKcK58sT2/nxmwxt517aJ5r7CP5ni9
# 0fwlrRLFfariHtiMC31oz/0mqzdeP+uR5BtJIESgXPezp3n9XfdG4AFm+fpIFeOO
# +pYSI9+so0Dhz1yVoCnnrULMKUL2j0wwEAQ0u3Z1LVeoQQIe9wacdDeu2BxHnYlY
# YuRkc9S4MrloDWHFvqx5iK8AzEu1DkbJLN8SbG6ndvR0Prrc/aEc7CzwcIUU68ot
# 3KMpYFZV048nqKf/N02Tg6pv9r3GGNjBnEPxo7ySsXowISiK9ihNaadhtA/qAPvM
# K1eIdvcd
# SIG # End signature block
