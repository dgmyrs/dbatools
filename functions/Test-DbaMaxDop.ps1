function Test-DbaMaxDop {
	<# 
		.SYNOPSIS 
			Displays information relating to SQL Server Max Degree of Parallelism setting. Works on SQL Server 2005-2016.

		.DESCRIPTION 
			Inspired by Sakthivel Chidambaram's post about SQL Server MAXDOP Calculator (https://blogs.msdn.microsoft.com/sqlsakthi/p/maxdop-calculator-SqlInstance/), 
			this script displays a SQL Server's: max dop configured, and the calculated recommendation.

			For SQL Server 2016 shows:
				- Instance max dop configured and the calculated recommendation
				- max dop configured per database (new feature)

			More info: 
				https://support.microsoft.com/en-us/kb/2806535
				https://blogs.msdn.microsoft.com/sqlsakthi/2012/05/23/wow-we-have-maxdop-calculator-for-sql-server-it-makes-my-job-easier/

			These are just general recommendations for SQL Server and are a good starting point for setting the "max degree of parallelism" option.

 		.PARAMETER SqlInstance
			The SQL Server instance(s) to connect to.

        .PARAMETER SqlCredential
			Allows you to login to servers using SQL Logins instead of Windows Authentication (AKA Integrated or Trusted). To use:

			$scred = Get-Credential, then pass $scred object to the -SqlCredential parameter.

			Windows Authentication will be used if SqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials.

			To connect as a different Windows user, run PowerShell as that user.

		.PARAMETER Detailed
			If this switch is enabled, detailed information related to MaxDop settings is returned.

		.NOTES 
			Tags: 
			Author  : Claudio Silva (@claudioessilva)
			Requires: sysadmin access on SQL Servers

			dbatools PowerShell module (https://dbatools.io, clemaire@gmail.com)
			Copyright (C) 2016 Chrissy LeMaire
            License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

		.LINK 
			https://dbatools.io/Test-DbaMaxDop

		.EXAMPLE   
			Test-DbaMaxDop -SqlInstance sql2008, sqlserver2012

			Get Max DOP setting for servers sql2008 and sqlserver2012 and also the recommended one.

		.EXAMPLE 
			Test-DbaMaxDop -SqlInstance sql2014 -Detailed

			Shows Max DOP setting for server sql2014 with the recommended value. As the -Detailed switch was used will also show the 'NUMANodes' and 'NumberOfCores' of each instance

		.EXAMPLE 
			Test-DbaMaxDop -SqlInstance sqlserver2016 -Detailed

			Get Max DOP setting for servers sql2016 with the recommended value. As the -Detailed switch was used will also show the 'NUMANodes' and 'NumberOfCores' of each instance. Because it is an 2016 instance will be shown 'InstanceVersion', 'Database' and 'DatabaseMaxDop' columns.

	#>
	[CmdletBinding()]
	Param (
		[parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $True)]
		[Alias("ServerInstance", "SqlServer", "SqlServers")]
		[DbaInstanceParameter[]]$SqlInstance,
		[PSCredential]$SqlCredential,
		[Switch]$Detailed
	)
	
	begin {
		$notesDopLT = "Before changing MaxDop, consider that the lower value may have been intentionally set."
		$notesDopGT = "Before changing MaxDop, consider that the higher value may have been intentionally set."
		$notesDopZero = "This is the default setting. Consider using the recommended value instead."
		$notesDopOne = "Some applications like SharePoint, Dynamics NAV, SAP, BizTalk has the need to use MAXDOP = 1. Please confirm that your instance is not supporting one of these applications prior to changing the MaxDop."
		$notesAsRecommended = "Configuration is as recommended."
		$collection = @()
	}
	
	process {
		$hasscopedconfiguration = $false
		
		foreach ($servername in $SqlInstance) {
			Write-Verbose "Attempting to connect to $servername."
			try {
				$server = Connect-SqlInstance -SqlInstance $servername -SqlCredential $SqlCredential
			}
			catch {
				Write-Warning "Can't connect to $servername or access denied. Skipping."
				continue
			}
			
			if ($server.versionMajor -lt 9) {
				Write-Warning "This function does not support versions lower than SQL Server 2005 (v9). Skipping server '$servername'."
				Continue
			}
			
			#Get current configured value
			$maxdop = $server.Configuration.MaxDegreeOfParallelism.ConfigValue
			
			try {
				#represents the Number of NUMA nodes 
				$sql = "SELECT COUNT(DISTINCT memory_node_id) AS NUMA_Nodes FROM sys.dm_os_memory_clerks WHERE memory_node_id!=64"
				$NUMAnodes = $server.ConnectionContext.ExecuteScalar($sql)
			}
			catch {
				$errormessage = $_.Exception.Message.ToString()
				Write-Warning "Failed to execute $sql.`n$errormessage."
				continue
			}
			
			try {
				#represents the Number of Processor Cores
				$sql = "SELECT COUNT(scheduler_id) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE'"
				$numberofcores = $server.ConnectionContext.ExecuteScalar($sql)
			}
			catch {
				$errormessage = $_.Exception.Message.ToString()
				Write-Warning "Failed to execute $sql.`n$errormessage."
				continue
			}
			
			#Calculate Recommended Max Dop to instance
			#Server with single NUMA node	
			if ($NUMAnodes -eq 1) {
				if ($numberofcores -lt 8) {
					#Less than 8 logical processors	- Keep MAXDOP at or below # of logical processors
					$recommendedMaxDop = $numberofcores
				}
				else {
					#Equal or greater than 8 logical processors - Keep MAXDOP at 8
					$recommendedMaxDop = 8
				}
			}
			else {
				#Server with multiple NUMA nodes
				if (($numberofcores / $NUMAnodes) -lt 8) {
					# Less than 8 logical processors per NUMA node - Keep MAXDOP at or below # of logical processors per NUMA node    
					$recommendedMaxDop = [int]($numberofcores / $NUMAnodes)
				}
				else {
					# Greater than 8 logical processors per NUMA node - Keep MAXDOP at 8
					$recommendedMaxDop = 8
				}
			}
			
			#Setting notes for instance max dop value
			$notes = $null
			if ($maxdop -eq 1) {
				$notes = $notesDopOne
			}
			else {
				if ($maxdop -ne 0 -and $maxdop -lt $recommendedMaxDop) {
					$notes = $notesDopLT
				}
				else {
					if ($maxdop -ne 0 -and $maxdop -gt $recommendedMaxDop) {
						$notes = $notesDopGT
					}
					else {
						if ($maxdop -eq 0) {
							$notes = $notesDopZero
						}
						else {
							$notes = $notesAsRecommended
						}
					}
				}
			}
			
			$collection += [pscustomobject]@{
				Instance              = $server.Name
				InstanceVersion       = $server.Version
				Database              = "N/A"
				DatabaseMaxDop        = "N/A"
				CurrentInstanceMaxDop = $maxdop
				RecommendedMaxDop     = $recommendedMaxDop
				NUMANodes             = $NUMAnodes
				NumberOfCores         = $numberofcores
				Notes                 = $notes
			}
			
			# On SQL Server 2016 and higher, MaxDop can be set on a per-database level
			if ($server.versionMajor -ge 13) {
				$hasscopedconfiguration = $true
				Write-Verbose "Server '$server' has an 2016 version, checking each database."
				
				foreach ($database in $server.Databases | Where-Object { $_.IsSystemObject -eq $false -and $_.IsAccessible -eq $true }) {
					Write-Verbose "Checking database '$($database.Name)'."
					
					$dbmaxdop = $database.MaxDop
					
					$collection += [pscustomobject]@{
						Instance              = $server.Name
						InstanceVersion       = $server.Version
						Database              = $database.Name
						DatabaseMaxDop        = $dbmaxdop
						CurrentInstanceMaxDop = $maxdop
						RecommendedMaxDop     = $recommendedMaxDop
						NUMANodes             = $NUMAnodes
						NumberOfCores         = $numberofcores
						Notes                 = if ($dbmaxdop -eq 0) {
							"Will use CurrentInstanceMaxDop value"
						}
						else {
							"$notes"
						}
					}
				}
			}
				
			$server.ConnectionContext.Disconnect()
			
		}
	}
	end {
		if ($Detailed) {
			if ($hasscopedconfiguration) {
				return ($collection | Select-Object Instance, InstanceVersion, Database, DatabaseMaxDop, CurrentInstanceMaxDop, RecommendedMaxDop, NUMANodes, NumberOfCores, Notes)
			}
			else {
				return ($collection | Select-Object Instance, CurrentInstanceMaxDop, RecommendedMaxDop, NUMANodes, NumberOfCores, Notes)
			}
		}
		else {
			if ($hasscopedconfiguration) {
				return ($collection | Select-Object Instance, InstanceVersion, Database, DatabaseMaxDop, CurrentInstanceMaxDop, RecommendedMaxDop, Notes)
			}
			else {
				return ($collection | Select-Object Instance, CurrentInstanceMaxDop, RecommendedMaxDop, Notes)
			}
		}
	}
}
