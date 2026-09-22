# ==========================================
# 9. Observability (CloudTrail + CloudWatch)
# ==========================================
# 이 파일이 로깅/모니터링을 한곳에 모은다. 세 갈래다.
#   A. CloudTrail   : 계정의 API 콜(관리 이벤트) + S3(media)·Lambda 데이터 이벤트를
#                     전용 S3 버킷에 보관. CloudWatch Logs 연동/메트릭 알람은 두지 않는다
#                     (요구: "S3 보관만"). 사후 분석·포렌식용.
#   B. VPC Flow Logs: VPC 전체 ENI 의 트래픽 메타데이터를 CloudWatch Logs 로.
#                     프라이빗 서브넷 안에서 벌어지는 SSRF/측면이동/MITM 관측용.
#   C. EC2 Agent    : WEB/WAS 호스트·컨테이너 로그와 메모리/디스크 메트릭을
#                     CloudWatch Logs/Metrics 로. 부팅 스크립트(templates/*)에서
#                     설치·기동하고, 여기서는 로그그룹과 (좁힌) IAM 권한만 만든다.
#
# 알람/SNS 는 만들지 않는다(요구: "알람 없이 로깅만"). 나중에 켜려면 여기
# 로그그룹/트레일에 metric_filter + cloudwatch_metric_alarm + sns_topic 를 얹으면 된다.
#
# ⚠️ 비용 메모(이 리포는 destroy/apply 주기가 있어 비용에 민감하다)
#   - CloudTrail 관리 이벤트는 "계정 첫 트레일" 이라 기록 자체는 무료. S3 저장분만 과금.
#   - CloudTrail 데이터 이벤트(S3/Lambda)는 이벤트 건당 과금($0.10/10만건 수준).
#     이 랩은 트래픽이 적어 미미하지만, 업로드 폭주 시엔 늘 수 있다.
#   - Flow Logs / EC2 로그는 CloudWatch Logs 수집·저장분 과금. retention 변수로 조인다.

data "aws_caller_identity" "current" {}

locals {
  cloudtrail_name = "kidhackapp-trail"

  # 트레일 ARN 을 문자열로 구성한다. 버킷 정책의 aws:SourceArn 조건(confused-deputy
  # 방어)에 쓰는데, aws_cloudtrail.arn 을 직접 참조하면 "버킷 정책 → 트레일 → 버킷 정책"
  # 순환이 생긴다. 트레일 이름/리전/계정은 apply 전에 이미 정해지므로 직접 조립한다.
  trail_arn = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"

  # EC2 Agent 가 메트릭을 쌓을 네임스페이스. 아래 IAM 조건(PutMetricData 를 이
  # 네임스페이스로 한정)과 부팅 스크립트의 Agent config 가 같은 값을 써야 한다.
  cw_metrics_namespace = "KidhackApp/EC2"

  # WEB/WAS 호스트·컨테이너 로그를 담을 로그그룹. 티어 구분 없이 공유하고,
  # 스트림 이름에 "web-/was-<instance_id>" 를 넣어 인스턴스를 가른다
  # (Agent config 의 log_stream_name, templates/* 참고).
  ec2_log_groups = {
    userdata   = "/kidhackapp/ec2/user-data"  # /var/log/user-data.log — 부팅 스크립트 전체 로그
    syslog     = "/kidhackapp/ec2/syslog"     # /var/log/syslog       — 호스트 시스템 로그
    auth       = "/kidhackapp/ec2/auth"       # /var/log/auth.log     — SSH/sudo(보안 관측)
    containers = "/kidhackapp/ec2/containers" # /var/lib/docker/.../*-json.log — 앱 컨테이너 stdout
  }
}

# ----------------------------------------------------------------------------
# A. CloudTrail
# ----------------------------------------------------------------------------

# 로그 전용 S3 버킷. media 버킷과 분리한다 — 감사 로그와 사용자 데이터의
# 수명주기·접근권한·force_destroy 정책이 서로 다르기 때문이다.
resource "aws_s3_bucket" "cloudtrail" {
  bucket = var.cloudtrail_bucket_name

  # media 버킷과 같은 이유(storage.tf 주석). destroy/apply 주기가 있어 유지한다.
  # ⚠️ destroy 시 그때까지 쌓인 감사 로그가 전부 사라진다. 로그를 남겨야 하는
  #    시점(사고 조사 등)에는 이 값을 false 로 바꾸거나 버킷을 Terraform 밖으로 뺄 것.
  force_destroy = true
}

