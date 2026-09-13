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
#   powershell -ExecutionPolicy Unrestricted -File bootv1.ps1 `
#     -DeploymentID <id> -ODLID <id> -azureUserName <user> `
#     -trainerUserName <user> -trainerUserPassword <pass>
# Idempotent-ish: safe to re-run (seed files are only written if absent).
#
# NOTE: requires cloudlabs-windows-functions.ps1 to be present in the
# same working directory - add it as a second fileUri on the
# CustomScriptExtension resource in the ARM template alongside this
# script, e.g.:
#   "fileUris": [
#     "[variables('scripturl')]",
#     "https://experienceazure.blob.core.windows.net/templates/cloudlabs-common/cloudlabs-windows-functions.ps1"
#   ]
# =====================================================================
Start-Transcript -Path C:\WindowsAzure\Logs\CloudLabsCustomScriptExtension.txt -Append
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"

New-Item -ItemType Directory -Path C:\LabFiles -Force | Out-Null
New-Item -ItemType Directory -Path C:\LabFiles\ArmTemplates -Force | Out-Null

# ---------------------------------------------------------------------
# Import the shared CloudLabs function library. CSE preserves each
# fileUri's source path structure under the working directory, so the
# library may land flat (.\cloudlabs-windows-functions.ps1) or nested
# (.\cloudlabs-common\cloudlabs-windows-functions.ps1) depending on the
# blob URL shape - search recursively instead of assuming a flat path.
# ---------------------------------------------------------------------
$commonScriptFile = Get-ChildItem -Path (Get-Location) -Filter "cloudlabs-windows-functions.ps1" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($commonScriptFile) {
    . $commonScriptFile.FullName
    Write-Host "Loaded cloudlabs-windows-functions.ps1 from $($commonScriptFile.FullName)."
} else {
    Write-Warning "cloudlabs-windows-functions.ps1 not found anywhere under the working directory - tooling install steps will be skipped. Add it as a second fileUri on the CustomScriptExtension resource."
}

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
      "defaultValue": "azureadmin"
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

    $deployScriptContent = @"
az deployment group create \
  --resource-group microland-$DeploymentID \
  --template-file ubuntuvm.json \
  --parameters ubuntuparameters.json
"@

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
try {
    @"
DeploymentID : $DeploymentID
ODLID        : $ODLID
AzureUserName: $azureUserName
TrainerUser  : $trainerUserName
"@ | Set-Content -Path C:\LabFiles\AzureCreds.txt -ErrorAction Stop
    Write-Host "AzureCreds.txt written successfully."
}
catch {
    Write-Warning "Failed to write AzureCreds.txt."
    Write-Warning $_.Exception.Message
}

# ---------------------------------------------------------------------
# Tooling - installed via the shared, tested cloudlabs-common functions
# (Chocolatey with winget fallback, retries, OS-aware logic) rather
# than ad-hoc installers, matching the pattern used across other
# CloudLabs bootstrap scripts.
#
#   WindowsServerCommon  - disables IE ESC, installs Chocolatey,
#                          disables the Windows Firewall, installs
#                          Edge Chromium AND creates the "Azure Portal"
#                          desktop shortcut (portal.azure.com) as part
#                          of its normal behavior.
#   InstallVSCode        - VS Code via Chocolatey (winget fallback).
#   InstallGitTools       - Git for Windows (Git Bash) via Chocolatey
#                          (winget fallback); installer includes the
#                          desktop icon and "Git Bash Here" shell
#                          integration by default.
#   InstallAzCLI          - Azure CLI via Chocolatey (winget fallback).
#   InstallAzPowerShellModule - Az PowerShell module from PSGallery.
# ---------------------------------------------------------------------
if (Get-Command WindowsServerCommon -ErrorAction SilentlyContinue) {
    try {
        Write-Host "Running WindowsServerCommon (Chocolatey, firewall, Edge + Azure Portal shortcut)..."
        WindowsServerCommon
        Write-Host "WindowsServerCommon completed."
    } catch {
        Write-Warning "WindowsServerCommon failed: $($_.Exception.Message)"
    }

    try {
        Write-Host "Installing Visual Studio Code..."
        InstallVSCode
        Write-Host "InstallVSCode completed."
    } catch {
        Write-Warning "InstallVSCode failed: $($_.Exception.Message)"
    }

    try {
        Write-Host "Installing Git Bash..."
        InstallGitTools
        Write-Host "InstallGitTools completed."
    } catch {
        Write-Warning "InstallGitTools failed: $($_.Exception.Message)"
    }

    try {
        Write-Host "Installing Azure CLI..."
        InstallAzCLI
        Write-Host "InstallAzCLI completed."
    } catch {
        Write-Warning "InstallAzCLI failed: $($_.Exception.Message)"
    }

    try {
        Write-Host "Installing Az PowerShell module..."
        InstallAzPowerShellModule
        Write-Host "InstallAzPowerShellModule completed."
    } catch {
        Write-Warning "InstallAzPowerShellModule failed: $($_.Exception.Message)"
    }

    if (Get-Command Get-ChocoInstallReport -ErrorAction SilentlyContinue) {
        try { Get-ChocoInstallReport | Out-Null } catch { Write-Warning "Get-ChocoInstallReport failed: $($_.Exception.Message)" }
    }
} else {
    Write-Warning "Shared function library not loaded - skipping VS Code / Git Bash / Azure CLI / Az PowerShell / Azure Portal shortcut install."
}

# OpenSSH client - not covered by the shared library, install directly if missing.
try {
    $sshCapability = Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction Stop
    if ($sshCapability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $sshCapability.Name -ErrorAction Stop | Out-Null
        Write-Host "OpenSSH client installed."
    } else {
        Write-Host "OpenSSH client already installed."
    }
} catch {
    Write-Warning "OpenSSH client install failed: $($_.Exception.Message)"
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
'@ | Out-String | ForEach-Object {
    try {
        Set-Content -Path "C:\LabFiles\Instructions.txt" -Value $_ -Encoding Ascii -ErrorAction Stop
        Write-Host "Instructions.txt written successfully."
    } catch {
        Write-Warning "Failed to write Instructions.txt: $($_.Exception.Message)"
    }
}

Write-Host "Bootstrap script reached the end."
Stop-Transcript
