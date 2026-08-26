# ==========================================
# 4. Storage (S3)
# ==========================================

resource "aws_s3_bucket" "media" {
  bucket = var.s3_bucket_name
}

resource "aws_s3_bucket_versioning" "media_ver" {
  bucket = aws_s3_bucket.media.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media_enc" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 퍼블릭 액세스 차단.
# 계정 수준 기본값이 켜져 있더라도 그건 콘솔에서 누구나 끌 수 있는 설정이라,
# 버킷 자체에 코드로 못 박아 둔다. 4 개 모두 true 여야 의미가 있다.
#   block_public_acls       : 퍼블릭 ACL 을 새로 붙이는 것을 거부
#   ignore_public_acls      : 이미 붙어 있는 퍼블릭 ACL 을 무시
#   block_public_policy     : 퍼블릭을 허용하는 버킷 정책 등록을 거부
#   restrict_public_buckets : 퍼블릭 정책이 있어도 익명 접근을 차단
#
# 아래 media_tls_only 정책은 Principal = "*" 이지만 Effect 가 Deny 이므로
# "퍼블릭 정책" 으로 판정되지 않는다. block_public_policy 와 충돌하지 않음.
resource "aws_s3_bucket_public_access_block" "media" {
  bucket = aws_s3_bucket.media.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 전송 암호화 강제: HTTP(비 TLS) 요청은 거부한다.
# S3 는 기본적으로 HTTP 도 받으므로 정책으로 막지 않으면 평문 전송이 가능하다.
resource "aws_s3_bucket_policy" "media_tls_only" {
  bucket = aws_s3_bucket.media.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.media.arn,
        "${aws_s3_bucket.media.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
