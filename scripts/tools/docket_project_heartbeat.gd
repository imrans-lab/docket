extends RefCounted
class_name DocketProjectHeartbeat
## Renews the owner lease that keeps memory projects in memory. Only a client
## that declares client_class=owner renews it; the declaration is trusted, not
## authenticated. Any other client gets the lease status and no renewal.


func get_definition() -> Dictionary:
	return {
		"name": "docket_project_heartbeat",
		"description": "Renew the owner lease for memory projects. Owner-class clients (docket.app GUI, Minerva) call this periodically with client_class=owner; while no owner holds the lease, memory projects with outstanding items are spilled to session files. Other clients get the lease status only.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"client": {"type": "string", "description": "Name of the calling client, shown as the lease holder"},
				"client_class": {"type": "string", "enum": ["owner", "tool"], "description": "Declared class; only owner renews"},
				"lease_seconds": {"type": "integer", "description": "Lease length before the next heartbeat is due (default 120, max 3600)"},
			},
			"required": ["client", "client_class"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _db: DocketDB, _project_dbs: Dictionary, _add_fn: Callable = Callable(), _remove_fn: Callable = Callable()) -> Dictionary:
	var client := str(args.get("client", ""))
	var renewed := str(args.get("client_class", "")) == MemoryProject.CLIENT_CLASS_OWNER
	if renewed:
		MemoryProject.renew(client, int(args.get("lease_seconds", MemoryProject.DEFAULT_LEASE_SECONDS)))
	var result := {"renewed": renewed, "lease": MemoryProject.lease_status()}
	if not renewed:
		result["message"] = "Only a client declaring client_class=owner renews the lease."
	return result
