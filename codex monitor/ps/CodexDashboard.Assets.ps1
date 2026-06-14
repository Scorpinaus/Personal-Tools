# Dot-sourced by codex_usage_dashboard.ps1. Keep this file free of entry-point side effects.

function Get-DashboardAsset {
    param([string]$Path)

    switch ($Path) {
        "/" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "index.html"
                ContentType = "text/html; charset=utf-8"
            }
        }
        "/index.html" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "index.html"
                ContentType = "text/html; charset=utf-8"
            }
        }
        "/daily.html" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "daily.html"
                ContentType = "text/html; charset=utf-8"
            }
        }
        "/styles.css" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "styles.css"
                ContentType = "text/css; charset=utf-8"
            }
        }
        "/app.js" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "app.js"
                ContentType = "application/javascript; charset=utf-8"
            }
        }
        "/daily.js" {
            return [pscustomobject]@{
                File = Join-Path $DashboardRoot "daily.js"
                ContentType = "application/javascript; charset=utf-8"
            }
        }
        default {
            return $null
        }
    }
}

function Read-DashboardAsset {
    param([string]$Path)

    $asset = Get-DashboardAsset $Path
    if ($null -eq $asset) {
        return $null
    }

    if (-not (Test-Path -LiteralPath $asset.File -PathType Leaf)) {
        throw "Dashboard asset not found: $($asset.File)"
    }

    return [pscustomobject]@{
        Body = Get-Content -Raw -LiteralPath $asset.File
        ContentType = $asset.ContentType
    }
}
