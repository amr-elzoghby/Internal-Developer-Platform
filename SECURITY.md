# Security policy

Report suspected vulnerabilities privately to the repository owner, using GitHub private vulnerability reporting when enabled. Include the affected commit, a minimal reproduction, impact, and suggested mitigation. Never put credentials, private state, or exploit details in public issues.

The maintained deployment path is the current default branch after its required checks pass. Container releases require an approved ECR digest, build provenance, an SPDX SBOM, and a HIGH/CRITICAL vulnerability gate. A failed security gate must be resolved through a reviewed change; no blanket scanner exclusions are accepted.

Repository administrators must enable secret scanning and push protection, require passing Repository quality and Verify deployment images checks, require CODEOWNERS review, dismiss stale approvals, and prohibit direct or force pushes to the default branch. CODEOWNERS currently names the actual repository maintainer; replace that entry with a real organization team and require independent review when a second maintainer is onboarded. A file in this repository does not itself enforce GitHub branch rules.
