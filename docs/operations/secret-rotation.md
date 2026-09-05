# Database secret rotation

The platform installs Stakater Reloader `2.2.16` in `reloader`. Its namespace-scoped Roles watch only the three tenant namespaces and its own namespace. Annotated Deployments (`reloader.stakater.com/auto: "true"`) roll when an ExternalSecret updates a referenced Kubernetes Secret. Two replicas and a disruption budget keep the controller available; application readiness determines whether replacement Pods receive traffic.

Reloader does not rotate database credentials. Keep the previous credential valid until replacement Pods pass real database queries. For applications supporting alternating database users, create the next user, publish its credential to Secrets Manager, wait for the ExternalSecret Ready condition and Deployment rollout, verify new connections under traffic, then revoke the old user. Single-user master-password rotation can interrupt existing clients; use a maintenance window until the application supports overlap. Do not claim zero downtime based only on a successful Pod restart.

Before enabling the quarantined login artifact, its owner must verify TLS database connections, a semantic readiness check, non-root execution, and credential overlap in a sandbox. Environment variables do not update in already-running processes.

Record the starting Secrets Manager version IDs without copying values into logs. After rotation, verify the ExternalSecret refresh timestamp, `kubectl rollout status deployment/NAME -n TEAM`, error rate, and a new authenticated query. On failure, keep the former database user valid, restore the former secret version, wait for another monitored rollout, and verify traffic before retrying. Never revoke the only working credential before the canary passes.
