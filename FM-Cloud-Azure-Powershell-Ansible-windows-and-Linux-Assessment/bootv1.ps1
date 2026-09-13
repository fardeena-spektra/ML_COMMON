Param (
    [string]
    $DeploymentID,

    [string]
    $ODLID,

    [string]
    $azureUserName,

    [string]
    $trainerUserName,

    [string]
    $trainerUserPassword
)

# =====================================================================
# CloudLabs CSE bootstrap - Azure IaaS Fundamentals assessment
# Prepares the Windows JumpVM for a hands-on assessment against the
# candidate's REAL nested Azure subscription (no mocks). This script
# only preps the environment - it does NOT perform s1-s4 itself.
# The candidate authenticates with their own azureUserName/password
# (shown in the CloudLabs portal) and completes the tasks manually.
#
# Invoked by the ARM CustomScriptExtension:
#   powershell -ExecutionPolicy Unrestricted -File psscript-01.ps1 `
#     -DeploymentID <id> -ODLID <id> -azureUserName <user> `
#     -trainerUserName <user> -trainerUserPassword <pass>
# Idempotent-ish: safe to re-run (seed files are only written if absent).
# =====================================================================
Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

New-Item -ItemType Directory -Path C:\LabFiles -Force | Out-Null
New-Item -ItemType Directory -Path C:\LabFiles\ArmTemplates -Force | Out-Null

# ---------------------------------------------------------------------
# Write Ubuntu ARM template, parameter file, and deploy.sh directly to
# disk (no download - content is embedded in this script).
# ---------------------------------------------------------------------

try {
    Write-Host "Writing Ubuntu ARM template files..."

    $armTemplateContent = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "vmName": {
      "type": "string"
    },
    "adminUsername": {
      "type": "string",
      "defaultValue": "azureuser"
    },
    "adminPassword": {
      "type": "secureString"
    },
    "location": {
      "type": "string",
      "defaultValue": "[resourceGroup().location]"
    },
    "sshSourceAddressPrefix": {
      "type": "string",
      "defaultValue": "*",
      "metadata": {
        "description": "IP address/CIDR allowed to SSH in. Use your own public IP/CIDR instead of '*' where possible. Note: if JIT is enabled on this VM, Defender for Cloud manages/overrides this rule dynamically."
      }
    }
  },
  "variables": {
    "vnetName": "lab-vnet",
    "subnetName": "default",
    "nsgName": "lab-nsg",
    "nicName": "[concat(parameters('vmName'), '-nic')]",
    "pipName": "[concat(parameters('vmName'), '-pip')]",
    "osDiskName": "[concat(parameters('vmName'), '-osdisk')]",
    "ipConfigName": "ipconfig1",
    "cloudInit": "#cloud-config\npackage_update: true\npackages:\n  - openssh-server\nruncmd:\n  - systemctl enable ssh\n  - systemctl restart ssh\n  - systemctl enable ssh.socket || true\n"
  },
  "resources": [
    {
      "type": "Microsoft.Network/networkSecurityGroups",
      "apiVersion": "2023-09-01",
      "name": "[variables('nsgName')]",
      "location": "[parameters('location')]",
      "properties": {
        "securityRules": [
          {
            "name": "Allow-SSH",
            "properties": {
              "priority": 1000,
              "direction": "Inbound",
              "access": "Allow",
              "protocol": "Tcp",
              "sourcePortRange": "*",
              "destinationPortRange": "22",
              "sourceAddressPrefix": "[parameters('sshSourceAddressPrefix')]",
              "destinationAddressPrefix": "*"
            }
          }
        ]
      }
    },
    {
      "type": "Microsoft.Network/virtualNetworks",
      "apiVersion": "2023-09-01",
      "name": "[variables('vnetName')]",
      "location": "[parameters('location')]",
      "dependsOn": [
        "[resourceId('Microsoft.Network/networkSecurityGroups', variables('nsgName'))]"
      ],
      "properties": {
        "addressSpace": {
          "addressPrefixes": [
            "10.0.0.0/16"
          ]
        },
        "subnets": [
          {
            "name": "[variables('subnetName')]",
            "properties": {
              "addressPrefix": "10.0.0.0/24",
              "networkSecurityGroup": {
                "id": "[resourceId('Microsoft.Network/networkSecurityGroups', variables('nsgName'))]"
              }
            }
          }
        ]
      }
    },
    {
      "type": "Microsoft.Network/publicIPAddresses",
      "apiVersion": "2023-09-01",
      "name": "[variables('pipName')]",
      "location": "[parameters('location')]",
      "sku": {
        "name": "Standard"
      },
      "properties": {
        "publicIPAllocationMethod": "Static"
      }
    },
    {
      "type": "Microsoft.Network/networkInterfaces",
      "apiVersion": "2023-09-01",
      "name": "[variables('nicName')]",
      "location": "[parameters('location')]",
      "dependsOn": [
        "[resourceId('Microsoft.Network/virtualNetworks', variables('vnetName'))]",
        "[resourceId('Microsoft.Network/publicIPAddresses', variables('pipName'))]"
      ],
      "properties": {
        "ipConfigurations": [
          {
            "name": "[variables('ipConfigName')]",
            "properties": {
              "subnet": {
                "id": "[resourceId('Microsoft.Network/virtualNetworks/subnets', variables('vnetName'), variables('subnetName'))]"
              },
              "publicIPAddress": {
                "id": "[resourceId('Microsoft.Network/publicIPAddresses', variables('pipName'))]"
              }
            }
          }
        ]
      }
    },
    {
      "type": "Microsoft.Compute/virtualMachines",
      "apiVersion": "2023-07-01",
      "name": "[parameters('vmName')]",
      "location": "[parameters('location')]",
      "dependsOn": [
        "[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]"
      ],
      "properties": {
        "hardwareProfile": {
          "vmSize": "Standard_D2as_v5"
        },
        "storageProfile": {
          "imageReference": {
            "publisher": "Canonical",
            "offer": "0001-com-ubuntu-server-jammy",
            "sku": "22_04-lts-gen2",
            "version": "latest"
          },
          "osDisk": {
            "name": "[variables('osDiskName')]",
            "createOption": "FromImage",
            "managedDisk": {
              "storageAccountType": "Standard_LRS"
            }
          }
        },
        "osProfile": {
          "computerName": "[parameters('vmName')]",
          "adminUsername": "[parameters('adminUsername')]",
          "adminPassword": "[parameters('adminPassword')]",
          "customData": "[base64(variables('cloudInit'))]",
          "linuxConfiguration": {
            "disablePasswordAuthentication": false
          }
        },
        "networkProfile": {
          "networkInterfaces": [
            {
              "id": "[resourceId('Microsoft.Network/networkInterfaces', variables('nicName'))]"
            }
          ]
        }
      }
    }
  ]
}
'@

    $parametersTemplate = @'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "vmName": {
      "value": "ubuntuvm-{{DEPLOYMENT_ID}}"
    },
    "adminUsername": {
      "value": "azureadmin"
    },
    "adminPassword": {
      "value": "P@ssw0rd12345!"
    }
  }
}
'@
    $parametersContent = $parametersTemplate -replace '{{DEPLOYMENT_ID}}', $DeploymentID

    $deployScriptContent = @'
