# Resilience extension roadmap — gaps, not claimed features

## Priority 0: protect against irreversible loss
If no usable backup strategy exists in production, escalate through incident/change governance immediately. Do not experiment with production. Inventory databases, owners, recovery models, business impact and desired recovery point/time objectives. Agree retention, backup destinations, access protections and restoration testing with security/business owners.

## Priority 1: prove restoration
Add lab-only backup schedules and isolated restores. Capture checksums/verification as applicable, backup-chain completeness, elapsed restore times, corruption checks and a sign-off. RMAN log text is not restore proof.

## Priority 2: distinguish HA from DR and replication
HA protects service continuity during certain failures; replication transports data but does not automatically provide failover or protection from logical corruption; DR encompasses recovery from a wider disaster. Document failure domains and application reconnection requirements.

## Priority 3: build platform-specific labs
- SQL Server: compare Always On availability groups, failover cluster instances and log shipping, with edition/version/prerequisite checks.
- Oracle: compare Data Guard and other approved Oracle HA/DR options, including licensing constraints.
- Azure/OCI: document region/zone failure domains, network dependencies and service-specific SLAs.

## Priority 4: measure resilience
Record target and actual RTO, target and observed RPO, replication lag, failover time, restore success, runbook completeness, and monitoring freshness. Label missing metrics as `NOT_CONFIGURED` or `NOT_TESTED`, never `PASS`.

## Minimum acceptance criteria for each lab
1. Architecture and failure-mode analysis.
2. Version/license/platform assumptions.
3. Approved business RTO/RPO and scope.
4. Reproducible provisioning/configuration instructions.
5. Repeatable success and negative test cases.
6. Sanitised test evidence with timestamps.
7. Rollback and risk summary.
