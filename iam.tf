# ==========================================
# 3. IAM Role (SSM + S3)
# ==========================================

resource "aws_iam_role" "ec2_role" {
  name = "kidhackapp-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "s3_access" {
  name = "kidhackapp-s3-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        # 게시글/문의를 지울 때 앱이 첨부 실물도 지운다.
        # 버저닝이 켜져 있어 이 권한으로는 삭제 마커만 남길 수 있고 이전 버전을
        # 영구 삭제할 수는 없다(그건 s3:DeleteObjectVersion 이며 주지 않는다).
        # 실제 정리는 storage.tf 의 라이프사이클 규칙이 한다.
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.media.arn,
        "${aws_s3_bucket.media.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_access.arn
}

# EC2 가 부팅 시 비밀 값을 SSM Parameter Store 에서 읽어가기 위한 권한.
# WAS 는 DB 비밀번호·JWT 키·Firebase 키를, WEB 과 WAS 는 각자의 Docker Hub
# 토큰을 읽는다(계정이 달라 토큰이 둘이다). 해당 파라미터 6 개로만 범위를 좁힌다.
#
# 두 티어가 인스턴스 프로파일을 공유하므로 WEB 도 WAS 토큰을 읽을 수 있다.
# 티어별로 역할을 나누면 더 좁힐 수 있으나, 지금은 같은 팀이 같은 이미지를
# 배포하는 구조라 역할 2 벌을 유지하는 비용이 더 크다고 보고 두지 않았다.
resource "aws_iam_policy" "ssm_params" {
  name = "kidhackapp-ssm-params-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          aws_ssm_parameter.db_password.arn,
          aws_ssm_parameter.docdb_password.arn,
          aws_ssm_parameter.jwt_secret.arn,
          aws_ssm_parameter.dockerhub_token.arn,
          aws_ssm_parameter.was_dockerhub_token.arn,
          aws_ssm_parameter.firebase_key.arn
        ]
      },
      {
        # SecureString 복호화용. AWS 관리형 키(alias/aws/ssm)를 쓰므로
        # 조건으로 SSM 경유 호출만 허용한다.
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_params_attach" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.ssm_params.arn
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "kidhackapp-ec2-profile"
  role = aws_iam_role.ec2_role.name
}
