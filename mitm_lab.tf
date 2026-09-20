# ============================================================================
# [모의해킹 실습] ELB confused-deputy MITM 랩  (핸드오프 §A/§B)
# ----------------------------------------------------------------------------
# 성격/라벨: "ELB 한정 confused-deputy (Register/Deregister)".
#   - admin/AdministratorAccess 상승 아님. 타 롤 AssumeRole 아님. 승격용 임시키
#     반환 아님. 이 델타가 하는 일은 오직 web_tg/was_tg 라우팅 탈취(MITM)뿐이다.
#   - SSM at-rest 시크릿(JWT/DB/FCM)은 ec2-role 의 SSM 권한으로 Lambda 없이도
#     이미 획득 가능하다 → 이 Lambda 델타의 고유 가치는 "라이브 트래픽 관찰·
#     라우팅 제어"에 한정된다.
#
# 공격 체인(재사용하는 기존 취약점 → 이 델타):
#   무인증 GET /api/community/thumbnail (SSRF, WAS)
#     → IMDS(http_tokens=optional, hop=2)로 kidhackapp-ec2-role 임시자격 회수
#     → 그 자격으로 이 Lambda(kidhack-elb-deputy) InvokeFunction
#     → Lambda 가 "자기 실행롤"로 web_tg/was_tg 에 RegisterTargets(악성 노드)
#       + DeregisterTargets(정상 노드) → 트래픽이 악성 노드 경유 → 평문 관찰
#   평문 구간: 앱→ALB:443(ACM 종단)→web_tg:80→nginx→NLB:8080→was_tg→WAS:8080.
#   재암호화 없음 → web:80 / was:8080 이 평문. 앱 인증서 피닝은 ALB 종단까지만 유효.
#
# 범위: **인프라 골격 + 토글까지**. Lambda 핸들러(Register/Deregister 로직)와
#   수신 노드의 투명 역프록시(user_data)는 범위 밖 — 팀이 토글 ON 시점에 구현/제공한다.
#     - 핸들러 zip : var.deputy_zip_path (미지정 시 precondition 실패)
#     - 노드 AMI   : var.mitm_node_ami   (미지정 시 precondition 실패)
#
# 게이팅: 전 리소스가 var.enable_mitm_lab(기본 false)로 count 게이팅된다.
#   OFF(기본) = 아무것도 생성하지 않음(apply 해도 0 add). ON = §A·§B 전부 생성.
#   방어 전환/정리 = enable_mitm_lab=false 로 되돌리면 §A·§B 전부 destroy.
#   (count 리소스끼리의 참조는 [0] 인덱싱. web_tg/was_tg/ec2_role 등 상시 리소스는
#    count 가 아니므로 인덱싱 없이 참조한다.)
# ============================================================================

locals {
  mitm_count = var.enable_mitm_lab ? 1 : 0
}

# ----------------------------------------------------------------------------
# §A. Lambda + IAM   [VULN-CLOUD-LAMBDA-1] / [VULN-CLOUD-IAM-1]
# ----------------------------------------------------------------------------

# Lambda 실행 롤 — trust 는 lambda.amazonaws.com.
resource "aws_iam_role" "elb_deputy_exec" {
  count = local.mitm_count
  name  = "kidhack-elb-deputy-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 실행 롤 — 과권한 부분(랩의 핵심 미스컨피그).
#   쓰기: web_tg/was_tg 에 대한 Register/Deregister (Resource 를 이 두 TG 로 한정).
#   읽기: DescribeTargetHealth/DescribeTargetGroups 는 리소스 지정이 불가하여 "*".
# 정상 썸네일/앱 기능엔 전혀 필요 없는 권한이며, 이 롤이 곧 confused-deputy 의
# "특권"이다(탈취 자격이 Invoke 로 이 롤에 도달해 라우팅을 바꾼다).
resource "aws_iam_role_policy" "elb_deputy_targets" {
  count = local.mitm_count
  name  = "kidhack-elb-deputy-targets"
  role  = aws_iam_role.elb_deputy_exec[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ModifyTargets"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
        Resource = [aws_lb_target_group.was_tg.arn, aws_lb_target_group.web_tg.arn]
      },
      {
        Sid      = "DescribeTargets"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeTargetGroups"]
        Resource = "*"
      }
    ]
  })
}

