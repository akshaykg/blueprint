<#
# Discription: To run this shell it needs policy definition, parameters and parameter values for assignment in folder containing this ps script,
#              before running the script modify the scope json under AssignmentParameters folder to provide correct resource group and subscription ID.
# Warning: Do not run the same script multiple times without removing the residual policies from the portal or else this will result in multiple assignments.
#>
$ErrorActionPreference = 'stop'

Start-Transcript -Path ./bploging.log -Append

# Az.Blueprint moduel will not come in bundle with Az module need to explicitely install. if script fails in below line run "Install-Module Az.Blueprint" in powershell admin tab and run this again
Import-Module Az.Blueprint -ErrorAction Stop


# reading scope for the policy initilization
$scopeReference = Get-Content '.\scope.json' | ConvertFrom-Json


#set app zip url

$scappzipurl = $scopeReference.scappzipurl.value
$scsqlzipurl = $scopeReference.scsqlzipurl.value


#login to azure (if runing automaticaly from pipe add login code below)
#Login-AzAccount


#swtiching to Subscription ID to assign policy
$SubscriptionID = $scopeReference.subscriptionid.value
Select-AzSubscription -Subscriptionid $SubscriptionID

###################################################################################################
##      Creating the storage account to hold UI defination zip on subscription level             ##
###################################################################################################
#this will be triggered only if  the scappzipurl is null and this will not 

if(!$scappzipurl){
$scrgname = 'test1'+(Get-Date -Format ddmmyyyyhhss)
$scsaname='test'+(Get-Date -Format ddmmyyyyhhss)
$scsalocation="centralus"
$scsakind="StorageV2"
$scsacontainername="appcontainer"
$scappzip='.\scstorage.zip'
$sciaaszip = '.\sciaassql.zip'
New-AzResourceGroup -Name $scrgname -Location $scsalocation
Start-Sleep -Seconds 10
$storageAccount = New-AzStorageAccount -ResourceGroupName $scrgname -Name $scsaname -Location $scsalocation -SkuName Standard_LRS -Kind $scsakind 
Start-Sleep -Seconds 10
$ctx = $storageAccount.Context
New-AzStorageContainer -Name $scsacontainername -Context $ctx -Permission blob
Write-Warning "do not use this blob container to write somthing else as this has public read access to general internet"
Set-AzStorageBlobContent -File $scappzip -Container $scsacontainername -Blob "app.zip" -Context $ctx
$scappblob = Get-AzStorageBlob -Container $scsacontainername -Blob app.zip -Context $ctx
$scappzipurl = $scappblob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri
Set-AzStorageBlobContent -File $sciaaszip -Container $scsacontainername -Blob "iaassql.zip" -Context $ctx
$scsqlblob = Get-AzStorageBlob -Container $scsacontainername -Blob iaassql.zip -Context $ctx
$scsqlzipurl = $scsqlblob.ICloudBlob.StorageUri.PrimaryUri.AbsoluteUri
Write-Warning "this url need to be available all the time if not blueprint can not maintain the scope state"
}

###################################################################################################
##                           Creating the policies on subscription level                         ##
###################################################################################################

# Creating the Policy Definition (Subscription scope) for Multy tags
$tagDefinition = New-AzPolicyDefinition -Name 'gov-pol-enf-tags' -DisplayName 'gov-pol-enf-tags' -description 'Enforces a required tags on VMs.' -Policy '.\gov-pol-enf-tags\policy.json' -Parameter '.\gov-pol-enf-tags\policy-rules.json' -Mode All 

# Creating the Policy Definition (Subscription scope) for deny NSG all inbound rules
$nsgDefinition = New-AzPolicyDefinition -Name 'gov-pol-vnet-outbound' -DisplayName 'gov-pol-vnet-outbound' -description 'Enforce disallow of all traffic on NSGs.' -Policy '.\gov-pol-vnet-outbound\policy.json' -Parameter '.\gov-pol-vnet-outbound\policy-rules.json' -Mode All

