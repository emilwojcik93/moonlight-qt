@{
    # Errors and warnings are gating; Information-level style hints (OutputType, positional parameters) are not.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Non-interactive SYSTEM task: console-style messages are written with Write-Output/Write-Host on purpose.
        'PSAvoidUsingWriteHost',
        # Internal helper naming (Get-UpdReleases, Read-Sha256Sums ...): plural nouns are intentional.
        'PSUseSingularNouns',
        # Internal helpers of an unattended script; New-* are in-memory factories, state-changing helpers are only reachable
        # through update.ps1 / install-task.ps1 (the latter implements -WhatIf itself). ShouldProcess prompts would hang a SYSTEM task.
        'PSUseShouldProcessForStateChangingFunctions',
        # Dependency-injection scriptblocks (production + test fakes) share one positional signature; not every consumer uses every argument.
        'PSReviewUnusedParameter'
    )
}
