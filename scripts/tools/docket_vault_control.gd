extends RefCounted
class_name DocketVaultControl
## Public controls for one open project's process-memory vault session.


func get_definition() -> Dictionary:
	return {
		"name":"docket_vault_control",
		"description":"Read a project's vault status, or initialize, unlock or lock its session with a caller-supplied password. Read status first: mutations require its open_generation and fingerprint. Passwords are never saved; hints stay in the project file. Managed openings do not use a saved Preferences password until they close.",
		"inputSchema":{
			"type":"object", "additionalProperties":false,
			"properties":{
				"action":{"type":"string", "enum":["status", "init", "unlock", "lock"]},
				"project":{"type":"string", "description":"Open project selector; defaults to primary."},
				"open_generation":{"type":"string", "description":"Required for mutations; returned by status."},
				"fingerprint":{"type":"string", "description":"Required for mutations; returned by status."},
				"password":{"type":"string", "description":"Required for init and unlock; used only in memory."},
				"hint":{"type":"string", "description":"Optional portable hint for init."},
			},
			"required":["action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	return VaultKeySession.control(args, db)
