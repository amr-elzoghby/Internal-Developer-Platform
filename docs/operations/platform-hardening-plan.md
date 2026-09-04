# خطة تقوية المنصة — الحالة الفعلية

> آخر تحديث: 4 سبتمبر 2026
>
> حالة البيئة: صاحب المشروع أكد أن المشروع **غير مشغّل حاليًا**. نتائج هذه الوثيقة مبنية على مراجعة الكود واختبارات ثابتة ومحلية، وليست إثباتًا أن AWS أو EKS أو Crossplane يعملون في بيئة حية.
>
> قاعدة أمان: لا نشغّل `terraform apply/destroy` أو `make up/down` أو أي حذف على AWS/Kubernetes بدون بيئة مصرح بها، مراجعة plan، وتأكيد صريح.

## ملخص تنفيذي

الأساس الأمني والمعماري تحسن بالفعل:

- Host EKS namespaces هي حدود الفرق الوحيدة المنفذة في المستودع.
- EKS access entries وKubernetes RBAC مفصولان بين platform admins والفرق.
- Argo CD AppProjects أصبحت مقيدة بالـnamespace والأنواع المسموحة.
- Pod Security Admission وValidatingAdmissionPolicy الأصليتان في Kubernetes هما طبقة enforcement الحالية.
- Kyverno متوقفة fail-closed لأن النسخة الموجودة في المستودع غير معتمدة للمسار الحالي على Kubernetes 1.36.
- Crossplane انتقلت إلى v2 namespaced APIs لأربع خدمات فقط: S3 وEC2 وRDS PostgreSQL وElastiCache Redis.
- AWS providers تستخدم IRSA roles منفصلة وMRAP تفعّل ثمانية managed resource kinds فقط.
- واجهة الويب المحلية أصبحت catalog للقراءة فقط، وليست Backstage كاملة أو بوابة provisioning.
- أسماء الفرق أصبحت واقعية ومتسقة:
  - `identity-platform`
  - `platform-engineering`
  - `data-platform`

لكن المنصة ليست production-ready بعد. أهم blockers هي غياب اختبار حي، وضع worker nodes في public subnets، EKS public endpoint غير مقيد في الكود، عدم وجود ingress controller، وفجوة بين Golden Paths التي تنشئ repositories منفصلة وArgo CD الذي يراقب monorepo.

## البنية المعتمدة حاليًا

```text
AWS
├── VPC 10.0.0.0/16
│   ├── Public subnets (2)  ← stable EKS nodes حاليًا
│   ├── Private subnets (2) ← RDS/Redis وVPC endpoints
│   └── S3/ECR/STS/EKS/EC2/SSM/Logs endpoints
├── EKS 1.36
│   ├── identity-platform namespace
│   ├── platform-engineering namespace
│   ├── data-platform namespace
│   ├── argocd
│   ├── crossplane-system
│   ├── external-secrets
│   └── monitoring (اختياري عبر target منفصل)
└── Crossplane namespaced APIs
    ├── ObjectBucket       → S3 Bucket
    ├── ServerInstance     → EC2 + Security Group
    ├── PostgresSQLInstance→ RDS + subnet/security groups
    └── RedisInstance      → ElastiCache + subnet/security groups
```

المسار المعتمد للفرق هو namespace داخل Host EKS، موصولة من IAM role إلى EKS Access Entry ثم Kubernetes group وRoleBinding داخل namespace. هذا يقلل تكلفة وتعقيد التشغيل، مقابل مشاركة الـcontrol plane والـcluster-scoped APIs بين الفرق تحت إدارة فريق المنصة.

## ما تم تنفيذه

### 1. سلامة الـbootstrap والـteardown

| Commit | النتيجة |
|---|---|
| `daf7b14` | منع teardown العادي من حذف tenant namespaces |
| `0e4179d` | إضافة encrypted `gp3` StorageClass إلى bootstrap |
| `5b6e326` | إضافة أول confirmation guard قبل teardown؛ طُورت لاحقًا إلى تحقق كامل من هوية الهدف |

الحماية الحالية تثبت account/region/cluster الخاصة بالإنتاج داخل الكود، وتتحقق من AWS caller وEKS ARN وحالة Cluster، ثم تنشئ snapshot خاصة من kubeconfig وتطابق endpoint وCA والصلاحيات قبل أي حذف. أوامر `kubectl delete` تستخدم الـsnapshot نفسها، بينما Terraform تثبت الـvariables والـdefault workspace وتستخدم `allowed_account_ids` في الـproviders والـbackends.

### 2. EKS identities وTenant RBAC