# 감사 로그 버킷은 절대 퍼블릭이 되면 안 된다. 4 개 모두 true (storage.tf 주석 참고).
resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 저장 암호화(SSE-S3). CloudTrail 은 SSE-S3 든 SSE-KMS 든 쓸 수 있는데,
# media 버킷과 같은 AES256(키 비용 없음)으로 맞춘다.
resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 로그 보관 기간. 감사 로그가 무한정 쌓여 요금이 새지 않게 만료시킨다.
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "expire-trail-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = var.cloudtrail_log_retention_days
    }
  }
}

# CloudTrail 서비스가 이 버킷에 로그를 쓸 수 있게 하는 버킷 정책.
#   - GetBucketAcl : CloudTrail 이 쓰기 전에 소유권을 확인한다.
#   - PutObject    : AWSLogs/<account_id>/ 접두사에만, bucket-owner-full-control ACL 로.
# 두 문장 모두 aws:SourceArn 을 이 트레일 ARN 하나로 못박아 confused-deputy 를 막는다
# (다른 계정/트레일이 이 버킷에 로그를 흘리지 못하게).
# 마지막 문장은 media 버킷과 동일한 "비 TLS 요청 거부" 다.
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
        }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail.arn,
          "${aws_s3_bucket.cloudtrail.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# 트레일 본체.
#   multi_region + global_service_events : IAM/STS 같은 글로벌 서비스 이벤트와
#     타 리전 이벤트까지 한 트레일로 모은다. 공격 체인이 여러 서비스를 건드리므로
#     관측 누락을 없애는 쪽을 택했다(관리 이벤트라 추가 기록 비용 없음).
#   log_file_validation : 로그 파일 변조 탐지용 다이제스트를 함께 남긴다.
#
# data_resource 로 데이터 이벤트를 좁게 건다:
#   - S3::Object  : media 버킷만. SSRF→자격탈취→S3 접근 체인의 오브젝트 레벨 기록.
#                   (트레일 자신이 쓰는 cloudtrail 버킷은 대상이 아니라 재귀/노이즈 없음)
#   - Lambda      : 계정의 모든 함수("arn:aws:lambda"). MITM 랩 Lambda 는 토글로
#                   생겼다 사라지므로 특정 ARN 대신 전체로 걸어야 켜질 때 자동 포함된다.
resource "aws_cloudtrail" "main" {
  name                          = local.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.media.arn}/"]
    }
    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"]
    }
  }

  # 버킷 정책이 먼저 붙어 있지 않으면 트레일 생성이 권한 검증에서 실패한다.
  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ----------------------------------------------------------------------------
# B. VPC Flow Logs → CloudWatch Logs
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/kidhackapp/vpc/flow-logs"
  retention_in_days = var.flow_log_retention_days
}

# Flow Logs 전달 서비스가 위 로그그룹에 쓸 수 있게 하는 롤.
resource "aws_iam_role" "vpc_flow" {
  name = "kidhackapp-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow" {
  name = "kidhackapp-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
    }]
  })
}

# VPC 전체 ENI 의 모든 방향(ALL) 트래픽을 기록한다. 서브넷별로 나누지 않고
# vpc_id 하나로 걸면 web/was/db·ALB·NLB·NAT·Lambda ENI 까지 자동 포함된다.
resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  iam_role_arn             = aws_iam_role.vpc_flow.arn
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.vpc_flow.arn
  max_aggregation_interval = 60 # 1분 집계(기본 600초보다 촘촘히 — 랩 관측용)

  tags = { Name = "kidhackapp-vpc-flow-log" }
}

