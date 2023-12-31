<#
    .Example
    $password = Read-Host -AsSecureString
    .\New-EntraBGA.ps1 -AccountGivenName Casey -AccountGivenSurname Worste -AccountPassword $password
    .Notes
    Author: Robert Przybylski 
    azureblog.pl 2023
#>

[CmdletBinding()]

param (
    [Parameter(MAndatory)]
    [string] $AccountGivenName,
    [Parameter(MAndatory)]
    [string] $AccountGivenSurname,
    [Parameter(MAndatory)]
    [securestring] $AccountPassword
)

#region module test
$moduleTest = Get-InstalledModule Microsoft.Graph -ErrorAction SilentlyContinue
if ($null -eq $moduleTest) {
    Write-Host "Microsoft.Graph module is missing"
    Write-Host "Installing..."
    Install-module Microsoft.Graph -Scope CurrentUser | Out-Null
}
#endregion


Connect-MgGraph -Scopes User.ReadWrite.all, EntitlementManagement.ReadWrite.All, RoleManagement.ReadWrite.Directory, Policy.ReadWrite.ConditionalAccess

#region Creating BGA user
$passwordProfile = @{
    password = $AccountPassword
}

$domain = Get-MgDomain | Where-Object { $_.IsInitial -eq $true } | Select-Object -ExpandProperty ID
$mail = "$($AccountGivenName.ToLower())" + "." + "$($AccountGivenSurname.ToLower())"
$upn = $mail + "@" + $domain
$userTest = Get-MGUSer -all | where-object { $_.UserPrincipalName -eq $upn } -ErrorAction SilentlyContinue
if ($null -eq $userTest) {
    Write-Host "User with UPN '$upn' does not exist." -ForegroundColor Yellow
    Write-Host "Creating..."
    $bga = New-MGUSer -GivenName $AccountGivenName -Surname $AccountGivenSurname -DisplayName "$AccountGivenName $AccountGivenSurname" -AccountEnabled -UserPrincipalName $upn -PasswordProfile $passwordProfile -MailNickName $mail
    Write-Host "USer with UPN '$upn' has been created" -ForegroundColor Green
    $bgaID = $bga.id
}
else {
    Write-Host "User with UPN '$upn' already exists." -ForegroundColor Red
}
#endregion

#region Rolle assignement
$gaRoleDefinitionID = Get-MgRoleManagementDirectoryRoleDefinition | Where-Object { $_.DisplayName -eq "Global Administrator" } | Select-Object -ExpandProperty ID
#based on "https://learn.microsoft.com/en-us/entra/identity/role-based-access-control/permissions-reference"
$params = @{
    "@odata.type"    = "#microsoft.graph.unifiedRoleAssignment"
    roleDefinitionId = $gaRoleDefinitionID
    principalId      = $bgaID
    directoryScopeId = "/"
}
Write-Host "Assigning GA role with ID '$gaRoleDefinitionID' to upn '$upn' with id '$bgaID'" -ForegroundColor Green
New-MgRoleManagementDirectoryRoleAssignment -BodyParameter $params
#endregion

#region CA Policy exclude
$caPolicies = Get-MgIdentityConditionalAccessPolicy
Write-Host "Found '$($caPolicies.Count)' CA policies..." -ForegroundColor Yellow
foreach ($policy in $caPolicies) {
    Write-Host "Updating policy '$($policy.DisplayName)' to exclude BGA user with id '$bgaID'" -ForegroundColor Green
    $existingExcludeUsersID = (Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.ID).Conditions.users.ExcludeUsers
    $excludedUsers = @()
    $excludedUsers += $existingExcludeUsersID
    $excludedUsers += $bgaID
    $excludedUsers = $excludedUsers | Select-Object -Unique
    $existingExcludeGroupsID = (Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.ID).Conditions.users.ExcludeGroups

    $params = @{
        conditions = @{
            users = @{
                excludeUsers  = @(
                    $excludedUsers
                )
                excludeGroups = @(
                    $existingExcludeGroupsID
                )
            }
        }
    }
    Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $policy.ID -BodyParameter $params
}
#endregion

Write-Host "Script end."