| Commit | النتيجة |
|---|---|
| `e4fd75d` | platform-admin وbreak-glass access entries صريحة |
| `275029e` | ربط IAM roles الخاصة بالفرق بـKubernetes groups |
| `88e740b` | viewer/operator RoleBindings داخل namespace الفريق فقط |
| `083f0b3` | workload ServiceAccount محدودة وتعطيل token غير اللازمة |
| `a8e8a27` | External Secrets IRSA role منفصلة لكل tenant secret prefix |

سلسلة الهوية:

```text
AWS IAM role
→ EKS Access Entry
→ idp:tenant:<team>:viewer|operator
→ RoleBinding داخل namespace الفريق
→ read-only أو عمليات تشغيل محدودة
```

الفرق لا تحصل من هذا المسار على قراءة Secrets أو إنشاء RBAC أو صلاحيات cluster-wide.

### 3. Argo CD وGit protection

| Commit | النتيجة |
|---|---|
| `6940f46` | تقييد مشروع infrastructure claims وحمايتها من prune التلقائي |
| `889c57e` | allowlists وdestinations محددة لكل Team AppProject |
| `b198574` | إزالة الصلاحية الافتراضية العامة للمستخدمين authenticated |
| `b82066f` | CODEOWNERS للمسارات الحساسة |

هذه القيود داخل repository فقط. تفعيل branch protection وrequired reviews على GitHub ما زال إعدادًا خارجيًا يجب إثباته.

### 4. Workload admission وSupply chain

| Commit | النتيجة |
|---|---|
| `144ef02` | PSA: baseline enforce وrestricted warn/audit |
| `6ee4b3a` | securityContext وresources وprobes وServiceAccount أكثر أمانًا |
| `6c15c0b` | CI تربط deployment بصورة immutable ولا تستخدم `latest` |
| `16b6211` | ValidatingAdmissionPolicy أصلية مع rollout Audit/type-check/Deny |

السياسات الحالية تفرض tags/digests صريحة، requests/limits، و`team` label مطابقًا للـnamespace. نجاح ملفات CEL ثابتًا لا يغني عن type-check حقيقي من Kubernetes 1.36 API server.

### 5. Crossplane v2 namespaced

| Commit | النتيجة |
|---|---|
| `2194594` | فصل ترتيب packages ثم definitions ثم compositions وإضافة waits |
| `be1aa4e` | Crossplane Core `2.4.0` |
| `99ab06d`, `f119e67` | AWS providers `2.7.1` وFunction Python `0.5.0` وإصلاحات التوافق |
| `5564a3e` | S3 إلى direct namespaced v2 |
| `302fc1d` | EC2 إلى direct namespaced v2 |
| `ae361cb` | RDS إلى direct namespaced v2 |
| `9df2185` | Redis إلى direct namespaced v2 |
| `7ba5680` | MRAP للثمانية أنواع المستخدمة فقط |
| `16b6211` | محاذاة claim paths والـGolden Path والـportal مع APIs الفعلية |

الـmanaged resources لا تحتوي `Delete` في `managementPolicies`. حذف claim لا يحذف مورد AWS تلقائيًا؛ هذا قرار حماية بيانات، لكنه يحتاج orphan inventory وrunbook للحذف المعتمد.

### 6. Tenant namespaces وأسماء الفرق

| Commit | النتيجة |
|---|---|
| `d1107a6` | أسماء الفرق الجديدة في Terraform وRBAC وArgo وCrossplane وBackstage |

كل فريق له namespace وEKS groups وRoleBindings وArgo CD project متطابقة الاسم. الـnamespace وRBAC وNetworkPolicy وadmission هي حدود العزل الحالية؛ لا يملك كل فريق API server أو control plane أو إصدار Kubernetes مستقلًا، وتظل الموارد والـcontrollers ذات النطاق cluster-wide مملوكة لفريق المنصة.

## نتائج التحقق الحالية

نجح:

- `terraform validate` للـnetwork root.
- `terraform validate` للـEKS root؛ ظهرت فقط warnings من dependency خارجية تستخدم attribute deprecated.
- `terraform fmt -check` للملفات التي تغيرت.
- parsing لملفات YAML/JSON غير القالبية.
- render تجريبي للـGolden Paths ثم JavaScript/Python/YAML checks.
- JavaScript syntax checks للـlocal catalog.
- HTTP smoke محلي:
  - root وhealth وclaim specs أعادت `200`.
  - login القديم وwrite API أعادا `404`.
  - محاولة path traversal لم تكشف ملفًا.
