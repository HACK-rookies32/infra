# ============================================================================
# member 테이블 월간 백업 (운영 기능)
# ----------------------------------------------------------------------------
# RDS Oracle 의 member 테이블을 월 1회 S3 로 백업한다.
#   - 트리거 : EventBridge 스케줄(기본 매월 1일 KST 09:00). 정상 운영에선 이 스케줄만
#              호출한다. 단 ec2_role(iam.tf)이 lambda:InvokeFunction 을 가져
#              EC2/탈취 자격이 수동 호출도 할 수 있다(iam.tf 의 lambda_deploy 정책).
#   - 출력   : s3://<cloudtrail 버킷>/db-backup/  (observability.tf 의 expire-db-backup
#              라이프사이클이 3년 보관 후 만료. 로그는 AWSLogs/ 로 분리돼 서로 안 겹침)
#   - 접속   : VPC 부착 람다 → was_private 서브넷(NAT 경유) → rds_sg 1521.
#              RDS 비밀번호는 SSM(/kidhackapp/rds/password, SecureString)에서 읽는다.
#
#
# 게이팅: 전 리소스가 var.enable_member_backup(기본 false)로 count 게이팅된다.
#   핸들러 zip(var.member_backup_zip_path)은 팀 제공 — 미지정 시 precondition 실패.
# ============================================================================

locals {
  member_backup_count = var.enable_member_backup ? 1 : 0
}

# ----------------------------------------------------------------------------
# 네트워크 — 백업 람다 전용 SG (아웃바운드만)
# ----------------------------------------------------------------------------
# 인그레스 없음(람다가 연결을 시작). egress 는 Oracle 1521 + AWS API(SSM/KMS 는
# NAT, S3 는 게이트웨이 엔드포인트) 도달을 위해 전체 허용(리포 관례).
# rds_sg 쪽 1521 인그레스는 security_groups.tf 의 dynamic 블록이 이 SG 를 참조해 연다.
resource "aws_security_group" "member_backup_sg" {
  count  = local.member_backup_count
  name   = "kidhackapp-member-backup-lambda-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "kidhackapp-member-backup-lambda-sg" }
}

# ----------------------------------------------------------------------------
# IAM — 백업 람다 실행롤 (최소 권한)
# ----------------------------------------------------------------------------
resource "aws_iam_role" "member_backup_exec" {
  count = local.member_backup_count
  name  = "kidhackapp-member-backup-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs (람다 실행 로그).
resource "aws_iam_role_policy_attachment" "member_backup_basic" {
  count      = local.member_backup_count
  role       = aws_iam_role.member_backup_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC ENI 생성/삭제 (VPC 부착 람다 필수).
resource "aws_iam_role_policy_attachment" "member_backup_vpc" {
  count      = local.member_backup_count
  role       = aws_iam_role.member_backup_exec[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# 백업 고유 권한 — 딱 세 가지로 좁힌다.
#   1) RDS 비번 파라미터 1개만 GetParameter
#   2) SecureString 복호 — iam.tf 의 ssm_params 와 동일하게 ssm 경유 호출만
#   3) 백업 prefix(db-backup/)로만 PutObject. 읽기/삭제/나열은 주지 않는다(쓰기 전용).
resource "aws_iam_role_policy" "member_backup" {
  count = local.member_backup_count
  name  = "kidhackapp-member-backup-policy"
  role  = aws_iam_role.member_backup_exec[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadRdsPassword"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.db_password.arn
      },
      {
        Sid      = "DecryptSecureString"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      },
      {
        Sid      = "WriteBackupObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.cloudtrail.arn}/db-backup/*"
      }
    ]
  })
}

# ----------------------------------------------------------------------------
# Lambda 함수 — VPC 부착, 로컬 zip 배포
# ----------------------------------------------------------------------------
# 코드 zip 은 팀 제공(var.member_backup_zip_path). media 버킷을 거치지 않고
# filename 으로 직접 올려 R1 아티팩트 오염 경로를 없앤다(파일 상단 주석).
# source_code_hash 로 zip 이 바뀌면 재배포되게 한다.
resource "aws_lambda_function" "member_backup" {
  count         = local.member_backup_count
  function_name = "kidhackapp-member-backup"
  role          = aws_iam_role.member_backup_exec[0].arn
  filename      = var.member_backup_zip_path
  handler       = var.member_backup_handler
  runtime       = var.member_backup_runtime
  timeout       = 300
  memory_size   = 256

  source_code_hash = var.member_backup_zip_path != "" ? filebase64sha256(var.member_backup_zip_path) : null

  vpc_config {
    subnet_ids         = [aws_subnet.was_private_2a.id, aws_subnet.was_private_2c.id]
    security_group_ids = [aws_security_group.member_backup_sg[0].id]
  }

  # 비밀 값은 넣지 않는다 — 비번은 런타임에 SSM 에서 읽는다. 여기엔 접속 좌표만.
  environment {
    variables = {
      DB_HOST           = aws_db_instance.oracle.address
      DB_PORT           = "1521"
      DB_SID            = var.oracle_db_name
      DB_USER           = var.db_username
      DB_PASSWORD_PARAM = aws_ssm_parameter.db_password.name
      BACKUP_BUCKET     = aws_s3_bucket.cloudtrail.id
      BACKUP_PREFIX     = "db-backup/"
    }
  }

  lifecycle {
    precondition {
      condition     = var.member_backup_zip_path != ""
      error_message = "enable_member_backup=true 이면 var.member_backup_zip_path(백업 핸들러 zip 경로)를 지정해야 합니다."
    }
  }

  tags = { Name = "kidhackapp-member-backup" }
}

# ----------------------------------------------------------------------------
# EventBridge — 월간 트리거
# ----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "member_backup_monthly" {
  count               = local.member_backup_count
  name                = "kidhackapp-member-backup-monthly"
  description         = "매월 1일 member 테이블 백업 트리거"
  schedule_expression = var.member_backup_schedule
}

resource "aws_cloudwatch_event_target" "member_backup" {
  count     = local.member_backup_count
  rule      = aws_cloudwatch_event_rule.member_backup_monthly[0].name
  target_id = "member-backup-lambda"
  arn       = aws_lambda_function.member_backup[0].arn
}

# 리소스 기반 정책: events.amazonaws.com 이 이 규칙(source_arn)으로만 호출하게 한정한다.
# 단 같은 계정의 IAM 아이덴티티는 리소스 정책 없이도 호출할 수 있어, lambda:InvokeFunction
# 을 가진 ec2_role(iam.tf 의 lambda_deploy)도 이 람다를 부를 수 있다.
resource "aws_lambda_permission" "member_backup_events" {
  count         = local.member_backup_count
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.member_backup[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.member_backup_monthly[0].arn
}
