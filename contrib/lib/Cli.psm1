# Turning raw command-line tokens into something that can be handed to a command.
#
# WHY THIS IS NOT ONE LINE. PowerShell cannot forward named parameters by
# splatting an array: `& $script @tokens` passes EVERY element positionally,
# whatever the array's type, so "-WithBrowser" arrives as a positional string and
# is rejected. Only the automatic $args preserves named semantics, and only when
# forwarded whole -- which a dispatcher that must first strip <resource> <action>
# cannot do. Hashtable splatting does bind by name, so the tokens are bound here
# against the command's own parameter metadata and handed over as a hashtable.
#
# The upside of doing it explicitly: an unknown option can be reported with the
# list of real ones, instead of PowerShell's "a positional parameter cannot be
# found", which tells a reader nothing about what they should have typed.

$script:Common = [System.Management.Automation.PSCmdlet]::CommonParameters +
                 [System.Management.Automation.PSCmdlet]::OptionalCommonParameters

# The options a command actually declares, for help and for error messages.
function Get-CommandOptions([string]$Path) {
    $params = (Get-Command -Name $Path).Parameters
    return @($params.Keys | Where-Object { $_ -notin $script:Common } | Sort-Object)
}

function Resolve-OptionName($Params, [string]$Name) {
    $exact = @($Params.Keys | Where-Object { $_ -ieq $Name })
    if ($exact.Count -eq 1) { return $exact[0] }
    # PowerShell accepts unambiguous abbreviations; so does this.
    $prefix = @($Params.Keys | Where-Object { $_ -ilike "$Name*" })
    if ($prefix.Count -eq 1) { return $prefix[0] }
    if ($prefix.Count -gt 1) {
        throw "Option '-$Name' is ambiguous: $(($prefix | Sort-Object) -join ', ')"
    }
    return $null
}

function Resolve-OptionKey([string]$Path, $Params, [string]$Name) {
    $key = Resolve-OptionName $Params $Name
    if ($key) { return $key }
    $known = Get-CommandOptions $Path
    throw ("Unknown option '-$Name'." + [Environment]::NewLine +
           "  known: $(($known | ForEach-Object { "-$_" }) -join ', ')")
}

# -Switch:$false reaches us as the bare string 'False', because PowerShell has
# already expanded it. A quoted '-Switch:$false' keeps its sigil, so strip that
# too, and say something useful when the value is neither.
function ConvertTo-SwitchValue([string]$Key, [string]$Text) {
    $parsed = $false
    if ([bool]::TryParse(($Text -replace '^\$', ''), [ref]$parsed)) { return $parsed }
    throw "Option '-$Key' is a switch, so it takes `$true or `$false -- got '$Text'."
}

# Returns @{ Named = <hashtable>; Positional = <object[]> }, ready to splat as
#   & $path @positional @named
function ConvertTo-CommandArguments([string]$Path, [object[]]$Tokens) {
    $params     = (Get-Command -Name $Path).Parameters
    $named      = @{}
    $positional = [System.Collections.ArrayList]::new()

    for ($i = 0; $i -lt $Tokens.Count; $i++) {
        $token = [string]$Tokens[$i]

        # Anything not shaped like an option is positional. A negative number or
        # a path beginning with '-' therefore still passes through untouched.
        if ($token -notmatch '^-(?<name>[A-Za-z][A-Za-z0-9]*)(?::(?<value>.*))?$') {
            [void]$positional.Add($token)
            continue
        }

        $key      = Resolve-OptionKey $Path $params $Matches['name']
        $isSwitch = $params[$key].ParameterType -eq [switch]
        $inline   = if ($Matches.ContainsKey('value')) { $Matches['value'] } else { $null }

        # PowerShell SPLITS `-Name:value` into two elements before a param-less
        # script ever sees them -- `-Name:` and `value` -- so a token ending in
        # ':' carries its value in the NEXT one. Without this the empty string
        # was taken as the value and the real one fell through as positional,
        # which made `-Confirm:$false` fail with "String '' was not recognized
        # as a valid Boolean" -- the standard way to run a High-impact command
        # non-interactively.
        if ($inline -eq '') {
            if ($i + 1 -ge $Tokens.Count) { throw "Option '-$key' needs a value after the colon." }
            $i++
            $inline = [string]$Tokens[$i]
        }

        if ($null -ne $inline) {
            $named[$key] = if ($isSwitch) { ConvertTo-SwitchValue $key $inline } else { $inline }
        } elseif ($isSwitch) {
            $named[$key] = $true
        } else {
            if ($i + 1 -ge $Tokens.Count) { throw "Option '-$key' needs a value." }
            $i++
            $named[$key] = [string]$Tokens[$i]
        }
    }

    return @{ Named = $named; Positional = $positional.ToArray() }
}

Export-ModuleMember -Function Get-CommandOptions, ConvertTo-CommandArguments
