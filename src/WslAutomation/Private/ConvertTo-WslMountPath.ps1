function ConvertTo-WslMountPath {
    <#
    .SYNOPSIS
        Converts a Windows drive-letter path to the path WSL mounts it at.
    .DESCRIPTION
        'D:\Backups\wsl-restic' becomes '/mnt/d/Backups/wsl-restic': the drive letter is
        lowercased, backslashes become forward slashes, and a trailing separator is trimmed.
        The rest of the path keeps its case.

        This assumes WSL's default automount root, /mnt. A distro whose /etc/wsl.conf sets a
        different [automount] root would mount the drive elsewhere, and the result would be
        wrong for it.

        Throws on anything that is not an absolute drive-letter path - a UNC path
        ('\\server\share'), a relative path, or a drive-relative path such as 'D:Backups' -
        because none of those has a /mnt/<drive> equivalent.
    .PARAMETER Path
        The Windows path to convert.
    .EXAMPLE
        ConvertTo-WslMountPath -Path 'D:\Backups\wsl-restic\'

        Returns '/mnt/d/Backups/wsl-restic'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Path -notmatch '^(?<drive>[A-Za-z]):(?<rest>[\\/].*)?$') {
        throw "Not an absolute drive-letter path, so it has no /mnt/<drive> equivalent: $Path"
    }

    $drive = $Matches['drive'].ToLowerInvariant()
    $rest = "$($Matches['rest'])".Replace('\', '/').TrimEnd('/')
    "/mnt/$drive$rest"
}
