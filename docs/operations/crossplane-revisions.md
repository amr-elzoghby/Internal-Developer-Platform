# Controlled composition promotion

Each XRD enforces one named Composition and defaults to `Manual` revisions. The checked-in claims explicitly request `Manual`. Tenant admission must reject `Automatic`, composition selectors, and unapproved revision changes; an XRD default by itself can be overridden by the requester. Tenant ResourceQuota limits the count of each API; Git policy validates the same budgets and region/owner contract before merge.

Platform changes first create a new CompositionRevision without changing existing requests. `make crossplane-compositions` checks pipeline validity; this only verifies the function reference, not AWS behavior. Create a canary request under the same approved API, record its selected revision and observed AWS settings, and run the data/availability tests in the service runbook. Only after the canary succeeds, submit a reviewed PR setting existing requests' `spec.crossplane.compositionRevisionRef.name` to that exact revision. Keep `compositionUpdatePolicy: Manual` throughout. Promote one tenant at a time and watch `Synced`/`Ready` plus the service health signal.

Reverting Git to the previous known-good revision is the rollback for reversible settings. Storage encryption changes, resource replacement and database engine migrations need a restore or explicit migration procedure; selecting an old revision does not recover deleted or migrated data. A new request without a revision pin initially selects the current revision; restrict request creation during an unaccepted composition rollout or pin it to the approved revision in the request PR.

The first installation has no existing revision hashes. Do not invent hashes in templates. After the initial canary, reviewers must record the approved revision on each real request. Only PostgreSQL has a portal template today; the other three APIs use reviewed YAML requests with identical XRD/admission/quota controls. This is a documented interface choice, not an unimplemented portal action.

Reference: [Crossplane v2 composition revisions](https://docs.crossplane.io/latest/composition/composition-revisions/).
