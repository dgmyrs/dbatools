function Get-DbaDependency
{
    <#
        .SYNOPSIS
            Finds object dependencies and their relevant creation scripts.
        
        .DESCRIPTION
            This function recursively finds all objects that depends on the input.
            It will then retrieve rich information from them, including their creation scripts and the order in which it should be applied.
            
            By using the 'Parents' switch, the function will instead retrieve all items that the input depends on (including their creation scripts).
            
            For more details on dependency, see:
            https://technet.microsoft.com/en-us/library/ms345449(v=sql.105).aspx
        
        .PARAMETER InputObject
            The SMO object to parse
        
        .PARAMETER AllowSystemObjects
            Normally, system objects are ignored by this function as dependencies.
            This switch overrides that behavior.
        
        .PARAMETER Parents
            Causes the function to retrieve all objects that the input depends on, rather than retrieving everything that depends on the input.
        
        .PARAMETER IncludeSelf
            Includes the object whose dependencies are retrieves itself.
            Useful when exporting an entire logic structure in order to recreate it in another database.
        
        .PARAMETER EnableException
            By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
            This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
            Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.
            
        .PARAMETER IncludeScript
            Setting this switch will cause the function to also retrieve the creation script of the dependency.
        
        .EXAMPLE
            $table = (Get-DbaDatabase -SqlInstance sql2012 Northwind).tables | Where Name -eq Customers
            $table | Get-DbaDependency
            
            Returns everything that depends on the "Customers" table
        
        .LINK
            https://dbatools.io/Get-DbaDependency
    #>
    [CmdletBinding()]
    Param (
        [Parameter(ValueFromPipeline = $true)]
        $InputObject,
        
        [switch]
        $AllowSystemObjects,
        
        [switch]
        $Parents,
        
        [switch]
        $IncludeSelf,
        
        [switch]
        [Alias('Silent')]$EnableException
    )
    
    Begin
    {
        #region Utility functions
        function Get-DependencyTree
        {
            [CmdletBinding()]
            Param (
                $Object,
                
                $Server,
                
                [bool]
                $AllowSystemObjects,
                
                [bool]
                $EnumParents,
                
                [string]
                $FunctionName,
                
                [bool]
                $EnableException
            )
            
            $scripter = New-Object Microsoft.SqlServer.Management.Smo.Scripter
            $options = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
            $options.DriAll = $true
            $options.AllowSystemObjects = $AllowSystemObjects
            $options.WithDependencies = $true
            $scripter.Options = $options
            $scripter.Server = $Server
            
            $urnCollection = New-Object Microsoft.SqlServer.Management.Smo.UrnCollection
            
            Write-Message -EnableException $EnableException -Level 5 -Message "Adding $Object which is a $($Object.urn.Type)" -FunctionName $FunctionName
            $urnCollection.Add([Microsoft.SqlServer.Management.Sdk.Sfc.Urn]$Object.urn)
            
            #now we set up an event listnenr go get progress reports
            $progressReportEventHandler = [Microsoft.SqlServer.Management.Smo.ProgressReportEventHandler] {
                $name = $_.Current.GetAttribute('Name');
                Write-Message -EnableException $EnableException -Level 5 -Message "Analysed $name" -FunctionName $FunctionName
            }
            $scripter.add_DiscoveryProgress($progressReportEventHandler)
            
            return $scripter.DiscoverDependencies($urnCollection, $EnumParents)
        }
        
        function Read-DependencyTree
        {
            [CmdletBinding()]
            Param (
                [System.Object]
                $InputObject,
                
                [int]
                $Tier,
                
                [System.Object]
                $Parent,
                
                [bool]
                $EnumParents
            )
            
            Add-Member -Force -InputObject $InputObject -Name Parent -Value $Parent -MemberType NoteProperty
            if ($EnumParents) { Add-Member -Force -InputObject $InputObject -Name Tier -Value ($Tier * -1) -MemberType NoteProperty -PassThru }
            else { Add-Member -Force -InputObject $InputObject -Name Tier -Value $Tier -MemberType NoteProperty -PassThru }
            
            if ($InputObject.HasChildNodes) { Read-DependencyTree -InputObject $InputObject.FirstChild -Tier ($Tier + 1) -Parent $InputObject -EnumParents $EnumParents }
            if ($InputObject.NextSibling) { Read-DependencyTree -InputObject $InputObject.NextSibling -Tier $Tier -Parent $Parent -EnumParents $EnumParents }
        }
        
        function Get-DependencyTreeNodeDetail
        {
            [CmdletBinding()]
            Param (
                [Parameter(ValueFromPipeline = $true)]
                $SmoObject,
                
                $Server,
                
                $OriginalResource,
                
                [bool]
                $AllowSystemObjects
            )
            
            Begin
            {
                $scripter = New-Object Microsoft.SqlServer.Management.Smo.Scripter
                $options = New-Object Microsoft.SqlServer.Management.Smo.ScriptingOptions
                $options.DriAll = $true
                $options.AllowSystemObjects = $AllowSystemObjects
                $options.WithDependencies = $true
                $scripter.Options = $options
                $scripter.Server = $Server
            }
            
            process
            {
                foreach ($Item in $SmoObject)
                {
                    $richobject = $Server.GetSmoObject($Item.urn)
                    $parent = $Server.GetSmoObject($Item.Parent.Urn)
                    
                    $NewObject = New-Object Sqlcollaborative.Dbatools.Database.Dependency
                    $NewObject.ComputerName = $server.NetName
                    $NewObject.ServiceName = $server.ServiceName
                    $NewObject.SqlInstance = $server.DomainInstanceName
                    $NewObject.Dependent = $richobject.Name
                    $NewObject.Type = $Item.Urn.Type
                    $NewObject.Owner = $richobject.Owner
                    $NewObject.IsSchemaBound = $Item.IsSchemaBound
                    $NewObject.Parent = $parent.Name
                    $NewObject.ParentType = $parent.Urn.Type
                    $NewObject.Tier = $Item.Tier
                    $NewObject.Object = $richobject
                    $NewObject.Urn = $richobject.Urn
                    $NewObject.OriginalResource = $OriginalResource
                    
                    $SQLscript = $scripter.EnumScriptWithList($richobject)
                    
                    # I can't remember how to remove these options and their syntax is breaking stuff
                    $SQLscript = $SQLscript -replace "SET ANSI_NULLS ON", ""
                    $SQLscript = $SQLscript -replace "SET QUOTED_IDENTIFIER ON", ""
                    $NewObject.Script = "$SQLscript `r`ngo"
                    
                    $NewObject
                }
            }
        }
        
        function Select-DependencyPrecedence
        {
            [CmdletBinding()]
            Param (
                [Parameter(ValueFromPipeline = $true)]
                $Dependency
            )
            
            Begin
            {
                $list = @()
            }
            Process
            {
                foreach ($dep in $Dependency)
                {
                    # Killing the pipeline is generally a bad idea, but since we have to group and sort things, we have not really a choice
                    $list += $dep
                }
            }
            End
            {
                $list | Group-Object -Property Object | ForEach-Object { $_.Group | Sort-Object -Property Tier -Descending | Select-Object -First 1 } | Sort-Object Tier
            }
        }
        #endregion Utility functions
    }
    Process
    {
        foreach ($Item in $InputObject)
        {
            Write-Message -EnableException $EnableException -Level 5 -Message "Processing: $Item"
            if ($null -eq $Item.urn)
            {
                Stop-Function -Message "$Item is not a valid SMO object" -EnableException $EnableException -Category InvalidData -Continue -Target $Item
            }
            
            # Find the server object to pass on to the function
            $parent = $Item.parent
            
            do { $parent = $parent.parent }
            until (($parent.urn.type -eq "Server") -or (-not $parent))
            
            if (-not $parent)
            {
                Stop-Function -Message "Failed to find valid server object in input: $Item" -EnableException $EnableException -Category InvalidData -Continue -Target $Item
            }
            
            $server = $parent
            
            $tree = Get-DependencyTree -Object $Item -AllowSystemObjects $false -Server $server -FunctionName (Get-PSCallStack)[0].COmmand -EnableException $EnableException -EnumParents $Parents
            $limitCount = 2
            if ($IncludeSelf) { $limitCount = 1 }
            if ($tree.Count -lt $limitCount)
            {
                Write-Message -Message "No dependencies detected for $($Item)" -Level 2 -EnableException $EnableException
                continue
            }
            
            if ($IncludeSelf) { $resolved = Read-DependencyTree -InputObject $tree.FirstChild -Tier 0 -Parent $tree.FirstChild -EnumParents $Parents }
            else { $resolved = Read-DependencyTree -InputObject $tree.FirstChild.FirstChild -Tier 1 -Parent $tree.FirstChild -EnumParents $Parents }
            $resolved | Get-DependencyTreeNodeDetail -Server $server -OriginalResource $Item -AllowSystemObjects $AllowSystemObjects | Select-DependencyPrecedence
        }
    }
}