az deployment group create \
  --resource-group microland \
  --template-file ubuntuvm.json \
  --parameters ubuntuparameters.json
'@

    Set-Content -Path "C:\LabFiles\ArmTemplates\ubuntuvm.json" -Value $armTemplateContent -Encoding Ascii
    Set-Content -Path "C:\LabFiles\ArmTemplates\ubuntuparameters.json" -Value $parametersContent -Encoding Ascii
    Set-Content -Path "C:\LabFiles\ArmTemplates\deploy.sh" -Value $deployScriptContent -Encoding Ascii

    Write-Host "Ubuntu ARM template files written successfully."
}
catch {
    Write-Warning "Failed to write Ubuntu ARM template files."
    Write-Warning $_.Exception.Message
}
# Deliberately NOT writing azurePassword to disk - candidate gets it from
# the CloudLabs environment details pane, same place they got this VM's RDP creds.
@"
DeploymentID : $DeploymentID
ODLID        : $ODLID
AzureUserName: $azureUserName
TrainerUser  : $trainerUserName
"@ | Set-Content -Path C:\LabFiles\AzureCreds.txt

# ---------------------------------------------------------------------
# Tooling - Az PowerShell module, Azure CLI, OpenSSH client (for
# ssh-keygen / ssh so the candidate can generate keys and reach the
# Ubuntu VM they deploy).
# ---------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Az -Scope AllUsers -Force -AllowClobber
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    $cliInstaller = "$env:TEMP\AzureCLI.msi"
    Invoke-WebRequest -Uri "https://aka.ms/installazurecliwindows" -OutFile $cliInstaller
    Start-Process msiexec.exe -ArgumentList "/I `"$cliInstaller`" /quiet" -Wait
}

$sshCapability = Get-WindowsCapability -Online -Name "OpenSSH.Client*"
if ($sshCapability.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $sshCapability.Name | Out-Null
}

# ---------------------------------------------------------------------
# VS Code - silent install with desktop shortcut and context-menu
# integration, so the candidate has a working editor on first login.
# ---------------------------------------------------------------------
try {
    Write-Host "Installing Visual Studio Code..."
    $vsCodeInstaller = "$env:TEMP\VSCodeSetup.exe"
    Invoke-WebRequest -Uri "https://update.code.visualstudio.com/latest/win32-x64-user/stable" -OutFile $vsCodeInstaller
    Start-Process -FilePath $vsCodeInstaller -ArgumentList "/VERYSILENT /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,desktopicon" -Wait
    Write-Host "Visual Studio Code installed successfully."
}
catch {
    Write-Warning "Failed to install Visual Studio Code."
    Write-Warning $_.Exception.Message
}

# ---------------------------------------------------------------------
# Git Bash - silent install with desktop icon.
# ---------------------------------------------------------------------
try {
    Write-Host "Installing Git for Windows (Git Bash)..."
    $gitInstaller = "$env:TEMP\GitSetup.exe"
    Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/latest/download/Git-64-bit.exe" -OutFile $gitInstaller
    Start-Process -FilePath $gitInstaller -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP- /COMPONENTS=`"icons,icons\desktopicon,ext,ext\shellhere,assoc,assoc_sh`"" -Wait
    Write-Host "Git Bash installed successfully."
}
catch {
    Write-Warning "Failed to install Git Bash."
    Write-Warning $_.Exception.Message
}

