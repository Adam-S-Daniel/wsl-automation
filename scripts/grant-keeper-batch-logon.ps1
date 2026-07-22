#requires -Version 7.6
<#
.SYNOPSIS
    Grants a user the "Log on as a batch job" right (SeBatchLogonRight), required by the
    background Claude Code Session Keeper scheduled task.

.DESCRIPTION
    Set-WslAutomationScheduledTasks registers the session keeper as an S4U ("run whether the
    user is logged on or not", no stored password) task so its frequent check runs in the
    non-interactive session 0 and never flashes a window on the desktop. An S4U task needs the
    SeBatchLogonRight user right.

    On a machine where the interactive user is a local administrator this is NOT satisfied by
    the default "Administrators" grant: an S4U logon produces a UAC-filtered token in which the
    Administrators group is deny-only, so a right granted to Administrators does not apply. This
    script therefore grants the right to the user's own SID, which stays enabled in the filtered
    token.

    Must be run elevated (as Administrator). Idempotent: granting a right the account already
    holds is a no-op. Uses LsaAddAccountRights so only this one right is touched (unlike a
    secedit /configure of the whole USER_RIGHTS area).

.PARAMETER UserSid
    SID of the account to grant the right to. Defaults to the current user's SID.

.EXAMPLE
    ./grant-keeper-batch-logon.ps1

    Grants SeBatchLogonRight to the current user. Run from an elevated PowerShell.

.EXAMPLE
    ./grant-keeper-batch-logon.ps1 -UserSid 'S-1-5-21-...-1001'

    Grants the right to a specific account SID.
#>
[CmdletBinding()]
param(
    [string]$UserSid = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'grant-keeper-batch-logon.ps1 can only run on Windows.'
}

$isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'This script must be run elevated (as Administrator) - it modifies a user right.'
}

Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class KeeperLsaRights {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
        public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaOpenPolicy(IntPtr SystemName, ref LSA_OBJECT_ATTRIBUTES ObjectAttributes,
        int AccessMask, out IntPtr PolicyHandle);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern uint LsaAddAccountRights(IntPtr PolicyHandle, byte[] AccountSid,
        LSA_UNICODE_STRING[] UserRights, int CountOfRights);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr PolicyHandle);
    [DllImport("advapi32.dll")]
    static extern int LsaNtStatusToWinError(uint status);

    static LSA_UNICODE_STRING ToLsaString(string s) {
        var u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)((s.Length + 1) * 2);
        return u;
    }

    public static void Grant(string sidString, string right) {
        var sid = new SecurityIdentifier(sidString);
        var sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);

        var oa = new LSA_OBJECT_ATTRIBUTES();
        oa.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));

        IntPtr policy;
        // POLICY_CREATE_ACCOUNT (0x0010) | POLICY_LOOKUP_NAMES (0x0800)
        uint status = LsaOpenPolicy(IntPtr.Zero, ref oa, 0x0810, out policy);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        try {
            var rights = new[] { ToLsaString(right) };
            status = LsaAddAccountRights(policy, sidBytes, rights, 1);
            if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        } finally {
            LsaClose(policy);
        }
    }
}
'@

[KeeperLsaRights]::Grant($UserSid, 'SeBatchLogonRight')
Write-Information -MessageData "Granted SeBatchLogonRight to $UserSid." -InformationAction Continue