# Creating the Policy Definition (Subscription scope) for image set
$imageDefinition = New-AzPolicyDefinition -Name 'gov-pol-vm-img' -DisplayName 'gov-pol-vm-img' -description 'Aduit if Vm is created without the suggested images.' -Policy '.\gov-pol-vm-img\policy.json' -Parameter '.\gov-pol-vm-img\policy-rules.json' -Mode All

###################################################################################################
##                  Defining and Creating the Initative on subscription level                    ##
###################################################################################################

# Defining the initivative definationabove set of policies for the 
 $setDefinationJSON = '[
    {
      "policyDefinitionId": "'+$tagDefinition.PolicyDefinitionId +'",
      "parameters": '+ (Get-Content .\gov-pol-enf-tags\policy-parameters.json)+'
    },
    {
      "policyDefinitionId": "'+$nsgDefinition.PolicyDefinitionId +'"
    },
    {
      "policyDefinitionId": "'+$imageDefinition.PolicyDefinitionId +'",
      "parameters": '+ (Get-Content .\gov-pol-vm-img\policy-parameters.json ) +'
    }
   ] '

# printing definition for loging perpuse
Write-Output $tagDefinition
Write-Output $nsgDefinition
Write-Output $imageDefinition
Write-Output $setDefinationJSON

# creating the PolicySet/Initivative defination for set of policies
$policySetDefination = New-AzPolicySetDefinition -Name $scopeReference.policygroupname.value -PolicyDefinition $setDefinationJSON 

# policy defination will take few seconds to initilize 
Start-Sleep -Seconds 10

###################################################################################################
##                          Creating the Blueprint on subscription level                         ##
###################################################################################################


# To Publish the blueprint one needs to have access on the management group or subscription (Scope is mentioned on JSON)
$bluePrint = New-AzBlueprint -Name $scopeReference.bpname.value  -BlueprintFile '.\Blueprint.json'

#creating the dynamic policy initative artifact file for blue print
$artifactFile = '{
  "kind": "policyAssignment",
  "properties": {
    "displayName": "tag-image-nsg-gov-initative",
    "dependsOn": [],
    "policyDefinitionId": "'+$policySetDefination.PolicySetDefinitionId +'",
    "parameters": {}
  }
}'

#temperuary file to save artiface json
$tempFile = New-TemporaryFile

#writing to temp file as New-AzBlueprintArtifact expects artifactfile as path variable 
$artifactFile | Out-File  $tempFile.FullName


#adding the initative as the artifact to the blueprint
New-AzBlueprintArtifact -Name $scopeReference.bpartifactassignmentname.value -Blueprint $blueprint -ArtifactFile $tempFile.FullName


#removing the temperuary file
Remove-Item -Path $tempFile.FullName -Force



#adding the second artifact (sc storage app) file for resource group and service catalog deployment
New-AzBlueprintArtifact -Name $scopeReference.storageservicecatalogname.value -Blueprint $bluePrint -ArtifactFile '.\gov-pol-servicecatalog-artifact\storageServiceCatalog.json'


#adding the third artifact (sc iaas sql app) file for resource group and service catalog deployment
New-AzBlueprintArtifact -Name $scopeReference.sqlservicecatalogname.value -Blueprint $bluePrint -ArtifactFile '.\gov-pol-servicecatalog-artifact\iaasSqlServiceCatalog.json'



###################################################################################################
##                        Publishing the Blueprint on subscription level                         ##
###################################################################################################

#publish the blue print and prep for assignment
$publishBluePrint = Publish-AzBlueprint -Blueprint $blueprint -Version $scopeReference.bpversion.value

# Blue print publish  will take few seconds to initilize 
Start-Sleep -Seconds 10

$publishedBluePrint = Get-AzBlueprint -Name $scopeReference.bpname.value 
Write-Output $publishedBluePrint.Id

###################################################################################################
##                          Assigning the Blueprint on subscription level                        ##
###################################################################################################


