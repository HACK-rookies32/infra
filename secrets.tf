# ==========================================
# 8. Secrets (SSM Parameter Store)
# ==========================================
# DB 비밀번호를 user_data 에 직접 넣으면 인스턴스 메타데이터로 평문 노출된다.
# (인스턴스 내 어떤 프로세스든 169.254.169.254 로 읽을 수 있음)
# SecureString 으로 저장하고 부팅 시 가져가게 한다.
#
# 주의: Terraform 으로 값을 넣는 이상 tfstate 에는 평문으로 남는다.
#       tfstate 를 S3 백엔드(암호화 활성화)로 옮기는 것이 다음 단계다.
#       Parameter Store 표준 파라미터는 무료.

resource "aws_ssm_parameter" "db_password" {
  name        = "/kidhackapp/rds/password"
  description = "RDS Oracle master password"
  type        = "SecureString"
  value       = var.db_password
}

resource "aws_ssm_parameter" "docdb_password" {
  name        = "/kidhackapp/docdb/password"
  description = "DocumentDB master password"
  type        = "SecureString"
  value       = var.docdb_password
}

# JWT 서명 키.
# application.yml 의 기본값은 "local-test-secret-key-change-in-production" 이라
# 그대로 두면 클라우드에서도 공개된 테스트 키로 토큰을 서명하게 된다.
# 사람이 값을 정하지 않도록 Terraform 이 생성해 SSM 에 넣고, WAS 가 부팅 시 읽어간다.
#
# special = false : 환경변수 파일(/opt/app/app.env)에 그대로 들어가므로
#                   따옴표나 $ 같은 문자로 파싱이 깨지지 않게 영숫자로 제한.
#                   길이 64 면 HS256(최소 256비트) 요구치를 충분히 넘는다.
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "jwt_secret" {
  name        = "/kidhackapp/app/jwt-secret"
  description = "JWT signing key for kidhack-backend"
  type        = "SecureString"
  value       = random_password.jwt_secret.result
}

# Docker Hub Personal Access Token (read-only).
# WEB 이 부팅 시 이걸로 docker login 한 뒤 이미지를 pull 하고, Watchtower 도
# 같은 자격증명(/root/.docker/config.json)으로 폴링한다.
#
# DB 비밀번호와 같은 이유로 user_data 에 넣지 않는다 — user_data 는 인스턴스
# 메타데이터로 평문 노출되기 때문이다.
resource "aws_ssm_parameter" "dockerhub_token" {
  name        = "/kidhackapp/dockerhub/token"
  description = "Docker Hub PAT (read-only) for pulling the WEB image"
  type        = "SecureString"
  value       = var.dockerhub_token
}

# WAS 이미지는 Docker Hub 계정이 달라(variables.tf 주석 참고) 토큰도 별개다.
# 파라미터를 나눠 두면 IAM 으로 티어별 접근을 좁힐 여지도 남는다.
resource "aws_ssm_parameter" "was_dockerhub_token" {
  name        = "/kidhackapp/dockerhub/was-token"
  description = "Docker Hub PAT (read-only) for pulling the WAS image"
  type        = "SecureString"
  value       = var.was_dockerhub_token
}

# Firebase 서비스 계정 키(JSON 전문).
#
# WAS 가 부팅 시 이 값을 /opt/app/firebase.json 으로 떨구고 컨테이너에
# 읽기 전용으로 마운트한다. 이미지에 구워 넣으면 Docker Hub 에 개인키가
# 박히므로 DB 비밀번호와 같은 경로로 다룬다.
#
# 값이 기본값("{}")이면 FirebaseConfig 가 초기화에 실패하고 warn 만 남긴다.
# 앱은 정상 기동하되 푸시 알림만 비활성 상태가 된다.
resource "aws_ssm_parameter" "firebase_key" {
  name        = "/kidhackapp/app/firebase-key"
  description = "Firebase service account JSON for kidhack-backend"
  type        = "SecureString"
  value       = var.firebase_credentials_json
}

# 카드번호 저장 필드암호화(AES-256) 키.
#
# 이 값이 없으면 FieldEncryptionKey 가 기동할 때마다 난수 키를 새로 만든다.
# 그런데 앱은 그 상태로도 정상 기동하므로 아무 에러가 나지 않고, WAS 2 대가
# 서로 다른 키를 들게 된다. 그러면 A 에 등록한 카드를 B 가 못 열어
# GET /wallet/cards 가 간헐적으로 500 이 나고, 재배포할 때마다 그때까지
# 저장된 카드가 통째로 복호 불가가 된다.
#
# jwt_secret 과 같은 이유로 사람이 값을 정하지 않는다. openssl 로 만들어
# 시크릿에 손으로 넣으면 (1) 32 바이트인지 사람이 검증해야 하고 (2) GitHub
# Secret 은 쓰기 전용이라 되읽을 수 없어, 다음에 prod yml 을 재생성할 때
# 키를 복원할 방법이 없다. 그 순간 기존 카드가 전부 날아간다.
#
# random_bytes 는 한 번 만들어지면 state 에 남고 이후 apply 에서 재생성되지
# 않는다. "키는 절대 바꾸지 않는다" 를 사람의 주의력이 아니라 도구로 강제하는
# 것이 이 리소스의 요점이다. 값을 확인해야 하면 아래 SSM 파라미터를 읽는다:
# `aws ssm get-parameter --name /kidhackapp/app/card-storage-key --with-decryption`.
#
# ⚠️ 이 리소스를 지우거나 이름을 바꾸면 다음 apply 에서 새 키가 만들어진다.
#    그 시점에 저장돼 있던 카드는 전부 복호 불가가 된다.
resource "random_bytes" "card_storage_key" {
  # AES-256. FieldEncryptionKey 는 32 바이트가 아니면 기동을 거부한다.
  length = 32
}

# 위 키를 이미지에 굽지 않고 SSM 으로 뺀다(jwt_secret·firebase_key 와 같은 경로).
#
# 예전에는 이 값을 outputs.tf 의 backend_prod_yml 이 그대로 렌더링해 이미지(jar)에
# 구웠고, 그러면 CD 가 남기는 sha- 롤백 태그 안에도 키가 영구히 남아 이미지를
# pull 할 수 있는 사람이 카드번호를 복호할 수 있었다. SecureString 으로 옮겨
# WAS 가 부팅 시에만 읽어 app.env(CARD_STORAGE_KEY)로 주입하게 한다.
#
# ⚠️ value 는 random_bytes 의 Base64 표현이다. FieldEncryptionKey 가
#    Base64 로 디코드해 32 바이트인지 검증하므로 .hex 가 아니라 .base64 여야 한다.
resource "aws_ssm_parameter" "card_storage_key" {
  name        = "/kidhackapp/app/card-storage-key"
  description = "Card field-encryption AES-256 key (Base64 32B) for kidhack-backend"
  type        = "SecureString"
  value       = random_bytes.card_storage_key.base64
}