# ----------------------------------------------------------------------------
# C. EC2 CloudWatch Agent — SSM State Manager 로 설치·설정 (user_data 밖)
#
# ⚠️ 왜 user_data 가 아니라 SSM 인가
#   WAS 부팅 스크립트는 AuthZ 랩(기본 ON)까지 렌더링하면 base64gzip 후 이미
#   ~16.1KB 로 EC2 user_data 상한(16KiB=16384B)에 거의 붙어 있다(남는 여유 ~288B).
#   Agent 설치·config 를 user_data 에 인라인하면 그 선을 넘어 apply 가
#     expected length of user_data to be in the range (0 - 16384)
#   로 실패한다(실측: WAS 17,652B). 그래서 Agent 는 user_data 를 건드리지 않고
#   SSM 으로 붙인다. 덤: user_data 가 안 바뀌니 이 기능으로 EC2 가 재생성되지 않는다.
#
# 구성:
#   1) 로그그룹 4 개(아래) + 좁힌 IAM.
#   2) Agent config(비밀 아님) 를 SSM Parameter(String)에 둔다.
#   3) 어소시에이션 2 개로 App=kidhackapp 태그(compute.tf)를 대상으로:
#        install   : AWS-ConfigureAWSPackage 로 CloudWatch Agent 패키지 설치
#        configure : AmazonCloudWatch-ManageAgent 로 위 SSM config 를 물려 기동
#   var.enable_cloudwatch_agent=false 면 param/어소시에이션을 만들지 않는다
#   (로그그룹/IAM 은 남는다 — 비어 있어 무해).
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ec2" {
  for_each          = local.ec2_log_groups
  name              = each.value
  retention_in_days = var.ec2_log_retention_days
}

# Agent config(비밀 아님 — 로그그룹 이름·네임스페이스뿐). SSM Parameter 로 두고
# 어소시에이션이 인스턴스에 물린다.
#   $${aws:InstanceId} : jsonencode 가 ${aws:InstanceId} 로 렌더링 → Agent 가
#     런타임에 인스턴스 ID 로 치환하는 메트릭 차원.
#   {instance_id}       : Agent 의 로그 스트림 치환자(인스턴스별 스트림).
#     티어(web/was) 구분은 인스턴스의 Name 태그로 본다(스트림엔 넣지 않는다).
#   앱 로그는 컨테이너 stdout→Docker json-file 이라 /var/lib/docker/.../*-json.log 를
#   tail 한다(각 줄이 {"log":...} JSON 래핑). log-driver 를 awslogs 로 바꾸지 않는 건
#   로컬 docker logs·json-file 로테이션·AuthZ 랩 배선을 안 깨기 위해서다.
resource "aws_ssm_parameter" "cw_agent_config" {
  count = var.enable_cloudwatch_agent ? 1 : 0
  name  = "/kidhackapp/cloudwatch-agent/config"
  type  = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace         = local.cw_metrics_namespace
      append_dimensions = { InstanceId = "$${aws:InstanceId}" }
      metrics_collected = {
        mem  = { measurement = ["mem_used_percent"] }
        disk = { measurement = ["used_percent"], resources = ["/"] }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = "/var/log/user-data.log"
              log_group_name  = aws_cloudwatch_log_group.ec2["userdata"].name
              log_stream_name = "{instance_id}"
            },
            {
              file_path       = "/var/log/syslog"
              log_group_name  = aws_cloudwatch_log_group.ec2["syslog"].name
              log_stream_name = "{instance_id}"
            },
            {
              file_path       = "/var/log/auth.log"
              log_group_name  = aws_cloudwatch_log_group.ec2["auth"].name
              log_stream_name = "{instance_id}"
            },
            {
              file_path       = "/var/lib/docker/containers/*/*-json.log"
              log_group_name  = aws_cloudwatch_log_group.ec2["containers"].name
              log_stream_name = "{instance_id}"
            },
          ]
        }
      }
    }
  })
}

# 설치: AWS 관리형 문서로 CloudWatch Agent 패키지를 깐다.
# schedule_expression 을 둬서 State Manager 가 주기적으로 재수렴한다(새 인스턴스·드리프트).
resource "aws_ssm_association" "cw_agent_install" {
  count            = var.enable_cloudwatch_agent ? 1 : 0
  name             = "AWS-ConfigureAWSPackage"
  association_name = "kidhackapp-cw-agent-install"

  parameters = {
    action = "Install"
    name   = "AmazonCloudWatchAgent"
  }

  targets {
    key    = "tag:App"
    values = ["kidhackapp"]
  }

  schedule_expression = "rate(30 minutes)"
}

