@{
    # Use PSScriptAnalyzer's full default rule set (no IncludeRules restriction).
    # Fail the build on both errors and warnings.
    Severity     = @('Error', 'Warning')

    # No ExcludeRules: nothing in this repo has been found to misfire against
    # the default rule set. If a rule ever needs to be excluded, add it here
    # with a comment explaining why.
    ExcludeRules = @()
}
