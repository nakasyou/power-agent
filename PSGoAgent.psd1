@{
    RootModule = 'PSGoAgent.psm1'
    ModuleVersion = '0.5.1'
    GUID = 'f5b8a8c7-5ba1-4eb1-b0a2-597a48c77af0'
    Author = 'PSGoAgent contributors'
    Description = 'PowerShell-only coding agent for OpenCode Go'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Get-GoVersion','Connect-GoMcp','Disconnect-GoMcp','Connect-GoCodex','Disconnect-GoCodex','Set-GoModel','Set-GoReasoning','New-GoAgent','Invoke-GoAgent','Save-GoSession','Import-GoSession','Get-GoModelCatalog','Get-GoTools','Invoke-GoTool')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
