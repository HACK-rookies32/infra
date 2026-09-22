# ==========================================
# 4. Storage (S3)
# ==========================================

# force_destroy = true 가 없으면 destroy 가 BucketNotEmpty 로 실패한다.
# 버저닝이 켜져 있어서 콘솔에서 파일을 지워도 삭제 마커와 이전 버전이 남기 때문에,
# 손으로 비우는 것으로는 해결되지 않는다. 이 옵션이 이전 버전까지 전부 지운다.
#
# ⚠️ 반대급부: destroy 시 버킷 안의 모든 객체가 사라진다.
#    이제 uploads/ 아래에 사용자 첨부가 실제로 쌓이므로(backend app.s3.prefix),
#    terraform destroy 는 게시글·문의 첨부를 전부 지우는 명령이 되었다.
#    라이프사이클도 버저닝도 이건 막아주지 못한다 — force_destroy 는 이전 버전까지
#    지우기 때문이다.
#
#    지금은 비용 때문에 환경을 통째로 내렸다 올리는 주기가 있어 이 설정을 유지한다.
#    상시 운영으로 넘어가면 버킷을 둘로 나눌 것:
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

# ==========================================
# 라이프사이클 — 지운 파일이 영원히 남지 않게 한다
# ==========================================
# 버저닝이 켜져 있으므로 앱이 DeleteObject 를 불러도 실제 데이터는 사라지지 않고
# "이전 버전" 으로 남는다. 규칙이 없으면 사용자가 지운 첨부가 전부 그대로 쌓이고
# 요금도 계속 나간다. 게시글/문의 삭제 시 앱이 첨부를 지우기 시작했으므로
# (backend FileStorageService#delete) 이 규칙이 짝으로 필요하다.
#
# 반대로 즉시 완전 삭제하지 않는 이유는 실수를 되돌릴 창을 남기기 위해서다.
# 백엔드의 게시글 삭제에는 작성자 검증이 없는 알려진 결함이 있어([VULN-11]),
# 30 일 안에는 이전 버전을 복원할 수 있어야 한다.
resource "aws_s3_bucket_lifecycle_configuration" "media" {
  bucket = aws_s3_bucket.media.id

  # 버저닝이 켜지기 전에 규칙이 붙으면 noncurrent_version_* 이 의미를 갖지 못한다.
  depends_on = [aws_s3_bucket_versioning.media_ver]

  # 지워진(또는 덮어써진) 이전 버전은 30 일 뒤 완전 삭제.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    # 프로바이더 v5 는 prefix 든 filter 든 하나를 반드시 요구한다.
    # 버킷 전체에 적용하려면 빈 filter 를 명시한다.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # 이전 버전이 모두 만료된 뒤 홀로 남은 삭제 마커를 치운다.
  # 남겨두면 ListObjects 결과만 느리게 만들고 아무 쓸모가 없다.
  rule {
    id     = "expire-delete-markers"
    status = "Enabled"
    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  # 끊긴 멀티파트 업로드 조각 정리.
  # 브라우저가 S3 로 직접 올리는 구조라 업로드가 중간에 끊기는 일이 늘어난다.
  # 이 조각들은 객체 목록에 보이지 않으면서 스토리지 요금은 그대로 나간다.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
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

# ==========================================
# 중요정보 공유용 프라이빗 버킷 (secure share)
# ==========================================
# media(사용자 첨부)와 완전히 분리된, 팀 내부 중요정보 공유 전용 비공개 버킷.
#
# ⚠️ 이 버킷은 ec2-role(iam.tf)에 "일부러" 연결하지 않는다.
#   앱 인스턴스 역할은 무인증 SSRF(GET /api/community/thumbnail)로 탈취되는 바로 그
#   롤이다(mitm_lab.tf 주석). 여기에 이 버킷 권한을 주면 중요정보가 그 체인으로
#   그대로 샌다. 접근은 사람/별도 IAM 주체가 콘솔·CLI 로 대역 밖에서 한다.
#   (그래서 CORS 도 없다 — 브라우저에서 직접 붙는 버킷이 아니다)
#
# ⚠️ media 와 달리 force_destroy = false 다. 중요정보라, 비어 있지 않으면 destroy 가
#   BucketNotEmpty 로 "일부러" 실패한다 — 환경을 통째로 내렸다 올리는 주기(storage.tf
#   상단 주석)에 이 버킷이 휩쓸려 지워지는 것을 막는 안전장치다. 정말 지우려면
#   버킷을 먼저 비우거나 이 값을 true 로 바꿀 것.
resource "aws_s3_bucket" "secure_share" {
  bucket        = var.secure_share_bucket_name
  force_destroy = false
}

# 퍼블릭 액세스 차단 4종 (media 와 동일. 위 media 블록 주석 참고).
resource "aws_s3_bucket_public_access_block" "secure_share" {
  bucket = aws_s3_bucket.secure_share.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 버저닝: 실수로 덮어쓰거나 지운 중요 파일을 되돌릴 수 있게 켠다.
resource "aws_s3_bucket_versioning" "secure_share" {
  bucket = aws_s3_bucket.secure_share.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 저장 암호화. 리포 관례대로 키 비용 없는 AES256(SSE-S3)을 쓴다.
# ⚠️ 오브젝트 단위 접근 추적/키 접근 통제가 필요하면 SSE-KMS(고객관리키)로 올릴 것.
#   그러면 오브젝트 접근이 CloudTrail 데이터이벤트 + KMS Decrypt 로그로 남고,
#   키 정책으로 "누가 복호할 수 있는가"까지 통제된다(observability.tf 와 맞물린다).
resource "aws_s3_bucket_server_side_encryption_configuration" "secure_share" {
  bucket = aws_s3_bucket.secure_share.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# 끊긴 멀티파트 업로드 조각 정리(순수 위생). 버전은 중요정보라 자동 만료하지 않는다.
resource "aws_s3_bucket_lifecycle_configuration" "secure_share" {
  bucket = aws_s3_bucket.secure_share.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# 전송 암호화 강제: HTTP(비 TLS) 요청 거부 (media_tls_only 와 동일 패턴).
# Effect=Deny 라 "퍼블릭 정책"으로 판정되지 않아 block_public_policy 와 충돌하지 않는다.
resource "aws_s3_bucket_policy" "secure_share_tls_only" {
  bucket = aws_s3_bucket.secure_share.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.secure_share.arn,
        "${aws_s3_bucket.secure_share.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