#https://github.com/Azure/azure-managedapp-samples/blob/master/Managed%20Application%20Sample%20Packages/201-managed-storage-account/managedstorage.zip?raw=true

#creating the assignment file json based on published blueprint
# $publishedBluePrint.Id 
$bpAssignmentFile = Get-Content '.\BluePrintAssignment.json'

# if below group do not exists the script will fail
$storageGroupID=(Get-AzADGroup -DisplayName $scopeReference.storagescgroupname.value).Id
$StorageRoleID=(Get-AzRoleDefinition -Name $scopeReference.storagescrole.value).Id

$sqlGroupID=(Get-AzADGroup -DisplayName $scopeReference.sqlscgroupname.value).Id
$SqlRoleID=(Get-AzRoleDefinition -Name $scopeReference.sqlscrole.value).Id

#dynamicaly editing the JSON to include to include the session related variables to assign the blueprint
#donot modify the BluePrintAssignment.json
#blueprintID
$bpAssignmentFile = $bpAssignmentFile.Replace('<<bp-id>>',$publishedBluePrint.Id)
#storage catalog variables
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-name>>',$scopeReference.storageservicecatalogname.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-storage-rg>>',$scopeReference.storagescrgname.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-storage-location>>',$scopeReference.storagescrglocation.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-location>>',$scopeReference.storagesclocation.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-locklevel>>',$scopeReference.storagesclocklevel.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-auth>>','{"principalId": "'+$storageGroupID+'", "roleDefinitionId": "'+$StorageRoleID+'"}')
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-description>>',$scopeReference.storagescdescription.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-displayName>>',$scopeReference.storagescdisplayname.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-uri>>',$scappzipurl)
#sql catalog variables
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-rg>>',$scopeReference.sqlscrgname.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sqlrg-location>>',$scopeReference.sqlscrglocation.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-name>>',$scopeReference.sqlservicecatalogname.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-location>>',$scopeReference.sqlsclocation.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-locklevel>>',$scopeReference.sqlsclocklevel.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-auth>>','{"principalId": "'+$sqlGroupID+'", "roleDefinitionId": "'+$SqlRoleID+'"}')
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-description>>',$scopeReference.sqlscdescription.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-displayName>>',$scopeReference.sqlscdisplayname.value)
$bpAssignmentFile = $bpAssignmentFile.Replace('<<sc-sql-uri>>',$scsqlzipurl)
#management ID lication
$bpAssignmentFile = $bpAssignmentFile.Replace('<<managedid-location>>',$scopeReference.blueprintmanagedidlocation.value)




#temperuary file to save assignment file json
$tempFileBpAssignment = New-TemporaryFile


#writing to temp file as New-AzBlueprintAssignment expects AssignmentFile as path variable 
$bpAssignmentFile| Out-File  $tempFileBpAssignment.FullName

#assigning the blueprint to subscription
New-AzBlueprintAssignment -Blueprint $blueprint -Name $scopeReference.bpassignmentname.value -AssignmentFile $tempFileBpAssignment.FullName


#removing the temperuary file
Remove-Item -path $tempFileBpAssignment.FullName -Force



# Creation of service catalog - storage account V2

Stop-Transcript

###################################################################################################
##                                         script end                                            ##
###################################################################################################


#write-output $SubscriptionID
# Assigning the initative or policySet to the perticular scope mentioned.
#$assignment = New-AzPolicyAssignment -Name "initiative-assignment" -PolicySetDefinition $policySetDefination -Scope $SubscriptionID
#write-output $assignment





####Note#####
#Get-AzLocation
#Get-AzVMImagePublisher
#(Get-AzVMImage -Location southindia -PublisherName MicrosoftWindowsServer -Skus 2016-Datacenter -Offer WindowsServer).Id
#login-azaccount
#Get-AzVMImageOffer -Location westus -PublisherName MicrosoftWindowsServer | select *
#
#Get-AzVMImageOffer -Location westus -PublisherName redhat | select *



