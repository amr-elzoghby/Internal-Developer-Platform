# خطة إعادة هيكلة مجلدات المشروع

> الحالة: **قيد التنفيذ.** نُقلت ملفات التوثيق أولًا، وتظل بقية المراحل خاضعة لاختبارات مستقلة.
>
> الهدف: جعل حدود Terraform وKubernetes وGitOps والـDeveloper Experience واضحة، بدون تغيير سلوك المنصة أو كسر Terraform state أو مسارات Argo CD وCI.

## القرار الأساسي

إعادة الهيكلة ستكون **تغييرًا ميكانيكيًا على مراحل**. لا نخلط نقل الملفات مع تحديث نسخ أو تغيير موارد أو سياسات أمنية. كل مرحلة لها commit واختبارات مستقلة.

قبل النقل سنثبت نقطتين:

1. هل يوجد Terraform state حقيقي في الـS3 backend المذكور في الكود؟
2. هل توجد Argo CD Applications أو workloads حية تعتمد على المسارات الحالية؟

لو لا توجد بيئة حية، ننفذ النقل ونختبره ثابتًا. لو توجد بيئة حية، نضيف خطة انتقال للمسارات ومراجعة `terraform plan` قبل الدمج.

## الهيكل المستهدف المقترح

```text
.
├── .github/
│   ├── CODEOWNERS
│   └── workflows/
├── apps/
│   └── <team>/<service>/
├── docs/
│   ├── architecture/
│   ├── operations/
│   ├── reviews/
│   └── images/
├── infrastructure/
│   ├── terraform/
│   │   ├── modules/
│   │   │   ├── eks/
│   │   │   └── network/
│   │   └── stacks/
│   │       └── prod/
│   │           ├── network/
│   │           └── eks/
│   └── crossplane/
│       ├── packages/
│       ├── provider-configs/
│       ├── apis/
│       │   ├── definitions/
│       │   └── compositions/
│       ├── claims/
│       └── scripts/
├── platform/
│   ├── bootstrap/
│   │   ├── storage/
│   │   └── karpenter/
│   ├── gitops/
│   │   └── argocd/
│   ├── developer-portal/
│   │   ├── backstage-config/
│   │   └── local-catalog/
│   ├── observability/
│   │   ├── prometheus/
│   │   ├── grafana/
│   │   └── kubecost/
│   ├── security/
│   │   ├── admission/
│   │   └── kyverno-disabled/
│   └── vcluster/
├── tenants/
│   ├── base/
│   ├── namespaces/
│   ├── rbac/
│   └── templates/
├── templates/
│   └── backstage/
│       ├── infra-database/
│       ├── nodejs-service/
│       └── python-fastapi/
├── Makefile
└── README.md
```

`apps/<team>/<service>` و`tenants/` سيظلان قريبين من شكلهما الحالي لأن Argo CD والـCI يعتمدان على هذا العقد. أي تغيير لهما يحتاج قرارًا معماريًا منفصلًا، وليس مجرد ترتيب مجلدات.

## خريطة النقل

| الحالي | المقترح | ما يجب تحديثه معه |
|---|---|---|
| `infrastructure/terraform/environments/prod/*` | `infrastructure/terraform/stacks/prod/*` | `Makefile`، module source paths، أوامر CI والتوثيق |
| `infrastructure/crossplane/providers` | `infrastructure/crossplane/packages` و`provider-configs` | targets وترتيب الـwaits في `Makefile` |
| `infrastructure/crossplane/definitions` | `infrastructure/crossplane/apis/definitions` | `Makefile` والتوثيق |
| `infrastructure/crossplane/compositions` | `infrastructure/crossplane/apis/compositions` | render loop في `Makefile` والتوثيق |
| `platform/argocd` | `platform/gitops/argocd` | `Makefile` وأي CI/docs |
| `platform/backstage` | `platform/developer-portal/backstage-config` | catalog locations وDocker paths إن تقرر بناء Backstage لاحقًا |
| `platform/backstage-portal` | `platform/developer-portal/local-catalog` | `make portal-up` وأي docs |
| `platform/karpenter` | `platform/bootstrap/karpenter` | `cluster-up` و`cluster-down` |
| `platform/storageclass.yaml` | `platform/bootstrap/storage/gp3.yaml` | `storage-up` |
| `platform/monitoring` | `platform/observability` | `monitoring-up` |
| `golden-paths` | `templates/backstage` | Backstage catalog locations وREADME |
| ملفات الخطط والتقارير في root | `docs/operations` و`docs/reviews` | روابط README فقط |

## قواعد حماية Terraform

- لا نغيّر أسماء resources أو modules داخل HCL أثناء نقل المجلدات.
- لا نغيّر مفاتيح الـbackend:
  - `prod/network/terraform.tfstate`
  - `prod/eks/terraform.tfstate`
- نقل root module لا يغير resource addresses وحده، لكن تغيير أسماء modules أو resources يفعل ذلك.
- نحدّث `source = "../../../modules/..."` حسب المسار الجديد ونشغّل `terraform init -backend=false` و`terraform validate` لكل root.
- لو state موجودة، نشغّل `terraform init -reconfigure` و`terraform plan` في بيئة مراجعة بعد أخذ نسخة مشفرة من state. لا نستخدم `-migrate-state` أو `state mv` بلا سبب مثبت.
- معيار النجاح للبيئة الحية: `terraform plan` لا يعرض destroy/recreate ناتجًا فقط عن النقل.

