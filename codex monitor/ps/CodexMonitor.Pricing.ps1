# Dot-sourced by codex_usage_monitor.ps1. Keep this file free of entry-point side effects.

function Get-ModelPricingTable {
    @(
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 30.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 10.00; CachedInputPerMillion = 1.00; OutputPerMillion = 45.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.75; CachedInputPerMillion = 0.075; OutputPerMillion = 4.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.20; CachedInputPerMillion = 0.02; OutputPerMillion = 1.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Standard"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 1.75; CachedInputPerMillion = 0.175; OutputPerMillion = 14.00 }

        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 1.25; CachedInputPerMillion = 0.125; OutputPerMillion = 7.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 11.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.375; CachedInputPerMillion = 0.0375; OutputPerMillion = 2.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Batch"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.10; CachedInputPerMillion = 0.01; OutputPerMillion = 0.625 }

        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 15.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.5"; ContextBand = "Long"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 22.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 1.25; CachedInputPerMillion = 0.125; OutputPerMillion = 7.50 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4"; ContextBand = "Long"; InputPerMillion = 2.50; CachedInputPerMillion = 0.25; OutputPerMillion = 11.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 0.375; CachedInputPerMillion = 0.0375; OutputPerMillion = 2.25 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Flex"; Model = "gpt-5.4-nano"; ContextBand = "Short"; InputPerMillion = 0.10; CachedInputPerMillion = 0.01; OutputPerMillion = 0.625 }

        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 12.50; CachedInputPerMillion = 1.25; OutputPerMillion = 75.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 5.00; CachedInputPerMillion = 0.50; OutputPerMillion = 30.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 1.50; CachedInputPerMillion = 0.15; OutputPerMillion = 9.00 }
        [pscustomobject]@{ Basis = "ApiUsdEstimate"; Unit = "USD"; Mode = "Priority"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 3.50; CachedInputPerMillion = 0.35; OutputPerMillion = 28.00 }

        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.5"; ContextBand = "Short"; InputPerMillion = 125.00; CachedInputPerMillion = 12.50; OutputPerMillion = 750.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.4"; ContextBand = "Short"; InputPerMillion = 62.50; CachedInputPerMillion = 6.25; OutputPerMillion = 375.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.4-mini"; ContextBand = "Short"; InputPerMillion = 18.75; CachedInputPerMillion = 1.875; OutputPerMillion = 113.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.3-codex"; ContextBand = "Short"; InputPerMillion = 43.75; CachedInputPerMillion = 4.375; OutputPerMillion = 350.00 }
        [pscustomobject]@{ Basis = "CodexCredits"; Unit = "credits"; Mode = "Standard"; Model = "gpt-5.2"; ContextBand = "Short"; InputPerMillion = 43.75; CachedInputPerMillion = 4.375; OutputPerMillion = 350.00 }
    )
}

function Get-PricingBand {
    param(
        [string]$Model,
        [long]$InputTokens
    )

    if ($Model -notin @("gpt-5.5", "gpt-5.4")) {
        return "Short"
    }

    if ($InputTokens -ge $script:LongContextThresholdTokens) {
        return "Long"
    }

    return "Short"
}

