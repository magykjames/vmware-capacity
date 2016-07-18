#VMware Capacity and Provisioning Report
#By James Couch and Chad King
#EVT Corporation
#Version 1.5.17
#5-17-16

#Changelog:
#Reports stats for CPU and Memory usage based on Powered On VM's only, and reports stats for storage based on All VMs.
#Loops through a list of vCenters and clusters, and only queries clusters that are in the currently connected vCenter.
#Calculates CPU Ready Average and Top 10% per cluster.
#Requirements: Powershell 3.0, PowerCLI 5.5

#Sets up paths and variables.
$vcenters = import-csv .\vcenters.csv
$output = @()
$capacity = @()
$captable = @()
$cpuready = @()
$vmcpuready = @()
$scriptpath = ".\"
$listpath = "$scriptpath\serverlists"
$outfile = "$scriptpath\Capacity\Reports\capacity_$(get-date -format MMdd_HHmm).csv"
#$vCPUTargetRatio = read-host "vCPU to pCPU Target Ratio?"
#$vRAMTargetRatio = read-host "vRAM to pRAM Target Ratio?"
$vCPUTargetRatio = 6
$vRAMTargetRatio = 2

#Gets CPU, RAM, and Storage allocation values and calculates ratios.
foreach ($item in $vcenters) {

	$vmcpuready = $null
	$vmcpuready = @()
	$cpuready = $null
	$cpurdytop10 = $null
	$cpurdytop10ave = $null

	#Connect to correct vCenter based on input file.
	if (($global:DefaultViServers).Name -ne $item.vcenter) {
	disconnect-viserver * -confirm:$false
	connect-viserver $item.vcenter
	}


#Get hosts from clusters.
write-host "Get hosts from "$item.cluster""
$vmhosts = Get-Cluster $item.cluster | get-vmhost
$vms = $vmhosts | Get-VM
$pwronvms = $vms | where {$_.PowerState -eq "PoweredOn"}

#Gather physical stats and VM data from hosts.
#CPU
write-host "Gather CPU stats from "$item.cluster""
$pCPU = $vmhosts | Measure-Object NumCpu -Sum
$pCPU = $pCPU.Sum
$vCPUCap = ($pCPU * $vCPUTargetRatio)
#RAM
write-host "Gather RAM stats from "$item.cluster""
$pRAM = $vmhosts | Measure-Object MemoryTotalGB -Sum
$pRAM = $pRAM.Sum
$vRAMCap = ($pRAM * $vRAMTargetRatio)
#Storage
write-host "Gather Storage stats from "$item.cluster""
$ds = get-cluster $item.cluster | get-datastore | Select Name, CapacityGB, FreeSpaceGB
$PhysCap = $ds | where-object {$_.Name -NotLike "*local*"} | measure-object CapacityGB -Sum
$PhysCap = $PhysCap.Sum


#Calculate vCPU values for Powered On only.
write-host "Measure and calculate stats."
$vCPU = $vms | where-object {$_.PowerState -eq "PoweredOn"} | measure-object NumCPU -Sum
$vCPU = $vCPU.Sum
#Calculate vCPU to pCPU ratio for Powered On VMs.
$vCPURatio = ([math]::round($vCPU / $pCPU,1))
$vCPURatio = "{0:N1}" -f $vCPURatio
$vCPURemaining = ($vCPUCap - $vCPU)

#Calculate vRAM allocation and compares to physical RAM

#Calculate vRAM values Powered On VMs
$vRAM = $vms | where-object {$_.PowerState -eq "PoweredOn"} | measure-object MemoryGB -Sum
$vRAM = $vRAM.Sum
#Calculate vRAM to pRAM Ratio (Powered On)
$vRAMRatio = ([math]::round($vRAM / $pRAM,1))
$vRAMRatio = "{0:N1}" -f $vRAMRatio
$vRAMRemaining = ($vRAMCap - $vRAM)

#Storage usage for All VMs.
$ProvSpace = $vms | measure-object ProvisionedSpaceGB -Sum
$ProvSpace = $ProvSpace.Sum
$UsedSpace = $vms | measure-object UsedSpaceGB -Sum
$UsedSpace = $UsedSpace.Sum
$FreeSpace = $ds | where-object {$_.Name -NotLike "*local*"} | measure-object FreeSpaceGB -Sum
$FreeSpace = $FreeSpace.Sum
$ProvPercent = ([math]::round(($ProvSpace / $PhysCap) * 100,1))

	#Calculate average CPU Ready over past 7 days.
	#Loop through the VM list and gather stats for each Powered On VM.
	foreach ($vm in $vms | where {$_.PowerState -eq "PoweredOn"}) {
		$tempcpurdy = $null
		$tempcpurdyave = $null
		#Capture stats.
		write-host "Calculate CPU Ready stats for $vm."
		$tempcpurdy = get-stat -entity $vm -stat cpu.ready.summation -start (get-date).adddays(-7) -intervalmins 30 -instance ""
		#Calculate average for time period and convert to % value.
		#Average divided by 30 minute interval converted to milliseconds, multiply by 100 and divide by number of CPU's.
		$tempcpurdyave = ([math]::round((((($tempcpurdy | measure-object value -ave).average) / 1800000) * 100) / $vm.NumCPU,2))
		#Add average to array, reject values that are less than 0.01%.
		$vmcpuready += ($tempcpurdyave | where {$_ -ge .01})
		#Repeat for next VM.
	}

	#Calculate average of all VMs on cluster.
	write-host "Aggregate CPU ready values from "$item.cluster""
	$cpuready = ([math]::round(($vmcpuready | measure-object -ave).average,2))
	# $cpureadymax = ([math]::round(($vmcpuready | measure-object -max).maximum,2))
	$cpurdytop10 = $vmcpuready | sort -desc | select -first ([math]::round($vmcpuready.count * .1,0))
	$cpurdytop10ave = ([math]::round(($cpurdytop10 | measure-object -ave).average,2))
		if ($vms.count -eq 0) {
			$cpuready = 0
			$cpurdytop10ave = 0
		}


#Adds counts and ratios to table.
write-host "Add values to table for "$item.cluster""
$capacity = New-Object PSObject
$capacity | Add-Member -MemberType Noteproperty "Cluster" -value $item.cluster
$capacity | Add-Member -MemberType Noteproperty "Total # of Hosts" -value $vmhosts.count
$capacity | Add-Member -MemberType Noteproperty "Total # of VMs" -value $pwronvms.count
$capacity | Add-Member -MemberType Noteproperty "vCPURatio" -value "$vCPURatio`:1"
$capacity | Add-Member -MemberType Noteproperty "pCPU" -value $pCPU
$capacity | Add-Member -MemberType Noteproperty "vCPU" -value $vCPU
$capacity | Add-Member -MemberType Noteproperty "vCPU Cap" -value $vCPUCap
$capacity | Add-Member -MemberType Noteproperty "vCPU Remaining" -value $vCPURemaining
$capacity | Add-Member -MemberType Noteproperty "CPUReady%" -value "$cpuready`%"
$capacity | Add-Member -MemberType Noteproperty "Top10%CPUReady" -value "$cpurdytop10ave`%"
$capacity | Add-Member -MemberType Noteproperty "vRAMRatio" -value "$vRAMRatio`:1"
$capacity | Add-Member -MemberType Noteproperty "pRAM" -value ([math]::round($pRAM / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "vRAM" -value ([math]::round($vRAM / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "vRAM Cap" -value ([math]::round($vRAMCap / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "vRAM Remaining" -value ([math]::round($vRAMRemaining / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "Provisioned Space" -value ([math]::round($ProvSpace / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "Physical Capacity" -value ([math]::round($PhysCap / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "Used Space" -value ([math]::round($UsedSpace / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "Free Space" -value ([math]::round($FreeSpace / 1024,3))
$capacity | Add-Member -MemberType Noteproperty "Provisioned %" -value "$ProvPercent`%"
$captable += $capacity
}
$output += $captable | Convertto-CSV -NoTypeInformation

$output | Set-Content $outfile
start excel $outfile