## العقود التي لا يجوز كسرها

| المستهلك | العقد الحالي |
|---|---|
| Argo CD apps | `apps/<team>/*` |
| Argo CD infra claims | `infrastructure/crossplane/claims/*` |
| GitHub Actions | `apps/<team>/<service>` و`deployment.yaml` |
| Backstage DB template | يكتب claim داخل watched claims path |
| Make tenant bootstrap | `tenants/namespaces` و`tenants/base` و`tenants/rbac/bindings/<team>.yaml` |
| Optional vCluster | ملف host namespace وملف values بالاسم نفسه لكل فريق |
| Crossplane bootstrap | packages ثم definitions ثم compositions، بهذا الترتيب |
| Terraform EKS root | يقرأ network remote state من نفس bucket/key |

## ترتيب التنفيذ المقترح

### Commit 1 — توحيد التوثيق

- إنشاء `docs/architecture` و`docs/operations` و`docs/reviews`.
- نقل الخطط والتقارير فقط وتحديث الروابط.
- لا نلمس أي مسار تنفيذي.

### Commit 2 — تنظيم Developer Experience

- نقل `golden-paths` إلى `templates/backstage`.
- جمع Backstage config والـlocal catalog تحت `platform/developer-portal`.
- تحديث catalog locations و`make portal-up`.
- اختبار template rendering والـlocal catalog.

### Commit 3 — تنظيم platform bootstrap وobservability

- نقل storage وKarpenter وmonitoring.
- تحديث `Makefile`.
- تشغيل dry-run لكل target وعدم الاتصال بالـcluster تلقائيًا.

### Commit 4 — تنظيم Argo CD

- نقل `platform/argocd` إلى `platform/gitops/argocd`.
- تحديث installer و`Makefile` وكل الروابط.
- التحقق أن ApplicationSets ما زالت تراقب paths الصحيحة.

### Commit 5 — تنظيم Crossplane

- تقسيم package declarations عن provider configs.
- نقل definitions/compositions تحت `apis` مع بقاء claims في watched path أو تحديث AppSet معها في نفس commit.
- الحفاظ على ترتيب التثبيت والـwaits.
- render لكل Composition ثم schema/static validation.

### Commit 6 — نقل Terraform roots

- `environments` تصبح `stacks`.
- تحديث relative module sources و`TF_DIR`.
- عدم تغيير HCL semantics أو backend keys.
- `fmt -check` و`init -backend=false` و`validate` للـnetwork والـEKS.
- لو توجد state حية: مراجعة plan بلا تغييرات غير مقصودة قبل الدمج.

### Commit 7 — تنظيف نهائي

- حذف المجلدات الفارغة والملفات غير المرجعية فقط بعد `rg` شامل.
- تحديث tree والروابط في README.
- تشغيل مجموعة القبول كاملة.

## مصفوفة الاختبارات بعد كل مرحلة

```text
git diff --check
rg للبحث عن المسارات القديمة
YAML/JSON parse لكل manifests
terraform fmt -check
terraform init -backend=false && terraform validate  # لكل root
make -n tenant-up
make -n vcluster-up TEAM=identity-platform
make -n crossplane-config
make -n argocd-up
node --check للـlocal catalog
Backstage template render بقيم اختبارية
Helm render للـvCluster لكل الفرق الثلاثة
```

الفحوص التي تحتاج cluster أو AWS لا تُعتبر ناجحة بمجرد نجاح الاختبار الثابت. نسجلها كـ`not run` حتى تتوفر بيئة اختبار مصرح بها.

## أسلوب النقل والـrollback

- نستخدم نقل Git واضحًا ويحافظ على history، ثم نحدّث references في نفس commit.
- لا نستخدم commit واحدة ضخمة لكل المشروع.
- بعد كل commit يجب أن يكون repository صالحًا منفردًا؛ لا نعتمد على commit لاحقة لإصلاح مسار مكسور.
- لو فشل gate، نصلح نفس المرحلة قبل بدء التالية.
- rollback يكون بعكس commit المرحلة فقط، وليس `git reset --hard` أو حذف state.
- أي live migration لها change window وخطة rollback مستقلة.

## Definition of Done

- لا يوجد reference لمسار قديم إلا داخل سجل migration مقصود.
- كل roots الخاصة بـTerraform valid، ولا توجد state address changes غير مبررة.
- كل Argo CD generators تشير لمسارات موجودة.
- كل targets في `Makefile` تشير لمسارات موجودة وتحافظ على ترتيب الاعتماديات.
- الـGolden Paths تنتج ملفات في paths يراقبها GitOps، أو تكون الفجوة موثقة بوضوح حتى تُحل.
- README والخريطة يطابقان الشجرة الفعلية.
- كل commit قابل للمراجعة والرجوع منفردًا.

## أول خطوة في التنفيذ

نبدأ بـinventory آلي لكل path reference، ثم نثبت هل توجد state/cluster حية. بعد ذلك ننفذ **Commit 1 فقط** ونراجع نتائجه قبل متابعة بقية المراحل.
