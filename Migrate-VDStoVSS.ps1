function Migrate-VDStoVSS{
 #Requires -Modules VMware.VimAutomation.Core, VMware.VimAutomation.Vds

<#
.SYNOPSIS  
    Migrates an ESXi host from a Distributed Virtual Switch to a Standard Virtual Switch
.DESCRIPTION
    Migrates an ESXi host from a Distributed Virtual Switch to a Standard Virtual Switch
.NOTES
    Version:        1.0
    Author:         Tim Carman
    Twitter:        @tpcarman
    Github:         tpcarman
    
    Credits:	    William Lam (@lamw) - Creator of original script from which this script was developed
.LINK
    https://github.com/tpcarman/vCenter-Migration
.PARAMETER VMHost
    Specifies the name of the ESXi host
    This parameter is manadatory and does not have a default value.
.PARAMETER DVS_Name
    Specifies the name of the distributed virtual switch
    This parameter is manadatory and does not have a default value.	
.PARAMETER VSS_Name
    Specifies the name of the standard virtual switch
    This parameter is manadatory and does not have a default value.
.EXAMPLE
    Migrate-VDStoVSS -VMHost esx1.domain.corp -DVS_Name dvSwitch0 -VSS_Name vSwitchMigrate
#>

[CmdletBinding()]
Param(  
    [Parameter(Mandatory=$True,HelpMessage='Specify the name of the ESXi host')]
    [ValidateNotNullOrEmpty()]
    [String]$VMHost='',
           
    [Parameter(Mandatory=$True,HelpMessage='Specify the name of the distributed virtual switch')]
    [ValidateNotNullOrEmpty()]
    [String]$DVS_Name='',

    [Parameter(Mandatory=$True,HelpMessage='Specify the name of the standard virtual switch')]
    [ValidateNotNullOrEmpty()]
    [String]$VSS_Name=''
	)

$objVMHost = Get-VMHost -Name $VMHost

# VDS to migrate from
$vds = Get-VDSwitch -Name $vds_name -VMHost $VMHost
 
# Name of portgroups to create on VSS
$mgmt_name = (Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel | where{$_.ManagementTrafficEnabled -eq $true}).PortGroupName
$vmotion_name = (Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel | where{$_.VMotionEnabled -eq $true}).PortGroupName
 
Write-host "Processing $VMHost"

# Create new standard virtual switch (VSS)
if((Get-VirtualSwitch -VMHost $VMHost).Name -eq $VSS_Name){
    Write-host "Standard virtual switch $VSS_Name already exists"
}
else{
    Write-host "Creating standard virtual switch $VSS_Name"
    New-VirtualSwitch -Name $VSS_Name -VMHost $VMHost -Confirm:$false
}

# Array of pNICs to migrate to VSS
Write-host "Retrieving uplink information from $DVS_Name"
$esxcli = Get-EsxCli -VMHost $VMHost
$uplink_array = $esxcli.network.vswitch.dvs.vmware.list($vds.Name) | select -ExpandProperty Uplinks
$pnic_array = @()
foreach($uplink in $uplink_array){
    Write-host "Retrieving physical NIC information for $uplink"
    $vmnic = Get-VMHostNetworkAdapter -VMHost $vmhost -Name $uplink
    $pnic_array += $vmnic
} 

# vSwitch to migrate to
$vss = $objVMHost | Get-VirtualSwitch -Name $VSS_Name

# Create destination portgroups
$dvspgs = Get-VDPortgroup | where{$_.IsUplink -eq $False}
foreach($dvspg in $dvspgs){
    $pgName = $dvspg.name
    $pgvlan = $dvspg.vlanConfiguration.vlanid  
    $vsspg = Get-VirtualPortGroup -VMHost $VMHost -VirtualSwitch $vss -Standard | where {$_.Name -eq $pgName}
    if(!($vsspg)){       
        if($pgvlan -gt 0){
            Write-host "Creating virtual portgroup $pgName (VLAN $pgvlan) on standard virtual switch $VSS_Name"
            New-VirtualPortGroup -VirtualSwitch $vss -Name $pgName -VLanId $pgvlan
        }
        else{
            Write-host "Creating virtual portgroup $pgName on standard virtual switch $VSS_Name"
            New-VirtualPortGroup -VirtualSwitch $vss -Name $pgName
        }
    }
    else{
        Write-host "Virtual portgroup $pgName already exists"
    }
}
# Get VMkernal portgroups
$mgmt_pg = Get-VirtualPortGroup -Standard -VirtualSwitch $vss -Name $mgmt_name
$vmotion_pg = Get-VirtualPortGroup -Standard -VirtualSwitch $vss -Name $vmotion_name
 
# Array of portgroups to map VMkernel interfaces (order matters!)
$pg_array = @($mgmt_pg,$vmotion_pg)
 
# VMkernel interfaces to migrate to VSS
Write-host "Retrieving VMkernel interface details"
$mgmt_vmk = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel | where{$_.ManagementTrafficEnabled -eq $true}
$vmotion_vmk = Get-VMHostNetworkAdapter -VMHost $VMHost -VMKernel | where{$_.VMotionEnabled -eq $true}

# Array of VMkernel interfaces to migrate to VSS (order matters!)
$vmk_array = @($mgmt_vmk,$vmotion_vmk)
 
# Perform the migration
Write-host "Migrating from $vds_name to $VSS_Name"
Add-VirtualSwitchPhysicalNetworkAdapter -VirtualSwitch $vss -VMHostPhysicalNic $pnic_array -VMHostVirtualNic $vmk_array -VirtualNicPortgroup $pg_array -Confirm:$false

# Move VMs and Templates to new portgroups
$Templates = Get-Template
foreach($Template in $Templates){
    Set-Template -Template $Template -ToVM -Confirm:$false
    Get-NetworkAdapter -VM $Template.Name | %{
        Write-host "Setting network adapter on" $Template.Name "to" $_.NetworkName
        $_ | Set-NetworkAdapter -PortGroup (Get-VirtualPortGroup -VMHost $VMHost -Standard -Name $_.NetworkName) -Confirm:$false  
    }
    Set-VM -VM $Template.Name -ToTemplate -Confirm:$false
}

# Loop through guests and set their networks.
$VMlist = $objVMHost | Get-VM
foreach($VM in $VMlist){
    Get-NetworkAdapter $VM | %{
        Write-host "Setting network adapter on" $VM "to" $_.NetworkName
        $_ | Set-NetworkAdapter -PortGroup (Get-VirtualPortGroup -VMhost $VMHost -Standard -Name $_.NetworkName) -Confirm:$false
    }
}

# Remove host from Distributed Virtual Switch
Write-host "Removing $VMHost from $vds_name"
$vds | Remove-VDSwitchVMHost -VMHost $VMHost -Confirm:$false

}
