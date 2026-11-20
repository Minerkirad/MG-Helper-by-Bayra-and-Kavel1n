@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',            # console menu - Write-Host is intentional
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseApprovedVerbs',               # Ensure/Archive/Prune are private helpers
        'PSUseSingularNouns',
        'PSReviewUnusedParameter'           # Logger/Foreground are used via scope
    )
}
