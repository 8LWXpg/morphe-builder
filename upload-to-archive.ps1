#requires -Version 7
<#
.SYNOPSIS
Upload an APK/bundle to an Internet Archive item, under the apks/<package-id>/<filename>
layout that dl-apk.sh's archive-dlurl fallback expects (see CONFIG.md).

.EXAMPLE
./upload-to-archive.ps1 -FilePath C:\Downloads\jp.naver.line.android-26.14.0-arm64-v8a.apkm -PackageId jp.naver.line.android

.EXAMPLE
./upload-to-archive.ps1 -FilePath .\line.apkm -PackageId jp.naver.line.android -Item my-apk-archive
#>
param(
	[Parameter(Mandatory)]
	[ValidateScript({ Test-Path $_ -PathType Leaf })]
	[string]$FilePath,

	# package id, e.g. jp.naver.line.android - the file must be named "<PackageId>-<version>-<arch>.(apk|apkm|xapk)"
	[Parameter(Mandatory)]
	[string]$PackageId,

	# archive.org item identifier; created on first upload if it doesn't exist yet
	[string]$Item = '8LWXpg',

	# override the uploaded filename; defaults to the local file's own name
	[string]$RemoteFileName
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command ia -ErrorAction SilentlyContinue)) {
	throw "'ia' CLI not found on PATH. Install it with: pip install internetarchive; then run: ia configure"
}

if (-not $RemoteFileName) {
	$RemoteFileName = Split-Path -Leaf $FilePath
}

$remotePath = "apks/$PackageId/$RemoteFileName"
$downloadUrl = "https://archive.org/download/$Item/apks/$PackageId"

Write-Host "Uploading '$FilePath' -> item '$Item', path '$remotePath'" -ForegroundColor Green

& ia upload $Item $FilePath `
	"--remote-name=$remotePath" `
	'--metadata=mediatype:software' `
	"--metadata=title:$Item"
if ($LASTEXITCODE -ne 0) {
	throw "ia upload failed with exit code $LASTEXITCODE"
}

Write-Host 'Done. Note: archive.org processes new files asynchronously, it may take a few minutes to appear.' -ForegroundColor Green
Write-Host "Set this app's archive-dlurl in config.toml to:" -ForegroundColor Green
Write-Host "  archive-dlurl = `"$downloadUrl`"" -ForegroundColor Cyan
