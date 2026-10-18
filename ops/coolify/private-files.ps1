function Protect-RecoveryPath {
 param([Parameter(Mandatory)][string]$Path)
 $item=Get-Item -LiteralPath $Path -Force
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Private recovery paths cannot be reparse points.'}
 $acl=[IO.FileSystemAclExtensions]::GetAccessControl($item,[Security.AccessControl.AccessControlSections]::Access)
 $acl.SetAccessRuleProtection($true,$false)
 foreach($rule in @($acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]))){$acl.RemoveAccessRuleSpecific($rule)}
 $ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 $systemSid=[Security.Principal.SecurityIdentifier]::new('S-1-5-18')
 $inheritance=if($item.PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
 foreach($sid in @($ownerSid,$systemSid)){
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
 }
 [IO.FileSystemAclExtensions]::SetAccessControl($item,$acl)
 $actual=[IO.FileSystemAclExtensions]::GetAccessControl($item,[Security.AccessControl.AccessControlSections]::Access)
 $rules=@($actual.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 if(-not $actual.AreAccessRulesProtected -or $rules.Count -ne 2 -or @($rules|Where-Object{$_.IdentityReference.Value -notin @($ownerSid.Value,$systemSid.Value) -or $_.AccessControlType -ne 'Allow' -or $_.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or $_.IsInherited}).Count){throw 'Private recovery ACL verification failed.'}
}
function New-RecoveryDirectory {
 param([Parameter(Mandatory)][string]$Path)
 $absolute=[IO.Path]::GetFullPath($Path)
 $ancestor=$absolute
 while($ancestor){
  if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Private recovery path has a reparse-point ancestor.'}}
  $ancestor=[IO.Path]::GetDirectoryName($ancestor)
 }
 $null=[IO.Directory]::CreateDirectory($absolute)
 Protect-RecoveryPath $absolute
}