# ---------------------------------------------------------------------
# Desktop shortcut - Azure Portal, so the candidate has a one-click
# way to open portal.azure.com from any browser installed on the VM.
# ---------------------------------------------------------------------
try {
    Write-Host "Creating Azure Portal desktop shortcut..."
    $desktopPath = [Environment]::GetFolderPath("CommonDesktopDirectory")
    $shortcutPath = Join-Path $desktopPath "Azure Portal.lnk"
    $wshShell = New-Object -ComObject WScript.Shell
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "$env:SystemRoot\System32\cmd.exe"
    $shortcut.Arguments = "/c start https://portal.azure.com"
    $shortcut.WindowStyle = 7
    $shortcut.IconLocation = "$env:SystemRoot\System32\SHELL32.dll,14"
    $shortcut.Description = "Open the Azure Portal"
    $shortcut.Save()
    Write-Host "Azure Portal desktop shortcut created successfully."
}
catch {
    Write-Warning "Failed to create Azure Portal desktop shortcut."
    Write-Warning $_.Exception.Message
}

# ---------------------------------------------------------------------
# SEED - broken ARM template for s1/s2. Faults, left for the candidate
# to find:
#   1) The VM's imageReference.sku is an invalid/deprecated Ubuntu SKU
#      name, so `New-AzResourceGroupDeployment` / `az deployment group
#      create` will fail validation. Fix it to a current, valid SKU.
#   2) The NSG's "Allow-SSH" rule has sourceAddressPrefix "*" (open to
#      the internet), and the VM uses adminPassword instead of an SSH
#      key. Restrict the NSG rule to the candidate's own public IP and
#      switch the VM to SSH-key-only auth (disablePasswordAuthentication).
# There is no seeded web server extension - that is task s3, done
# manually after SSH access works.
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
# Candidate instructions.
# ---------------------------------------------------------------------
@'
Azure IaaS Fundamentals assessment - candidate instructions
=============================================================

Environment: this JumpVM has Az PowerShell, Azure CLI, the OpenSSH
client, Visual Studio Code, and Git Bash installed, along with a
desktop shortcut to the Azure Portal. Your Azure login (username shown
in C:\LabFiles\AzureCreds.txt, password from the lab portal) gives you
a real nested Azure subscription to work in. Nothing here is
simulated - every task below is graded against actual Azure resources.

Resource group naming (required for grading):
  rg-iaas-assessment-<DeploymentID>
  (see C:\LabFiles\AzureCreds.txt for your DeploymentID)

Starter files: C:\LabFiles\ArmTemplates\azuredeploy.json and
azuredeploy.parameters.json. This template does not deploy as-is.

--------------------------------------------------------------------
s1 - Deploy infrastructure using the ARM template
--------------------------------------------------------------------
Authenticate (Connect-AzAccount or az login), create the resource
group above, then deploy azuredeploy.json into it. The first attempt
will fail - read the error, it tells you exactly which property is
wrong. Fix the template and redeploy until it succeeds.

--------------------------------------------------------------------
s2 - Secure SSH access
--------------------------------------------------------------------
Once you can deploy, look closely at the NSG rule for port 22 and the
VM's auth configuration in the template - neither is ready for a real
environment. Restrict SSH to your own public IP only (find it, e.g.
Invoke-RestMethod https://api.ipify.org) and switch the VM to SSH
public-key authentication only. Generate a key pair with ssh-keygen if
you don't have one on this JumpVM yet.

--------------------------------------------------------------------
s3 - Deploy Ubuntu VM and configure as web server
--------------------------------------------------------------------
The template deploys a plain Ubuntu VM with no web server. Once SSH
access works, connect and install/configure a web server (nginx or
apache2) so that http://<public-ip> returns a working page. You can do
this by hand over SSH, or by adding your own CustomScript extension
resource to the template - either is acceptable.

--------------------------------------------------------------------
s4 - Automate Azure VM start/stop
--------------------------------------------------------------------
No starter code for this one. Build a way to automatically start the
VM on weekday mornings and stop (deallocate) it on weekday evenings -
an Az Automation runbook with a schedule, or a script registered with
Task Scheduler/cron, are both acceptable. Document which approach you
used and why in C:\LabFiles\s4-notes.txt.

--------------------------------------------------------------------
When finished
--------------------------------------------------------------------
Leave all resources deployed under rg-iaas-assessment-<DeploymentID>
for grading. Do not delete the resource group at the end of the
assessment.
'@ | Set-Content -Path "C:\LabFiles\Instructions.txt" -Encoding Ascii

Stop-Transcript