# 설정+기동: 위 SSM config 를 Agent 에 물리고 재시작한다.
# depends_on 으로 install 어소시에이션 뒤에 만들되, 실제 순서는 State Manager 의
# 주기 재수렴이 보장한다(첫 실행이 설치 전이라 실패해도 30 분 뒤 재실행에 성공).
#
# ⚠️ optionalRestart=yes + rate(30분) 이라 30 분마다 Agent 가 재시작된다.
#   재시작 시 로그는 체크포인트에서 이어져 유실이 없고 메트릭만 ≤60초 빈다.
#   자가치유(설치 레이스·config 드리프트 복구)를 위한 의도된 비용이다. 재시작이
#   싫으면 schedule_expression 을 지우면 되지만, 그러면 첫 실행 실패 시 새 인스턴스
#   등록/재apply 전까지 재수렴하지 않는다.
resource "aws_ssm_association" "cw_agent_configure" {
  count            = var.enable_cloudwatch_agent ? 1 : 0
  name             = "AmazonCloudWatch-ManageAgent"
  association_name = "kidhackapp-cw-agent-configure"

  parameters = {
    action                        = "configure"
    mode                          = "ec2"
    optionalConfigurationSource   = "ssm"
    optionalConfigurationLocation = aws_ssm_parameter.cw_agent_config[0].name
    optionalRestart               = "yes"
  }

  targets {
    key    = "tag:App"
    values = ["kidhackapp"]
  }

  schedule_expression = "rate(30 minutes)"
  depends_on          = [aws_ssm_association.cw_agent_install]
}

# Agent 전용 권한을 ec2_role(iam.tf)에 얹는다.
#
# ⚠️ 관리형 CloudWatchAgentServerPolicy 를 일부러 쓰지 않는다.
#   그 정책은 logs:* 를 리소스 "*" 로 열고 ssm:GetParameter 까지 "*" 로 준다.
#   이 ec2_role 은 SSRF(무인증 GET /api/community/thumbnail)로 자격이 탈취되는
#   바로 그 롤이다(mitm_lab.tf 주석). 관리형을 붙이면 탈취 자격의 사정거리가
#   "임의 로그그룹 조작 + 임의 SSM 파라미터 열람"까지 넓어진다.
#
#   그래서 딱 필요한 범위로 손수 좁힌다:
#     - logs 쓰기 : 위에서 만든 4 개 로그그룹으로 Resource 한정.
#     - PutMetricData : 리소스 지정이 불가능한 API 라 "*" 이지만, cloudwatch:namespace
#                       조건으로 KidhackApp/EC2 네임스페이스에만 쓰도록 묶는다.
#     - ssm:GetParameter : Agent 가 config 를 SSM 에서 읽으므로(위 어소시에이션) 필요.
#                       config 파라미터 "한 개"로만 Resource 를 좁힌다. 이 값은 비밀이
#                       아니라 로그그룹 이름뿐이라, 탈취 자격에 새어도 피해가 없다.
#   그래도 탈취 자격이 "우리 로그그룹에 가짜 로그를 넣어 증거를 흐리는" 정도는
#   가능해진다 — 로깅을 붙이며 감수하는 최소 확장이며, 관리형보다 훨씬 좁다.
resource "aws_iam_policy" "cloudwatch_agent" {
  name = "kidhackapp-cloudwatch-agent-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ShipLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = [for g in aws_cloudwatch_log_group.ec2 : "${g.arn}:*"]
      },
      {
        Sid      = "PutAgentMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = local.cw_metrics_namespace
          }
        }
      },
      {
        # config 파라미터 ARN 을 문자열로 구성한다(파라미터가 토글로 없어도 정책은
        # 유효). 없는 리소스에 GetParameter 를 허용하는 것은 무해하다.
        Sid      = "ReadAgentConfig"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/kidhackapp/cloudwatch-agent/config"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.cloudwatch_agent.arn
}
