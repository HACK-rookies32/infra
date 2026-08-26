# ==========================================
# 3. IAM Role (SSM + S3)
# ==========================================

resource "aws_iam_role" "ec2_role" {
  name = "saferookids-ec2-role"

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
  name = "saferookids-s3-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
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
# WAS 는 DB 비밀번호와 JWT 키를, WEB 은 Docker Hub 토큰을 읽는다.
# 해당 파라미터 4 개로만 범위를 좁힌다.
resource "aws_iam_policy" "ssm_params" {
  name = "saferookids-ssm-params-policy"
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
          aws_ssm_parameter.dockerhub_token.arn
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
  name = "saferookids-ec2-profile"
  role = aws_iam_role.ec2_role.name
}
