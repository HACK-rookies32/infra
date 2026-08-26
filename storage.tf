# ==========================================
# 4. Storage (S3)
# ==========================================

# force_destroy = true 가 없으면 destroy 가 BucketNotEmpty 로 실패한다.
# 버저닝이 켜져 있어서 콘솔에서 파일을 지워도 삭제 마커와 이전 버전이 남기 때문에,
# 손으로 비우는 것으로는 해결되지 않는다. 이 옵션이 이전 버전까지 전부 지운다.
#
# ⚠️ 반대급부: destroy 시 버킷 안의 모든 객체가 사라진다.
#    지금은 artifacts/ (dist.tar.gz, jar) 뿐이라 재업로드하면 그만이지만,
#    사용자 업로드 파일이 같은 버킷에 쌓이기 시작하면 그것까지 함께 날아간다.
#    그 시점에는 버킷을 둘로 나누는 것이 맞다:
#      - artifacts 버킷 : force_destroy = true (지금 이 설정)
#      - media 버킷     : 사용자 데이터. prevent_destroy 또는 Terraform 밖으로
resource "aws_s3_bucket" "media" {
  bucket        = var.s3_bucket_name
  force_destroy = true
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

# ==========================================
# CORS — 브라우저에서 S3 로 직접 업로드하기 위한 설정
# ==========================================
# 큰 파일을 WAS 로 보내지 않고 presigned URL 로 브라우저 -> S3 직접 전송하는 구조를
# 전제로 한다. 이때 요청이 서비스 도메인이 아니라 S3 오리진으로 나가므로
# preflight(OPTIONS)가 발생하고, 이 설정이 없으면 거기서 막힌다.
#
# DEPLOY.md 3 장에 "상대 경로(/api)를 쓰면 CORS 가 아예 발생하지 않는다" 고 적혀 있는데,
# 그건 Nginx 가 /api/ 를 프록시해서 동일 오리진이기 때문이다.
# S3 직접 업로드는 그 전제가 깨지는 유일한 경로다.
#
# presigned URL 은 "서명된 요청" 이지 익명 접근이 아니다. 따라서 위
# public_access_block 4 개를 전부 켜둔 채로 정상 동작한다. 끌 필요 없다.
# 마찬가지로 media_tls_only 정책과도 충돌하지 않는다 (presigned 는 https 로 생성됨).

locals {
  # 도메인 유무로 분기하는 방식은 compute.tf 의 리스너, dns.tf 와 동일하다.
  # 도메인이 없으면 ALB DNS 로 접속하게 되므로 그쪽을 오리진으로 잡는다.
  #
  # 로컬 개발(vite dev server)에서 업로드를 테스트하려면 "http://localhost:5173" 을
  # 임시로 추가할 것. 운영 오리진에 상시로 두지는 말 것.
  media_cors_origins = var.domain_name != "" ? [
    "https://${var.domain_name}",
    "https://www.${var.domain_name}",
    ] : [
    "http://${aws_lb.ext_alb.dns_name}",
  ]
}

resource "aws_s3_bucket_cors_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  cors_rule {
    allowed_origins = local.media_cors_origins

    # PUT      : presigned 업로드
    # GET/HEAD : 다운로드, 업로드 후 존재 확인
    # 나중에 presigned POST(content-length-range 로 업로드 크기 제한)로 바꾸면 "POST" 추가.
    allowed_methods = ["PUT", "GET", "HEAD"]

    # presigned PUT 은 Content-Type 등을 서명에 포함해 함께 보내므로 열어둔다.
    allowed_headers = ["*"]

    # 업로드 성공 후 클라이언트가 ETag 를 읽어 WAS 완료 콜백에 실어 보낼 수 있게 한다.
    # (노출하지 않으면 브라우저가 응답 헤더를 스크립트에 넘겨주지 않는다)
    expose_headers = ["ETag"]

    # preflight 결과 캐시. 매 업로드마다 OPTIONS 가 한 번씩 더 나가는 것을 막는다.
    max_age_seconds = 3000
  }
}
