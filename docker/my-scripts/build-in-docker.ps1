# build-in-docker.ps1
param (
    [string]$buildType = "both"
)

$containerName = "thingsboard-build"
$hostDir = "C:\GitHub\ti\thingsboard"
$containerDir = "/home/thingsboard"
$dockerImage = "thingsboard-dev"

Write-Host ""
Write-Host "==== 🐳 Docker Build Environment ===================================="
Write-Host "🔧 Build type      : $buildType"
Write-Host "📂 Host directory  : $hostDir"
Write-Host "📁 Container path  : $containerDir"
Write-Host "📦 Docker image    : $dockerImage"
Write-Host "======================================================================"
Write-Host ""

docker run --rm -it `
    --name $containerName `
    -v "${hostDir}:${containerDir}" `
    -w $containerDir `
    -e BUILD_TYPE=$buildType `
    $dockerImage `
    bash -c "./build.sh"