- `make -n` لمسارات cluster وtenant.
- اختبارات `make test-destroy-guard` المحلية تغطي فشل التأكيد والـaccount وARN وendpoint وCA والصلاحيات، وتثبت عدم وصول أي حالة فشل إلى أمر حذف.
- بحث شامل عن أسماء الفرق القديمة؛ بقي اسم واحد مقصود داخل ECR image URI القديمة.

لم يُشغّل:

- `terraform plan/apply` ضد AWS.
- `kubectl apply` أو server-side dry-run ضد EKS 1.36.
- Crossplane Provider/Composition/claim reconciliation حي.
- Argo CD sync.
- CNI NetworkPolicy enforcement test.
- RDS/Redis connectivity أو connection-secret contract.
- استعادة backup أو disaster recovery.

## المخاطر المفتوحة مرتبة بالأولوية

### P0 — يجب حلها قبل اعتبار المنصة قابلة للنشر

#### 1. لا يوجد إثبات تشغيل حي

**التأثير:** نجاح parsing لا يكشف أخطاء AWS permissions أو CRD schemas أو CEL type-check أو controller behavior.

**التنفيذ المقترح:** بيئة sandbox منفصلة، ثم `terraform plan`، bootstrap تدريجي، وsmoke tests بالترتيب: S3 ثم EC2 ثم RDS ثم Redis.

**شرط القبول:** Providers وFunctions `Healthy=True`، XRDs established، Compositions valid، claims ready، ولا يوجد privilege escalation بين فريقين.

#### 2. Stable worker nodes موجودة في public subnets

**المكان:** `infrastructure/terraform/modules/eks/cluster.tf`.

**التأثير:** الـnodes تحصل على public IPs لأن public subnets تستخدم `map_public_ip_on_launch=true`. هذا يوسع سطح التعرض، حتى مع Security Groups.

**التعديل الأفضل:** نقل managed node group وKarpenter workloads إلى private subnets. نثبت أولًا أن VPC endpoints/NAT تغطي bootstrap وimage pulls والـAWS APIs المطلوبة.

**Trade-off:** private nodes أكثر أمانًا، لكنها تحتاج outbound design مكتمل؛ نقلها بدون endpoints/NAT كافية قد يمنع node bootstrap أو downloads.

#### 3. EKS public API endpoint غير مقيد

**المكان:** `endpoint_public_access=true` ولا توجد `public_access_cidrs` في module.

**التأثير:** endpoint عامة على الإنترنت ومحمية بالمصادقة، لكن بلا network allowlist من هذا الكود.

**التعديل الأفضل:** private endpoint أساسي، وpublic endpoint مغلق أو مقيد بعناوين VPN/office ثابتة. بعد إثبات وصول CI وbreak-glass فقط.

**Trade-off:** إغلاق endpoint قبل توفير VPN/runner داخل VPC قد يقطع الإدارة وCI.

#### 4. Ingress manifests بلا Ingress Controller

**المكان:** Argo CD و`login-app` يستخدمان `ingressClassName: nginx`، والمستودع لا يثبت controller بهذا الاسم.

**التأثير:** الموارد قد تُقبل في Kubernetes لكن لا تصبح لها نقطة دخول.

**التعديل الأفضل:** اختيار AWS Load Balancer Controller مع IRSA ونسخة مثبتة، أو حذف Ingress إلى أن توجد استراتيجية ingress/DNS/TLS معتمدة.

**Trade-off:** AWS LBC يضيف IAM/controller وتكلفة ALB؛ الإبقاء على ClusterIP أبسط لكنه لا يوفر وصولًا خارجيًا.

#### 5. Golden Paths لا تتصل بعقد GitOps الحالي

**المشكلة:** Node/Python templates تنشر repository منفصلة، بينما ApplicationSets تراقب `apps/<team>/*` داخل هذا monorepo. Python starter لا يحتوي Kubernetes manifests أصلًا.

**التأثير:** نجاح scaffolding لا يعني deployment.

**الخيار الموصى به:** اجعل القوالب تفتح PR تضيف الخدمة إلى `apps/<team>/<service>` في monorepo، أو غيّر Argo إلى SCM/repository discovery في تصميم منفصل.

**Trade-off:** monorepo أبسط ويتوافق مع CI الحالي؛ multi-repo يعطي استقلالية أكبر لكنه يحتاج repository registration وcredentials وgovernance.

#### 6. Crossplane runtime contracts غير مختبرة

يجب إثبات:

- أسماء وحقول APIs الفعلية في provider `2.7.1`.
- connection secret keys، خصوصًا هل RDS يكتب `host` كما يتوقع التطبيق أم مفتاحًا مختلفًا.
- behavior عند حذف claim مع `Delete` غير مفعلة.
- IAM actions الكافية بدون توسيع غير ضروري.
- EC2 Composition لا تضع `metadata.namespace` صراحةً على الموارد الثلاثة، بعكس باقي Compositions؛ يجب تصحيحها أو إثبات defaulting موثق قبل canary.

لا نعدل الـapp إلى contract مفترض قبل smoke test.

#### 7. S3 وEC2 ينقصهما hardening داخل الـCompositions

- S3 تنشئ `Bucket` فقط؛ لا توجد موارد صريحة للتشفير أو versioning أو ownership controls أو public-access block.
- EC2 لا تصرح بـIMDSv2 ولا تشفير root volume، وقاعدة port 80 تسمح من VPC CIDR بالكامل.

**التنفيذ المقترح:** إضافة managed resource kinds اللازمة إلى MRAP وIAM أولًا، ثم إضافة controls للـCompositions واختبار canary. لا نصف AWS defaults بأنها policy مضمونة من المنصة.

### P1 — تقوية مطلوبة بعد أول نشر ناجح

#### 8. Network egress وdatabase ingress أوسع من المطلوب

- tenant policy تسمح TCP/443 إلى `0.0.0.0/0`.
- RDS وRedis Security Group rules تسمح من VPC CIDR بالكامل.
- تفعيل AWS CNI NetworkPolicy موجود، لكن strict behavior لم يُثبت حيًا.

**المستهدف:** flow matrix واضحة لـDNS وECR/STS/Secrets Manager والـdatabases، ثم تضييق 443 واستبدال VPC CIDR بهوية workload مثل Security Groups for Pods حيث يناسب.

**Trade-off:** allowlists تقلل lateral movement، لكنها تحتاج inventory حقيقي وإلا ستكسر integrations.

#### 9. Redis ليست production hardened

الكود الحالي يستخدم Redis 7.1 وعقدة واحدة، ولا يظهر فيه transit encryption أو at-rest encryption أو auth/ACL أو automatic failover أو snapshots.

**المستهدف:** TLS، encryption at rest، secret-based authentication، Multi-AZ/failover، snapshot retention، واختبار client compatibility.

**Trade-off:** تكلفة أعلى، clients تحتاج TLS/auth، وبعض الخيارات قد تتطلب replacement حسب AWS/provider.

#### 10. Secrets Manager recovery معطلة

`recovery_window_in_days = 0` يجعل حذف secret فوريًا عند destroy.

**المستهدف:** recovery window مناسبة للإنتاج، مع استثناء موثق فقط لبيئات مؤقتة.

**Trade-off:** الاستعادة أسهل، لكن الاسم والتكلفة يظلان محجوزين أثناء recovery window.

#### 11. Helm dependencies غير مثبتة كلها

Argo CD وCrossplane وMetrics Server مثبتة النسخ. External Secrets وPrometheus/Kubecost targets لا تحدد chart versions.

**المستهدف:** version pins، values مراجعة، `--atomic --wait`، readiness، وسياسة تحديث دورية.

#### 12. Sample application تعتمد على artifact قديم

المسار أصبح `identity-platform` لكن ECR URI ما زالت باسم `idp-team-alpha-login-app` للحفاظ على artifact المنشور.

**المستهدف:** إثبات وجود الصورة، نسخها إلى repository الجديد بالـdigest، تحديث manifest إلى `@sha256`، ثم حذف alias القديم بعد مدة rollback. لو artifact غير موجود، نحذف demo بدل اختراع URI.

#### 13. IAM boundaries تحتاج اختبار وتقليل إضافي

تم فصل roles حسب S3/RDS/Redis/EC2 وإضافة ownership tags ومنع state bucket بالكامل. مع ذلك بعض read/reconciliation actions تستخدم resources واسعة بسبب قيود AWS APIs.

**المستهدف:** CloudTrail canary، Access Analyzer، وتضييق actions/resources/conditions حيث تسمح الخدمة بدون كسر reconciliation.

### P2 — نضج تشغيلي وتجربة مطور

#### 14. Backstage ليست application قابلة للبناء من هذا المستودع

`platform/developer-portal/backstage-config` يحتوي config/catalog وDockerfile يفترض وجود `packages` و`plugins` وroot Yarn project غير موجودة. `make portal-up` يشغّل `platform/developer-portal/local-catalog` للقراءة فقط.