function Get-ApiModelPricing {
    param(
        [string]$Model,
        [string]$PricingBand = "Short"
    )

    $pricing = Get-ModelPricingTable |
        Where-Object { $_.Basis -eq "ApiUsdEstimate" -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
        Select-Object -First 1

    if ($null -eq $pricing -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq "ApiUsdEstimate" -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
            Select-Object -First 1
    }

    return $pricing
}

function Get-NoCompactionPricingBand {
    param(
        [string]$Model,
        [long]$CumulativeInputTokens
    )

    if ($CumulativeInputTokens -lt $script:LongContextThresholdTokens) {
        return "Short"
    }

    $longPricing = Get-ModelPricingTable |
        Where-Object { $_.Basis -eq "ApiUsdEstimate" -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Long" } |
        Select-Object -First 1

    if ($null -ne $longPricing) {
        return "Long"
    }

    return "Short"
}

function Get-ModelPricing {
    param(
        [string]$Model,
        [long]$InputTokens = 0,
        [string]$PricingBand = $null
    )

    if ([string]::IsNullOrWhiteSpace($PricingBand)) {
        $PricingBand = Get-PricingBand -Model $Model -InputTokens $InputTokens
    }

    $pricing = Get-ModelPricingTable |
        Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
        Select-Object -First 1

    if ($null -eq $pricing -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq $PricingMode -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
            Select-Object -First 1
    }

    if ($null -eq $pricing -and $CostBasisMode -eq "CodexCredits" -and $PricingMode -ne "Standard") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq "Standard" -and $_.Model -eq $Model -and $_.ContextBand -eq $PricingBand } |
            Select-Object -First 1
    }

    if ($null -eq $pricing -and $CostBasisMode -eq "CodexCredits" -and $PricingBand -eq "Long") {
        $pricing = Get-ModelPricingTable |
            Where-Object { $_.Basis -eq $CostBasisMode -and $_.Mode -eq "Standard" -and $_.Model -eq $Model -and $_.ContextBand -eq "Short" } |
            Select-Object -First 1
    }

    return $pricing
}

function Get-SessionInitialModel {
    param([string]$Path)

    foreach ($line in (Get-Content -LiteralPath $Path -TotalCount 200)) {
        if ($line -notlike '*"turn_context"*') {
            continue
        }

        $model = Get-JsonStringFromLine $line "model"
        if (-not [string]::IsNullOrWhiteSpace($model)) {
            return $model
        }
    }

    return "unknown"
}

function Set-EstimatedCost {
    param([object]$Bucket)

    if ($null -eq $Bucket -or [string]::IsNullOrWhiteSpace($Bucket.Model)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($Bucket.PricingBand)) {
        $Bucket.PricingBand = Get-PricingBand -Model $Bucket.Model -InputTokens ([long]$Bucket.Input)
    }
    $Bucket.PricingMode = $PricingMode
    $Bucket.CostBasisMode = $CostBasisMode

    $pricing = Get-ModelPricing -Model $Bucket.Model -InputTokens ([long]$Bucket.Input) -PricingBand $Bucket.PricingBand
    if ($null -eq $pricing) {
        $Bucket.BillingConfidence = "Low"
        return
    }

    $Bucket.BillingConfidence = "High"
    $Bucket.CostUnit = $pricing.Unit

    $cachedInput = [Math]::Max(0L, [long]$Bucket.CachedInput)
    $uncachedInput = [Math]::Max(0L, [long]$Bucket.Input - $cachedInput)
    $cost =
        ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
        ($cachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
        ([long]$Bucket.Output * [double]$pricing.OutputPerMillion / 1000000.0)

    $roundedCost = [Math]::Round($cost, 4)
    $Bucket.EstimatedCost = $roundedCost
    if ($pricing.Unit -eq "USD") {
        $Bucket.EstimatedCostUsd = $roundedCost
        $Bucket.EstimatedCostCredits = $null
    }
    elseif ($pricing.Unit -eq "credits") {
        $Bucket.EstimatedCostUsd = $null
        $Bucket.EstimatedCostCredits = $roundedCost
    }
}

function Set-NoCompactionEstimatedCost {
    param([object]$Bucket)

    if ($null -eq $Bucket -or [string]::IsNullOrWhiteSpace($Bucket.Model)) {
        return
    }

    $Bucket.PricingMode = $PricingMode
    $Bucket.CostBasisMode = "ApiNoCompactionUsdEstimate"
    $pricing = Get-ApiModelPricing -Model $Bucket.Model -PricingBand $Bucket.PricingBand
    if ($null -eq $pricing) {
        $Bucket.BillingConfidence = "Low"
        return
    }

    $cachedInput = [Math]::Max(0L, [long]$Bucket.CachedInput)
    $uncachedInput = [Math]::Max(0L, [long]$Bucket.Input - $cachedInput)
    $cost =
        ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
        ($cachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
        ([long]$Bucket.Output * [double]$pricing.OutputPerMillion / 1000000.0)

    $roundedCost = [Math]::Round($cost, 4)
    $Bucket.CostUnit = $pricing.Unit
    $Bucket.EstimatedCost = $roundedCost
    $Bucket.EstimatedCostUsd = $roundedCost
    $Bucket.EstimatedCostCredits = $null
    $Bucket.BillingConfidence = "Scenario"
}

function Get-EstimatedTextChars {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0L
    }

    if ($Value -is [string]) {
        return [long]$Value.Length
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $total = 0L
        foreach ($key in $Value.Keys) {
            if ([string]$key -eq "encrypted_content") {
                continue
            }

            $total += Get-EstimatedTextChars $Value[$key]
        }

        return $total
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $total = 0L
        foreach ($item in $Value) {
            $total += Get-EstimatedTextChars $item
        }

        return $total
    }

    if ($Value.PSObject -and $Value.PSObject.Properties) {
        $total = 0L
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -eq "encrypted_content") {
                continue
            }

            $total += Get-EstimatedTextChars $property.Value
        }

        return $total
    }

    return 0L
}