# CloudWatch Logs (핸들러 디버깅/실행 로그).
resource "aws_iam_role_policy_attachment" "elb_deputy_basic" {
  count      = local.mitm_count
  role       = aws_iam_role.elb_deputy_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda 함수 — VPC 미부착(공격자가 프록시 밖에서 SigV4 Invoke 하는 전제).
#   zip/핸들러는 팀 제공(var.deputy_zip_path). 미지정 시 precondition 으로 실패시킨다
#   (빈 자리표시자 배포를 막고, "골격은 있으나 핸들러는 팀 몫"을 강제).
resource "aws_lambda_function" "elb_deputy" {
  count         = local.mitm_count
  function_name = "kidhack-elb-deputy"
  role          = aws_iam_role.elb_deputy_exec[0].arn
  filename      = var.deputy_zip_path
  handler       = var.deputy_handler
  runtime       = var.deputy_runtime

  lifecycle {
    precondition {
      condition     = var.deputy_zip_path != ""
      error_message = "enable_mitm_lab=true 이면 var.deputy_zip_path(팀 제공 핸들러 zip 경로)를 지정해야 합니다."
    }
  }
}

# ec2-role 에 부여하는 InvokeFunction — Resource 는 위 함수 ARN 하나로 한정.
#   리포 관례(iam.tf)대로 managed policy + attachment 짝을 쓴다.
#   이 한 줄이 "탈취한 ec2-role 자격 → Lambda 도달"의 다리다.
resource "aws_iam_policy" "ec2_invoke_deputy" {
  count = local.mitm_count
  name  = "kidhackapp-ec2-invoke-deputy-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.elb_deputy[0].arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_invoke_deputy_attach" {
  count      = local.mitm_count
  role       = aws_iam_role.ec2_role.name # iam.tf 의 공유 EC2 롤(WEB/WAS 4대 공유)
  policy_arn = aws_iam_policy.ec2_invoke_deputy[0].arn
}

# ----------------------------------------------------------------------------
# §B. MITM 수신 타깃 (악성 노드 + 전용 SG)
# ----------------------------------------------------------------------------

# 수신 노드 SG — 등록 대상 TG 에 따라 두 경로 모두 허용.
#   web_tg 로 등록될 경우: ext_alb_sg(ALB) 로부터 :80
#   was_tg 로 등록될 경우: web_private 대역(192.168.10/11.0/24) 로부터 :8080
#     (was_sg 와 동일 규칙 — WEB EC2 요청 + NLB 헬스체크가 모두 이 대역)
#   SSH(22)는 일부러 열지 않는다(관리 필요 시 SSM). egress 는 실 WAS 로 forward 위해 전체 허용.
resource "aws_security_group" "mitm_node_sg" {
  count  = local.mitm_count
  name   = "kidhackapp-mitm-node-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "web_tg path: from ALB :80"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.ext_alb_sg.id]
  }

  ingress {
    description = "was_tg path: from web_private :8080 (WEB EC2 fwd + NLB healthcheck)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["192.168.10.0/24", "192.168.11.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "kidhackapp-mitm-node-sg" }
}

# 수신 노드 — web_private_2a, target_type=instance(기본).
#   AMI 는 팀 제공(var.mitm_node_ami, 아키텍처 일치). 미지정 시 precondition 실패.
#   IMDS/루트볼륨은 기존 EC2 와 동일한 compute.tf locals 재사용.
#   IAM 인스턴스 프로파일은 일부러 미부착 — 관찰 노드가 또 다른 자격 탈취점이 되지
#   않게. 관리가 필요하면 SSM 프로파일을 별도로 붙인다.
#   user_data 는 플레이스홀더(투명 역프록시는 팀이 토글 ON 에서 구현).
resource "aws_instance" "mitm_node" {
  count                  = local.mitm_count
  ami                    = var.mitm_node_ami
  instance_type          = var.mitm_node_instance_type
  subnet_id              = aws_subnet.web_private_2a.id
  vpc_security_group_ids = [aws_security_group.mitm_node_sg[0].id]

  # SG 에서 22 를 막으므로 키를 붙여도 SSH 로는 못 붙는다. 플릿 일관성 위해 이름만 참조.
  key_name = var.ssh_key_name != "" ? var.ssh_key_name : null

  # [플레이스홀더] 팀이 투명 역프록시 구현: :8080(및/또는 :80) 수신 →
  #   헬스체크(web /healthz, was /actuator/health/readiness)에 200 응답 →
  #   실 WAS 로 forward 하며 사본 저장. 스텁 상태는 헬스체크를 통과하지 못하므로
  #   런타임은 반드시 "역프록시 기동 → 그 다음 Lambda 로 Register" 순서를 지킬 것.
  user_data = <<-EOT
    #!/bin/bash
    # [PLACEHOLDER] transparent reverse proxy — 팀 구현 예정
  EOT

  metadata_options {
    http_endpoint               = local.imds_v2.http_endpoint
    http_tokens                 = local.imds_v2.http_tokens
    http_put_response_hop_limit = local.imds_v2.http_put_response_hop_limit
  }

  root_block_device {
    volume_size = local.root_volume.size
    volume_type = local.root_volume.type
    encrypted   = local.root_volume.encrypted
  }

  lifecycle {
    precondition {
      condition     = var.mitm_node_ami != ""
      error_message = "enable_mitm_lab=true 이면 var.mitm_node_ami(팀 제공 역프록시 AMI, 아키텍처 일치)를 지정해야 합니다."
    }
  }

  tags = { Name = "kidhackapp-mitm-node" }
}

# ⚠️ 타깃그룹 사전 등록(aws_lb_target_group_attachment)을 일부러 두지 않는다.
#    TF 로 미리 등록하면 스텁 노드가 healthy 진입에 실패해 /api 가 흔들린다.
#    등록은 런타임에 Lambda 로: Register → DescribeTargetHealth 로 healthy 확인
#    → 정상 타깃 Deregister (순서가 반대면 공백 구간이 생긴다).
