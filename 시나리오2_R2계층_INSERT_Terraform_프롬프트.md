# 시나리오2 MITM 랩 — R2 계층(Design1) INSERT Terraform 추가 (was_tg 본선)

> **성격**: INSERT(의도 삽입) · 하위 토글 게이팅 · was_tg 본선 최소 세트
> **대조 근거**: infra `08be767` (`mitm_lab.tf` · `iam.tf` · `observability.tf` · `compute.tf` · `security_groups.tf`) — 팀 브랜치/SHA 확인 후 apply
> **검증 상태**: 접목 시 apply-깨짐 없음(BUG-1 `[0]` · BUG-2 B3 merge · C4 forward 루프 방지 반영). 참조 유효성·카운트 포함관계·버킷 정책 삭제 허용·kms 세트 전부 코드 대조 완료.

---

## 배경 / 성격

- 기존 `mitm_lab.tf`(ELB 한정 confused-deputy, §A/§B)는 **그대로** 두고, 위에 **R2 계층**을 하위 토글로 얹는다. 전부 **INSERT**이며 base 동작·한계는 불변.
- R2 계층이 하는 일: **Lambda가 SSM에서 r2 AccessKey를 읽어 응답에 실어주고**, 그 키로 **CloudTrail 무력화 · 로그버킷 삭제**가 가능해진다. (ELB Register/Deregister는 기존 §A 그대로.)

## 게이팅 (먼저)

```hcl
variable "enable_design1_r2" {
  type    = bool
  default = false
}

locals {
  r2_count = var.enable_mitm_lab && var.enable_design1_r2 ? 1 : 0
}
```

- **`count = local.r2_count` 적용 대상 = A1–A4 · B1 만.**
- **B3은 기존 `aws_lambda_function.elb_deputy`(이미 `count = local.mitm_count`)에 `environment` 속성 INSERT** — Lambda 자체를 `r2_count`로 다시 세지 말 것.

## 추가 Terraform (mitm_lab.tf)

### A1 — R2 IAM 사용자
- `aws_iam_user "r2"` — 이름 예 `kidhack-r2-deputy`, `count = local.r2_count`.

### A2 — R2 AccessKey
- `aws_iam_access_key "r2"` — `user = aws_iam_user.r2[0].name`.
- secret은 생성 시 1회 노출 → 바로 A3로 배선. **tfstate에 평문 잔존**(secrets.tf와 동일 한계) → state 보호.

### A3 — SSM SecureString
- `type = "SecureString"`
- `name = "/kidhackapp/lab/r2-access-key"`
  - **검증**: 앱 6키(`/kidhackapp/rds`,`docdb`,`app`,`dockerhub/…`)·관측(`/kidhackapp/vpc`,`cloudwatch-agent/…`)과 **충돌 없음** — `lab/`은 신규 접두.
- `value = jsonencode({ id = aws_iam_access_key.r2[0].id, secret = aws_iam_access_key.r2[0].secret })`
- `key_id` 생략 → `alias/aws/ssm` (B1 kms 조건과 세트).

### A4 — R2 IAM 정책 (`aws_iam_user_policy`, R2 유저 부착)
3 statement:

1. **S3 (로그버킷 한정)**
   - `["s3:DeleteObject","s3:ListBucket"]`
   - Resource `[aws_s3_bucket.cloudtrail.arn, "${aws_s3_bucket.cloudtrail.arn}/*"]`
   - **검증**: 버킷 정책의 유일한 Deny는 `DenyInsecureTransport`(비TLS)뿐 → **TLS 호출이면 IAM Allow로 삭제 동작**. (열람·유출 스토리면 `s3:GetObject` 추가, wipe만이면 생략)
2. **CloudTrail 무력화 (trail ARN 한정)**
   - `["cloudtrail:StopLogging","cloudtrail:DeleteTrail"]`
   - Resource `aws_cloudtrail.main.arn` — **별도 변수 없이 resource 직접 참조**.
3. **(선택) LookupEvents**
   - `["cloudtrail:LookupEvents"]`, Resource `"*"` — **LookupEvents는 리소스 스코핑 미지원 → `*` 필수**. 불필요하면 생략.

### B1 — Lambda 실행역할 SSM/KMS (`aws_iam_role_policy`, `count = local.r2_count`)
`elb_deputy_exec[0]`에 별도 인라인 정책:
- `["ssm:GetParameter"]`, Resource `aws_ssm_parameter.r2[0].arn` (단일 ARN)
- `["kms:Decrypt"]`, Resource `"*"`, Condition `StringEquals { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" }`
- **SecureString 복호 세트 필수. `iam.tf`의 `ssm_params` kms 조건 그대로 복제.**

