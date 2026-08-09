# build.ps1  —  Compila las Lambdas de Go y las empaqueta para AWS Lambda (Windows)
# -----------------------------------------------------------------------------
# Requisitos (una sola vez):
#   go install github.com/aws/aws-lambda-go/cmd/build-lambda-zip@latest
#
# Uso, parado en la carpeta ccs-lambdas/:
#   .\build.ps1
# Compila cada subcarpeta con un main.go a  <lambda>/<lambda>.zip  (Linux/arm64).
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

# Ubicación de build-lambda-zip (lo instala 'go install' en el GOBIN/GOPATH\bin)
$zipper = Join-Path (go env GOPATH) "bin\build-lambda-zip.exe"
if (-not (Test-Path $zipper)) {
    Write-Error "No encuentro build-lambda-zip. Instálalo con: go install github.com/aws/aws-lambda-go/cmd/build-lambda-zip@latest"
}

# Compilación cruzada a Linux ARM64 (coincide con architectures=['arm64'] en Terraform)
$env:GOOS = "linux"
$env:GOARCH = "arm64"
$env:CGO_ENABLED = "0"

# Recorre cada subcarpeta que tenga un main.go
Get-ChildItem -Directory | ForEach-Object {
    $dir = $_.FullName
    $name = $_.Name
    if (Test-Path (Join-Path $dir "main.go")) {
        Write-Host "==> Compilando $name ..." -ForegroundColor Cyan
        Push-Location $dir

        # Resuelve dependencias (crea go.sum si falta) y compila el binario 'bootstrap'
        go mod tidy
        go build -o bootstrap main.go

        # Empaqueta con permisos de ejecución correctos
        & $zipper -o "$name.zip" bootstrap

        Remove-Item bootstrap -ErrorAction SilentlyContinue
        Pop-Location
        Write-Host "    OK -> $name\$name.zip" -ForegroundColor Green
    }
}

Write-Host "Listo. Zips generados." -ForegroundColor Green
