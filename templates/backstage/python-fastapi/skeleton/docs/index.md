# ${{ values.component_id }}

Owned by `${{ values.owner }}` in `apps/${{ values.owner }}/${{ values.component_id }}`.

`GET /healthz` checks application health. Source changes trigger the build and scan pipeline after merge. Review the digest promotion PR to enable deployment. Use a reviewed Git revert of the promotion commit to roll back; Argo CD follows main.
