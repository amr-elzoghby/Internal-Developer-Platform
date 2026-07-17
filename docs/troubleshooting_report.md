Crossplane Database Provisioning Troubleshooting Report

This document outlines the key technical challenges encountered during the setup, debugging, and validation of database provisioning using Crossplane and Terraform on AWS EKS, along with their root causes and resolutions.

---

Summary of Challenges and Solutions

1. Issue/Error: cannot resolve references: VPCID: no resources matched selector
   Component: Crossplane Composition
   Root Cause: Selectors searched for VPC/Subnets in Crossplane, but they were managed by Terraform.
   Resolution: Replaced selectors with environment variables dynamically substituted from Terraform outputs.

2. Issue/Error: token file name cannot be empty (CannotConnectToProvider)
   Component: EKS IRSA / AWS Provider
   Root Cause: AWS Provider ServiceAccounts lacked the role ARN annotation, preventing EKS from injecting tokens.
   Resolution: Created DeploymentRuntimeConfig to dynamically inject Role ARN annotations into Provider pods.

3. Issue/Error: sts:AssumeRoleWithWebIdentity AccessDenied
   Component: AWS IAM Trust Policy
   Root Cause: Terraform generated StringEquals for wildcard service accounts, which matches literally instead of acting as wildcard.
   Resolution: Refactored EKS module to use a custom aws_iam_role resource with explicit StringLike wildcard matching.

4. Issue/Error: Cannot find version 15.4 for postgres
   Component: AWS RDS Postgres Engine
   Root Cause: AWS deprecated Postgres version 15.4 in the us-east-1 region.
   Resolution: Updated default Postgres minor version to 15.13 (supported and active).

5. Issue/Error: Invalid master password
   Component: AWS RDS Password Policy
   Root Cause: Suffixes added to XR names mismatch developer secret name, resulting in empty password values. Also, RDS checks blocked common words like "password" and "admin".
   Resolution: Updated Python script to map directly to the Claim Name. Switched developer secret password to AmrElzoghbyEksCluster2026.

6. Issue/Error: READY = False indefinitely on XR/Claim
   Component: Custom Python Script
   Root Cause: Custom python composition script did not propagate individual resource status check values to Crossplane engine.
   Resolution: Added is_ready helper inside the python script and mapped .ready field status outputs explicitly.

---

In-Depth Technical Analysis

1. Crossplane Selectors vs. Terraform Managed Infrastructure
   - Behavior: Compositions were failing to sync security groups and subnet groups with errors indicating that VPC and Subnet Selectors did not find any matching resources in the cluster.
   - Analysis: Crossplane's default templates used labels to search for VPC and Subnet objects managed by Crossplane. However, our VPC infrastructure was built entirely via Terraform.
   - Solution: Parameterized rds-postgres.yaml and redis-elasticache.yaml with ${VPC_ID}, ${PRIVATE_SUBNET_1}, and ${PRIVATE_SUBNET_2}. Updated the Makefile to retrieve these IDs directly from Terraform outputs and render templates using envsubst during make up.

2. AWS Authentication & Pod Role Mapping (IRSA)
   - Behavior: Providers failed to sync with "token file name cannot be empty".
   - Analysis: EKS projects IAM role credentials (using web identity tokens) into pods based on ServiceAccount annotations. The ServiceAccounts created by Crossplane lacked eks.amazonaws.com/role-arn.
   - Solution: Created a new Crossplane DeploymentRuntimeConfig template pointing to the IAM Role ARN. Linked each provider in providers.yaml to the runtime config using runtimeConfigRef.

3. Wildcard ServiceAccount Matching in AWS IAM Trust Policy
   - Behavior: Providers got sts:AssumeRoleWithWebIdentity AccessDenied even with annotations present.
   - Analysis: AWS provider ServiceAccounts are suffixed with dynamic hashes (e.g. provider-aws-rds-a2d79fe752c3). EKS IAM Module generated a trust policy using StringEquals for system:serviceaccount:crossplane-system:provider-aws-*. In AWS IAM, StringEquals treats asterisks as literal characters.
   - Solution: Replaced the terraform-aws-modules role setup with a custom aws_iam_role and aws_iam_policy_document. Configured StringLike operator for OIDC audience/subject matching to fully support wildcard suffixes. Added wildcard coverage for upbound-provider-family-aws-*.

4. Deprecated PostgreSQL Minor Versions
   - Behavior: RDS instance returned InvalidParameterCombination: Cannot find version 15.4 for postgres.
   - Analysis: AWS deprecates outdated Postgres minor versions periodically. Version 15.4 was no longer available.
   - Solution: Queried supported database engine versions via AWS CLI and updated the engine configuration inside rds-postgres.yaml to 15.13.

5. Password Strengths & Name-Suffix Mismatches
   - Behavior: AWS RDS instance creation failed with Invalid master password.
   - Analysis:
     * The Python script fetched the metadata name of the Composite Resource (XR) which contains random suffixes (e.g., team-alpha-db-jx2pz), meaning it looked for team-alpha-db-jx2pz-password instead of the developer's secret team-alpha-db-password.
     * AWS RDS password checks reject passwords containing common dictionary strings like password or admin.
   - Solution: Changed the Python logic to fetch claimRef.name (team-alpha-db). Switched the developer test password to AmrElzoghbyEksCluster2026.

6. Readiness Status Propagation in Composition Pipelines
   - Behavior: Database was ready and connection secret was created, but the Claim status remained READY = False.
   - Analysis: Composition functions running under Python pipelines require the developer to calculate and write the .ready status of each composed resource. Without setting .ready, Crossplane cannot determine status and defaults to unready.
   - Solution: Added a helper inside the Python script to check for Ready conditions in the observed resource struct and assign .ready = 1 (True) dynamically.
