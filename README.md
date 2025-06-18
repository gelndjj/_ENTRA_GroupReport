# 🔎 EntraID Groups Report Generator

This PowerShell script generates a complete CSV report of all Microsoft Entra ID groups, enriched with key metadata useful for audits, governance, and access reviews.

---

## 📋 Features

- ✅ **Lists all Entra ID groups** (Security and Microsoft 365)
- ✅ **Detects Teams-based M365 Groups**
- ✅ Counts group **members**
- ✅ Retrieves group **owners**
- ✅ Shows **membership type** (Static/Dynamic) and rules
- ✅ Lists **Conditional Access (CA) policies** referencing the group
- ✅ Lists **Azure AD roles** assigned to the group
- ✅ Detects **app role assignments** (Service Principal references)
- ✅ Detects **Nested Groups**

---

## 🧪 Requirements

- PowerShell 5.1+ or Core
- Microsoft Graph PowerShell SDK (`Microsoft.Graph` module)

Install the SDK (if needed):

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force
```
---

## 🔐 Required Permissions
The script connects to Microsoft Graph with the following scopes:
```
Group.Read.All
GroupMember.Read.All
Team.ReadBasic.All
Policy.Read.All
Application.Read.All
```
When prompted, log in with an account that has sufficient rights to enumerate groups, owners, conditional access policies, and service principals.

---

## 🚀 How to Run
```
.\EntraID_Groups_Report.ps1
```
Once completed, a CSV file will be generated in the script's folder with a timestamp, for example:
```
EntraID_Groups_Report_20250618_1042.csv
```
---

## 📊 Sample Output Columns

| 📛 Group Identity | 👥 Membership & Ownership | 🔐 Security & Role Assignments  | 🌐 Integration & Provisioning |
| ----------------- | ------------------------- | ------------------------------- | ----------------------------- |
| Object ID         | Total Members             | Assigned Roles                  | Referenced in App Roles       |
| Display Name      | Assigned Owners           | Referenced In CA Policy Include | Is Teams Team                 |
| Group Type        | Membership Type           | Referenced In CA Policy Exclude | Created On                    |
| Group Email       | Dynamic Rule              |                                 | ResourceProvisioningOptions   |
| Mail Enabled      |                           |                                 | Visibility                    |
| Description       |                           |                                 | Nested Groups                 |

---

## 📌 Notes
The script does not yet include Access Package integration (planned).

Teams detection is performed using resourceProvisioningOptions.

Batched Graph API calls are used for performance when retrieving members and owners.

## 📄 License
MIT License