function Convert-CharsToEstimatedTokens {
    param([long]$Chars)

    if ($Chars -le 0) {
        return 0L
    }

    return [long][Math]::Ceiling([double]$Chars / 4.0)
}

function Get-TextFieldChars {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0L
    }

    if ($Value -is [string]) {
        return [long]$Value.Length
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $total = 0L
        foreach ($item in $Value) {
            $total += Get-TextFieldChars $item
        }

        return $total
    }

    $text = Get-PropValue $Value @("text")
    if ($null -ne $text) {
        return Get-TextFieldChars $text
    }

    $content = Get-PropValue $Value @("content")
    if ($null -ne $content) {
        return Get-TextFieldChars $content
    }

    return 0L
}

function Get-SourceEstimateFromEntry {
    param([object]$Entry)

    $payload = Get-PropValue $Entry @("payload")
    if ($null -eq $payload) {
        return $null
    }

    $entryType = Get-PropValue $Entry @("type")
    $payloadType = Get-PropValue $payload @("type")
    $source = $null
    $side = $null
    $chars = 0L
    $attribution = "Field text estimate"

    if ($entryType -eq "event_msg" -and $payloadType -eq "user_message") {
        $source = "User input"
        $side = "Input"
        $chars =
            (Get-TextFieldChars (Get-PropValue $payload @("message"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("text_elements", "textElements")))
    }
    elseif ($entryType -eq "response_item" -and $payloadType -eq "message") {
        $role = Get-PropValue $payload @("role")
        if ($role -eq "assistant") {
            $source = "Assistant output"
            $side = "Output"
            $chars = Get-TextFieldChars (Get-PropValue $payload @("content"))
        }
        elseif ($role -eq "user") {
            $source = "User context"
            $side = "Input"
            $chars = Get-TextFieldChars (Get-PropValue $payload @("content"))
        }
        elseif ($role -eq "developer" -or $role -eq "system") {
            $source = "System/developer context"
            $side = "Input"
            $chars = Get-TextFieldChars (Get-PropValue $payload @("content"))
        }
    }
    elseif ($entryType -eq "response_item" -and ($payloadType -eq "function_call" -or $payloadType -eq "custom_tool_call")) {
        $source = "Tool call arguments"
        $side = "Output"
        $chars = Get-TextFieldChars (Get-PropValue $payload @("arguments", "input"))
    }
    elseif ($entryType -eq "response_item" -and ($payloadType -eq "function_call_output" -or $payloadType -eq "custom_tool_call_output")) {
        $source = "Tool outputs"
        $side = "Input"
        $chars = Get-TextFieldChars (Get-PropValue $payload @("output"))
    }
    elseif ($entryType -eq "response_item" -and $payloadType -eq "reasoning") {
        $source = "Reasoning"
        $side = "Output"
        $chars =
            (Get-TextFieldChars (Get-PropValue $payload @("summary"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("content")))
        $attribution = "Visible reasoning text estimate"
    }
    elseif (($entryType -eq "response_item" -and $payloadType -eq "summary") -or ($entryType -eq "event_msg" -and $payloadType -eq "context_compacted") -or $entryType -eq "compacted") {
        $source = "Context summaries"
        $side = "Input"
        $chars =
            (Get-TextFieldChars (Get-PropValue $payload @("summary"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("content"))) +
            (Get-TextFieldChars (Get-PropValue $payload @("message", "text")))
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
        return $null
    }

    $tokens = Convert-CharsToEstimatedTokens $chars
    if ($tokens -le 0) {
        return $null
    }

    [pscustomobject]@{
        Source = $source
        Side = $side
        Tokens = $tokens
        Chars = $chars
        Attribution = $attribution
    }
}

function New-SourceEstimateBucket {
    param(
        [string]$Window,
        [string]$Model,
        [string]$Source
    )

    [pscustomobject]@{
        Window = $Window
        Model = $Model
        Source = $Source
        EstimatedInputTokens = 0L
        EstimatedOutputTokens = 0L
        EstimatedChars = 0L
        Events = 0
        Attribution = "Field text estimate"
    }
}

function Add-SourceEstimate {
    param(
        [hashtable]$Buckets,
        [string]$Window,
        [string]$Model,
        [object]$Estimate
    )

    if ($null -eq $Estimate) {
        return
    }

    $key = "{0}|{1}|{2}" -f $Window, $Model, $Estimate.Source
    if (-not $Buckets.ContainsKey($key)) {
        $Buckets[$key] = New-SourceEstimateBucket $Window $Model $Estimate.Source
    }

    if ($Estimate.Side -eq "Input") {
        $Buckets[$key].EstimatedInputTokens += [long]$Estimate.Tokens
    }
    else {
        $Buckets[$key].EstimatedOutputTokens += [long]$Estimate.Tokens
    }

    $Buckets[$key].EstimatedChars += [long]$Estimate.Chars
    if ($Estimate.Attribution -and $Buckets[$key].Attribution -ne $Estimate.Attribution) {
        $Buckets[$key].Attribution = "Mixed text estimate"
    }
    elseif ($Estimate.Attribution) {
        $Buckets[$key].Attribution = $Estimate.Attribution
    }
    $Buckets[$key].Events += 1
}

function Get-SourceCostRows {
    param(
        [object[]]$EstimateRows,
        [object[]]$ModelRows
    )

    function Get-MeasureSumOrZero {
        param(
            [object[]]$Rows,
            [string]$Property
        )

        if ($Rows.Count -eq 0) {
            return 0L
        }

        $measure = $Rows | Measure-Object -Property $Property -Sum
        if ($null -eq $measure -or $null -eq $measure.PSObject.Properties["Sum"] -or $null -eq $measure.Sum) {
            return 0L
        }

        return [long]$measure.Sum
    }

    $rows = @()
    foreach ($modelRow in $ModelRows) {
        $pricing = Get-ModelPricing -Model $modelRow.Model -InputTokens ([long]$modelRow.Input) -PricingBand $modelRow.PricingBand
        $sourceRows = @($EstimateRows | Where-Object { $_.Window -eq $modelRow.Window -and $_.Model -eq $modelRow.Model })

        $inputEstimateTotal = Get-MeasureSumOrZero -Rows $sourceRows -Property "EstimatedInputTokens"
        $outputEstimateTotal = Get-MeasureSumOrZero -Rows $sourceRows -Property "EstimatedOutputTokens"

        $expandedRows = @($sourceRows)
        if ([long]$modelRow.Input -gt $inputEstimateTotal) {
            $expandedRows += [pscustomobject]@{
                Window = $modelRow.Window
                Model = $modelRow.Model
                Source = "Unattributed input/context"
                EstimatedInputTokens = [long]$modelRow.Input - $inputEstimateTotal
                EstimatedOutputTokens = 0L
                EstimatedChars = 0L
                Events = 0
                Attribution = "Allocated remainder"
            }
            $inputEstimateTotal = [long]$modelRow.Input
        }

        if ([long]$modelRow.Output -gt $outputEstimateTotal) {
            $expandedRows += [pscustomobject]@{
                Window = $modelRow.Window
                Model = $modelRow.Model
                Source = "Unattributed output"
                EstimatedInputTokens = 0L
                EstimatedOutputTokens = [long]$modelRow.Output - $outputEstimateTotal
                EstimatedChars = 0L
                Events = 0
                Attribution = "Allocated remainder"
            }
            $outputEstimateTotal = [long]$modelRow.Output
        }

        foreach ($sourceRow in $expandedRows) {
            $rawInput = [long]$sourceRow.EstimatedInputTokens
            $rawOutput = [long]$sourceRow.EstimatedOutputTokens
            $rawTokens = $rawInput + $rawOutput
            $allocatedInput = 0L
            $allocatedOutput = 0L
            if ($inputEstimateTotal -gt 0 -and $rawInput -gt 0) {
                $allocatedInput = [long][Math]::Round([double]$modelRow.Input * [double]$rawInput / [double]$inputEstimateTotal)
            }

            if ($outputEstimateTotal -gt 0 -and $rawOutput -gt 0) {
                $allocatedOutput = [long][Math]::Round([double]$modelRow.Output * [double]$rawOutput / [double]$outputEstimateTotal)
            }

            $allocatedCachedInput = 0L
            if ([long]$modelRow.Input -gt 0 -and $allocatedInput -gt 0) {
                $allocatedCachedInput = [long][Math]::Round([double]$modelRow.CachedInput * [double]$allocatedInput / [double]$modelRow.Input)
            }

            $cost = $null
            $costUsd = $null
            $costCredits = $null
            if ($null -ne $pricing) {
                $uncachedInput = [Math]::Max(0L, $allocatedInput - $allocatedCachedInput)
                $costValue =
                    ($uncachedInput * [double]$pricing.InputPerMillion / 1000000.0) +
                    ($allocatedCachedInput * [double]$pricing.CachedInputPerMillion / 1000000.0) +
                    ($allocatedOutput * [double]$pricing.OutputPerMillion / 1000000.0)
                $cost = [Math]::Round($costValue, 4)
                if ($pricing.Unit -eq "USD") {
                    $costUsd = $cost
                }
                elseif ($pricing.Unit -eq "credits") {
                    $costCredits = $cost
                }
            }

            $rows += [pscustomobject]@{
                Window = $sourceRow.Window
                Model = $sourceRow.Model
                Source = $sourceRow.Source
                PricingMode = $PricingMode
                CostBasisMode = $CostBasisMode
                CostUnit = if ($null -ne $pricing) { $pricing.Unit } else { $null }
                PricingBand = $modelRow.PricingBand
                BillingConfidence = if ($null -eq $pricing) { "Low" } elseif ($sourceRow.Attribution -eq "Allocated remainder") { "Medium" } else { $modelRow.BillingConfidence }
                EstimatedChars = if ($null -ne $sourceRow.EstimatedChars) { [long]$sourceRow.EstimatedChars } else { 0L }
                EstimatedInputTokens = $rawInput
                EstimatedOutputTokens = $rawOutput
                EstimatedTokens = $rawTokens
                AllocatedInput = $allocatedInput
                AllocatedCachedInput = $allocatedCachedInput
                AllocatedOutput = $allocatedOutput
                AllocatedTokens = $allocatedInput + $allocatedOutput
                ReconciliationDelta = ($allocatedInput + $allocatedOutput) - $rawTokens
                Events = $sourceRow.Events
                EstimatedCost = $cost
                EstimatedCostUsd = $costUsd
                EstimatedCostCredits = $costCredits
                Attribution = $sourceRow.Attribution
            }
        }
    }

    return @($rows | Sort-Object Window, Model, Source)
}

function Get-TotalEstimatedCostUsd {
    param([object[]]$Rows)

    $total = 0.0
    foreach ($row in $Rows) {
        if ($null -ne $row.EstimatedCostUsd) {
            $total += [double]$row.EstimatedCostUsd
        }
    }

    return [Math]::Round($total, 4)
}

function Get-TotalEstimatedCostCredits {
    param([object[]]$Rows)

    $total = 0.0
    foreach ($row in $Rows) {
        if ($null -ne $row.EstimatedCostCredits) {
            $total += [double]$row.EstimatedCostCredits
        }
    }

    return [Math]::Round($total, 4)
}