**القرار المطلوب:** إما scaffold رسمي لتطبيق Backstage وتوصيل auth/catalog/scaffolder، أو إبقاء config كمرجع وتسميته بوضوح.

#### 15. Monitoring غير مثبت تشغيليًا

القيم موجودة، لكن لا توجد نتائج تثبيت أو alerts/runbooks/SLOs مثبتة. لا نصف Grafana/Prometheus/Kubecost بأنها live قبل الاختبار.

#### 16. Kyverno files مرجعية فقط

`make kyverno-up` يفشل عمدًا. يجب إما اعتماد نسخة متوافقة واختبارها، أو حذف الملفات القديمة بعد نقل أي سياسات لازمة إلى native admission/GitOps checks.

#### 17. Orphaned cloud resources تحتاج lifecycle runbook

حماية الموارد من delete مفيدة، لكن يجب وجود:

- inventory دوري للclaims المحذوفة والموارد الباقية.
- approval workflow للحذف.
- backup/restore قبل RDS/Redis deletion.
- tagging يربط AWS resource بالـnamespace والclaim.

## ترتيب التنفيذ القادم

### المرحلة A — إثبات الواقع

- [ ] تأكيد AWS account/region/backend المراد اختباره.
- [ ] `terraform plan` للـnetwork ثم EKS بدون apply.
- [ ] inventory لأي موارد أو state موجودة.
- [ ] إنشاء sandbox/change window مصرح بها.

### المرحلة B — إغلاق perimeter blockers

- [ ] private node groups.
- [ ] EKS endpoint allowlist/private access.
- [ ] اختيار ingress controller وDNS/TLS design.
- [ ] اختبار break-glass قبل إزالة bootstrap creator admin أو الانتقال إلى API-only auth.

### المرحلة C — توصيل Golden Paths بـGitOps

- [ ] اختيار monorepo أو multi-repo رسميًا.
- [ ] تحديث Node template وفق العقد المختار.
- [ ] إضافة Kubernetes path حقيقي لـPython أو إبقاؤها scaffold فقط.
- [ ] PR approval/CODEOWNERS/branch protection.
- [ ] end-to-end test من template إلى Argo sync.

### المرحلة D — Crossplane canaries

- [ ] S3 canary بدون object-data permissions.
- [ ] EC2 canary بـAMI معتمدة.
- [ ] RDS canary واختبار secret keys/backup/deletion protection.
- [ ] Redis canary بعد إضافة TLS/encryption/auth/HA.
- [ ] cross-team RBAC negative tests.

### المرحلة E — Network hardening

- [ ] جمع flows الفعلية.
- [ ] تضييق tenant HTTPS egress.
- [ ] تضييق RDS/Redis ingress.
- [ ] تفعيل/إثبات strict enforcement تدريجيًا.

### المرحلة F — تشغيل المنصة

- [ ] pin ESO/monitoring dependencies.
- [ ] alerts وSLOs وrunbooks وbackup/restore drill.
- [ ] قرار Backstage الحقيقي.

### المرحلة G — إعادة هيكلة المجلدات

الخطة التفصيلية موجودة في `repository-restructure-plan.md`. لا يبدأ أي نقل يؤثر على بيئة حية قبل تثبيت state/live-path assumptions، ولا يُخلط مع تغييرات السلوك.

## معايير الجاهزية النهائية

لا نستخدم وصف production-ready إلا عندما تتحقق كلها:

- Terraform plan مراجَع ولا يحتوي replacements غير مقصودة.
- EKS nodes خاصة والـAPI endpoint مقيدة.
- كل controller pinned وHealthy.
- admission policies type-checked وتعمل fail-closed كما هو مقصود.
- Git → review → Argo → workload flow مثبت end-to-end.
- كل Crossplane API لها canary ناجحة وconnection contract موثق.
- tenant isolation مثبت باختبارات positive وnegative.
- RDS/Redis backup وrestore مجربان.
- ingress/DNS/TLS فعالة ومملوكة.
- observability وalerts وrunbooks موجودة.
- branch protection وCODEOWNERS مفعلان، لا مجرد ملفات في Git.

## طريقة تحديث هذه الخطة

بعد كل تغيير:

1. commit واحدة لمشكلة واحدة أو مجموعة مترابطة صغيرة.
2. نسجل hash والاختبارات والـwarnings.
3. نميّز بين static pass وlive pass.
4. لا نحول بندًا إلى مكتمل بسبب نجاح YAML parsing فقط.
5. أي تغيير قد يحذف أو يستبدل موردًا حيًا يحتاج plan وbackup وrollback وموافقة منفصلة.
