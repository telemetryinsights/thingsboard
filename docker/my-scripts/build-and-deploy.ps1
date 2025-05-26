param (
    [switch]$buildOnly,
    [switch]$deployOnly
)

Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Definition)

# -----------------------------
# Environment setup
# -----------------------------
$dockerImage = "thingsboard-dev"
$containerName = "thingsboard-build"
$containerDir = "/home/thingsboard"
$hostDir = "C:\GitHub\ti\thingsboard"
# $containerMountPath = "/home/thingsboard"
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
Log "⚙️ Full Frontend and Backend build started..."

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
        docker build -f "$hostDir\docker\Dockerfile.dev" -t $dockerImage "$hostDir"
        if ($LASTEXITCODE -ne 0) {
            Log "❌ Docker image build failed."
            exit 1
        }
    }

    if (docker ps -a --format '{{.Names}}' | Select-String "^$containerName$") {
        Log "Removing old container '$containerName'..."
        docker rm -f $containerName | Out-Null
    }

    # Use dev source directly (no temp copy)
    $tempDir = $hostDir
    Log "🔗 Using direct dev source from: $tempDir"

    # Normalize paths for Docker
    $tempDir = $tempDir -replace '\\', '/'
    $containerDir = $containerDir -replace '\\', '/'
    $m2Path = "$env:USERPROFILE/.m2" -replace '\\', '/'
    $yarnPath = "$env:LOCALAPPDATA/Yarn/Cache" -replace '\\', '/'

    Log "🚀 Launching container '$containerName'..."
    docker run -dit --name $containerName `
        -v "${tempDir}:${containerDir}" `
        -v "${m2Path}:/root/.m2" `
        -v "${yarnPath}:/usr/local/share/.cache/yarn" `
        -w $containerDir `
        $dockerImage bash

    if ($LASTEXITCODE -ne 0) {
        Log "❌ Failed to start Docker container."
        exit 1
    }

    $srcSummary = Get-ChildItem -Recurse $tempDir | Measure-Object -Property Length -Sum
    $fileCount = (Get-ChildItem -Recurse $tempDir -File).Count
    $dirCount = (Get-ChildItem -Recurse $tempDir -Directory).Count
    $totalSize = "{0:N0}" -f ($srcSummary.Sum)
    Log "📦 Using $fileCount files and $dirCount directories (~$totalSize bytes) from live dev source."

    # Log "📦 Building Angular frontend (Yarn)..."
    $sysInfoCommand = "echo '=== System Info ===' && free -h && echo && echo '=== CPU Info ===' && lscpu | grep -E '^CPU\(s\)|Model name|Architecture' && echo && echo '=== Load & Uptime ===' && uptime"
    docker exec $containerName bash -c "$sysInfoCommand"

    # Log "📦 Installing dependencies for ui-ngx..."
    # docker exec $containerName bash -c "cd $containerMountPath/ui-ngx && yarn install"
    # if ($LASTEXITCODE -ne 0) {
    #     Log "❌ Installing dependencies for ui-ngx failed."
    #     exit 1
    # }

    # Log "📦 Installing dependencies for msa/web-ui..."
    # docker exec $containerName bash -c "cd $containerMountPath/msa/web-ui && yarn install"
    # if ($LASTEXITCODE -ne 0) {
    #     Log "❌ Installing dependencies for msa/web-ui failed."
    #     exit 1
    # }

    # Log "🎨 Building Angular UI (ui-ngx)..."
    # docker exec $containerName bash -c "cd $containerMountPath/ui-ngx && yarn build"
    # if ($LASTEXITCODE -ne 0) {
    #     Log "❌ Frontend build failed."
    #     exit 1
    # }

    # Log "📁 Verifying built UI assets exist..."
    # docker exec $containerName bash -c "ls -l ui-ngx/target/generated-resources/public"


    Log "🧱 Building Backend with Maven..."
    docker exec $containerName bash -c "$sysInfoCommand"
    # docker exec $containerName bash -c "cd $containerMountPath && mvn clean install -DskipTests -Dlicense.skip=true"
    docker exec $containerName bash -c "cd application && mvn clean install -DskipTests -Dlicense.skip=true"

    if ($LASTEXITCODE -ne 0) {
        Log "❌ Backend build failed."
        exit 1
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