### B3 — Lambda environment (기존 리소스, `count = local.mitm_count` 유지)
`aws_lambda_function.elb_deputy`에 `environment` 속성 추가:

```hcl
environment {
  variables = merge(
    {
      WEB_TG_ARN   = aws_lb_target_group.web_tg.arn
      WAS_TG_ARN   = aws_lb_target_group.was_tg.arn
      MITM_NODE_ID = aws_instance.mitm_node[0].id
    },
    local.r2_count == 1 ? {
      # 이름 고정이라 리터럴도 가능(0-리스크): "/kidhackapp/lab/r2-access-key"
      R2_PARAM_NAME = one(aws_ssm_parameter.r2[*].name)
    } : {}
  )
}
```

- TG ARN·MITM_NODE_ID → `enable_mitm_lab`만 ON이어도 항상 설정(핸들러 Register/Deregister용).
- R2_PARAM_NAME → `enable_design1_r2`일 때만 merge. **`one(...[*])` 또는 리터럴로 카운트-세이프** (`aws_ssm_parameter.r2[0]` 직접 인덱싱은 mitm=1·r2=0 조합에서 index-out-of-range 위험).

## 스코프 규율

- 원칙: **단일 ARN/특정 리소스 참조, 와일드카드 금지.**
- 예외만: `kms:Decrypt`의 `*`+Condition, `cloudtrail:LookupEvents`의 `*`, (기존 §A) ELB `Describe*`의 `*`.
- trail·버킷 ARN은 `aws_cloudtrail.main.arn` / `aws_s3_bucket.cloudtrail.arn` **직접 참조**(변수 불필요).

## 팀 아티팩트 (Terraform 아님 — C계열 경계)

- 핸들러 zip(`deputy_zip_path`) · 프록시 AMI(`mitm_node_ami`) · 역프록시 `user_data`(§B, 현재 PLACEHOLDER)는 **별도 산출물**.
- 인프라는 **C4 forward 대상**만 프록시 `user_data` 템플릿 변수로 주입:
  - forward = **정상 WAS 인스턴스 private IP** — `[for id, i in aws_instance.was : i.private_ip]` (**키-무관 권장**. `aws_instance.was`는 `for_each` 맵이라 `["1"]`은 키가 "1"일 때만 유효). 핸들러가 목록에서 healthy 하나 선택.
  - **금지**: 내부 NLB DNS(`aws_lb.int_nlb.dns_name`) / was_tg 엔드포인트로 forward → 프록시가 was_tg 등록 후 NLB로 보내면 **프록시→NLB→was_tg→프록시 무한 루프**. (⑲로 실 WAS를 TG에서 빼도 인스턴스는 살아 IP:8080 직접 도달 — was_sg가 web_private CIDR 허용.)
  - 헬스 경로: `/actuator/health/readiness` (기존 mitm_lab 주석).

## 제외 (was_tg 본선이라 불필요)

- 멘토형: A5(인스턴스 프로파일) · B2(`ec2:RunInstances`+`iam:PassRole`) — 프록시는 §B 사전 프로비저닝 사용.
- B4(web_tg 경로 `mitm_node_sg→web_sg:80`) — was_tg만 쓰므로 불필요.
- 외부 C2 전송 · 실제 반출 — **구현하지 않음**(finding 레벨).

## 완료 기준

| 토글 | 결과 |
|---|---|
| `enable_mitm_lab=false` | mitm·r2 모두 0 (기존 동작 불변) |
| `mitm=true` · `design1=false` | 기존 §A/§B + B3의 TG/NODE env 생성, r2만 0 (base MITM 유지) |
| `mitm=true` · `design1=true` | 추가로 A1–A4 · B1 · R2_PARAM_NAME 생성 |

## 인프라 팀 체크리스트 (apply 전)

| # | 확인 |
|---|---|
| 1 | `count=local.r2_count`는 A1–A4·B1만. Lambda count는 `mitm_count` 유지 |
| 2 | r2 리소스 참조는 전부 `[0]` (또는 `[*]`+`one()`) |
| 3 | B3 merge로 R2_PARAM만 조건부(카운트-세이프) |
| 4 | C4 user_data = **WAS private IP**, NLB DNS/TG 엔드포인트 금지 |
| 5 | A4 Resource = `aws_cloudtrail.main.arn` / `aws_s3_bucket.cloudtrail.arn` |
| 6 | B1 kms `ViaService=ssm` 세트 |
| 7 | 핸들러·AMI·역프록시는 팀 산출물(기존 TF precondition 유지) |
