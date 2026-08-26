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
  name        = "/saferookids/rds/password"
  description = "RDS Oracle master password"
  type        = "SecureString"
  value       = var.db_password
}

resource "aws_ssm_parameter" "docdb_password" {
  name        = "/saferookids/docdb/password"
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
  name        = "/saferookids/app/jwt-secret"
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
  name        = "/saferookids/dockerhub/token"
  description = "Docker Hub PAT (read-only) for pulling the WEB image"
  type        = "SecureString"
  value       = var.dockerhub_token
}

# WAS 이미지는 Docker Hub 계정이 달라(variables.tf 주석 참고) 토큰도 별개다.
# 파라미터를 나눠 두면 IAM 으로 티어별 접근을 좁힐 여지도 남는다.
resource "aws_ssm_parameter" "was_dockerhub_token" {
  name        = "/saferookids/dockerhub/was-token"
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
  name        = "/saferookids/app/firebase-key"
  description = "Firebase service account JSON for kidhack-backend"
  type        = "SecureString"
  value       = var.firebase_credentials_json
}
