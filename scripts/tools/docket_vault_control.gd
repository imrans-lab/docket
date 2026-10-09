extends RefCounted
class_name DocketVaultControl
## Public controls for one open project's process-memory vault session.


func get_definition() -> Dictionary:
	return {
		"name":"docket_vault_control",
		"description":"Read a project's vault status (including managed), initialize/unlock/lock its session, change its password or edit its portable hint. Read status first: mutations require its open_generation and fingerprint. Passwords are never saved. Managed openings do not use a saved Preferences password until they close.",
		"inputSchema":{
			"type":"object", "additionalProperties":false,
			"properties":{
				"action":{"type":"string", "enum":["status", "init", "unlock", "lock", "change_password", "set_hint"]},
				"project":{"type":"string", "description":"Open project selector; defaults to primary."},
				"open_generation":{"type":"string", "description":"Required for mutations; returned by status."},
				"fingerprint":{"type":"string", "description":"Required for mutations; returned by status."},
				"password":{"type":"string", "description":"Required for init and unlock; used only in memory."},
				"old":{"type":"string", "description":"Current password, required for change_password."},
				"new":{"type":"string", "description":"Replacement password, required for change_password."},
				"hint":{"type":"string", "description":"Portable hint: optional for init/change_password, required for set_hint."},
			},
			"required":["action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	return VaultKeySession.control(args, db)
