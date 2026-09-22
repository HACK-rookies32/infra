variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "vpc_cidr" {
  type    = string
  default = "192.168.0.0/16"
}

variable "s3_bucket_name" {
  type    = string
  default = "kidhackapp-media-bucket-2026"
}

variable "db_username" {
  type    = string
  default = "adminexample"
}

# RDS Oracle 마스터 비밀번호.
#
# default 를 두지 않는다. 기본값을 넣으면 그 값이 코드에 평문으로 남아 그대로
# 커밋되고, 리포지토리를 읽을 수 있는 사람 전부가 운영 DB 비밀번호를 알게 된다.
# default 가 없으면 값을 주지 않았을 때 terraform 이 plan 단계에서 멈추므로,
# "설정을 깜빡한 채 배포되는" 경로 자체가 사라진다.
#
# 값은 환경변수로 주입한다. tfvars 파일은 실수로 커밋될 여지가 있어 쓰지 않는다.
#   로컬 : export TF_VAR_db_password='...'
#   CI   : GitHub Secrets -> env: TF_VAR_db_password: ${{ secrets.DB_PASSWORD }}
#
# 제약: 8~30 자. / " @ & ' 와 공백 사용 불가.
#
# ⚠️ 길이 상한이 다른 엔진(PostgreSQL 등 128 자)보다 훨씬 짧다. RDS Oracle 만
#    8~30 자다. 또 Oracle 은 & 와 작은따옴표까지 추가로 막는다.
#    이 값은 /opt/app/app.env 에도 그대로 들어가는데, & 는 거기서도 위험하다
#    (SPRING_DATA_MONGODB_URI 의 쿼리스트링 구분자와 같은 문자다).
#
# 영숫자 + ! # $ % ^ * ( ) - _ = + 범위로 20 자 내외면 두 DB 모두 안전하다.
variable "db_password" {
  type      = string
  sensitive = true
}

# destroy 시 최종 스냅샷을 남길지 여부.
#
# false (기본, 점검/개발용)
#   : 스냅샷 없이 빠르게 destroy 된다. destroy/apply 를 몇 번 반복해도 문제없다.
# true (최종 제출/운영 전환 시)
#   : destroy 전에 최종 스냅샷을 남긴다. 단 스냅샷 이름은 계정 내 유일해야 하므로,
#     true 로 두고 destroy 를 두 번 하면 이름 충돌로 실패한다.
#     그때는 기존 스냅샷을 지우거나 아래 리소스의 이름을 바꿀 것.
#
# 자동 백업(backup_retention_period)은 이 값과 무관하게 항상 켜져 있다.
variable "keep_final_snapshot" {
  type    = bool
  default = false
}

# 서비스 도메인. 현재 값은 Route 53 에서 직접 등록한 도메인이다.
#
# Route 53 Domains 로 등록하면 호스팅 존이 자동 생성되고 도메인의 네임서버도
# 그 존으로 자동 연결된다. 즉 외부 등록기관(가비아 등)에서 샀을 때 필요했던
# "NS 4 개를 등록기관에 손으로 입력" 단계가 아예 없다.
#
# 빈 문자열이면 Route 53 / ACM / 443 리스너가 아예 생성되지 않고 HTTP 80 만 뜬다.
# 값을 주면 호스팅 존 조회 -> 인증서 -> DNS 검증 -> 443 리스너 -> Alias 레코드가
# 한 번의 apply 로 전부 구성된다. 자세한 절차는 dns.tf 상단 주석 참고.
variable "domain_name" {
  type    = string
  default = "kidhackapp.com"
}

# Oracle SID. WAS 의 JDBC URL 에도 이 값이 그대로 들어간다. 8자 이하.
variable "oracle_db_name" {
  type    = string
  default = "ORCL"
}

# AMI 고정용.
# 빈 문자열이면 최신 Ubuntu 22.04 를 조회하는데, Canonical 이 새 이미지를 내면
# AMI ID 가 바뀌어 EC2 4 대가 전부 재생성된다. 시연/발표 전에는
# `terraform output ubuntu_ami_id` 값을 여기에 박아 고정할 것.
variable "ubuntu_ami_id" {
  type    = string
  default = ""
}

# Docker Engine 버전 핀 (WEB / WAS 4대 공통, 상시 적용).
#
# 예전에는 공식 저장소의 최신(unpinned) docker-ce 를 깔았다. 지금은 이 버전으로
# 고정한다. 모의해킹 실습의 Docker AuthZ 플러그인(enable_docker_authz_lab)이
# 특정 데몬 API 세대를 전제로 하고, latest 로 두면 Docker 가 새 버전을 내는 순간
# 플러그인/정책 동작이 조용히 어긋날 수 있기 때문이다.
#
# ⚠️ 이 값을 바꾸면 user_data 가 바뀌어 EC2 4대가 전부 재생성된다
#    (compute.tf 의 user_data_replace_on_change = true).
#
# ⚠️ apt 의 "정확한" 패키지 버전 문자열(epoch·suffix 포함, 예:
#    5:29.3.0-1~ubuntu.22.04~jammy)은 릴리스마다 바뀐다. 부팅 스크립트는 이 값을
#    apt-cache madison 결과에서 찾아 매칭하므로, 여기에는 x.y.z 만 적으면 된다.
#    레포에서 이미 내려간 버전을 적으면 부팅이 즉시 FATAL 로 중단된다.
variable "docker_version" {
  type    = string
  default = "29.3.0"
}

# ------------------------------------------------------------------
# Docker Hub (WEB / WAS CI/CD)
# ------------------------------------------------------------------

# WEB 이미지 경로. "<사용자명>/<저장소명>" 형식.
# GitHub Actions 가 여기에 :latest 를 밀고, Watchtower 가 이걸 폴링한다.
# 워크플로의 IMAGE 값과 반드시 일치해야 한다. 어긋나면 CI 는 성공하는데
# 배포만 조용히 안 되고, 아무 에러도 나지 않는다.
variable "dockerhub_image" {
  type    = string
  default = "bulletbear/kidhack-web"
}

# WAS(백엔드) 이미지 경로. 위와 같은 규칙이다.
# backend 레포 .github/workflows/cd.yml 의 IMAGE 값과 일치해야 한다.
variable "was_image" {
  type    = string
  default = "jotriever/kidhack-was"
}

# ------------------------------------------------------------------
# Docker Hub 계정이 티어별로 다르다.
#
#   WEB : bulletbear/kidhack-web
#   WAS : jotriever/kidhack-was
#
# 두 개인 계정이고 조직(org)이 아니므로, 한쪽 자격증명으로 다른 쪽 private
# 저장소를 받을 수 없다. docker login 은 레지스트리(docker.io)당 한 계정만
# 유지되므로 한 인스턴스가 두 계정을 동시에 쓰는 것도 불가능하다.
#
# 다행히 WEB 과 WAS 는 서로 다른 EC2 라 충돌하지 않는다. 각 티어가 자기
# 계정으로 로그인하도록 사용자명과 토큰을 티어별로 나눠 둔다.
# ------------------------------------------------------------------

variable "dockerhub_username" {
  type    = string
  default = "bulletbear"
}

variable "was_dockerhub_username" {
  type    = string
  default = "jotriever"
}

# Docker Hub Personal Access Token.
#
# default 를 두지 않는 이유는 db_password 주석과 같다.
#   로컬 : export TF_VAR_dockerhub_token='dckr_pat_...'
#   CI   : GitHub Secrets -> env: TF_VAR_dockerhub_token: ${{ secrets.DOCKERHUB_PULL_TOKEN }}
#
# ⚠️ Read-only 권한으로 발급할 것.
#   EC2 는 pull 만 하면 되고 push 는 GitHub Actions 의 역할이다.
#   여기에 쓰기 권한을 주면 인스턴스가 뚫렸을 때 이미지를 덮어쓸 수 있게 된다.
#   즉 GitHub 에 넣는 토큰(Read & Write)과 반드시 다른 토큰이어야 한다.
#
# 대상 저장소가 private 이므로 이 값 없이는 WEB 이 이미지를 받지 못한다.
variable "dockerhub_token" {
  type      = string
  sensitive = true
}

# WAS 용 Docker Hub PAT. 위 dockerhub_token 과 계정이 다르므로 별도 값이다.
# 주의사항은 위와 동일하다 — Read-only 로 발급하고, backend 레포 GitHub
# Secrets 에 넣는 Read & Write 토큰과 반드시 다른 토큰이어야 한다.
#
#   로컬 : export TF_VAR_was_dockerhub_token='dckr_pat_...'
#   CI   : GitHub Secrets -> env: TF_VAR_was_dockerhub_token: ${{ secrets.WAS_DOCKERHUB_PULL_TOKEN }}
#
# 이 값 없이는 WAS 가 이미지를 받지 못하고 systemd 가 30 초마다 재시도만 한다.
variable "was_dockerhub_token" {
  type      = string
  sensitive = true
}

# Watchtower 이미지.
#
# ⚠️ containrrr/watchtower 를 쓰면 안 된다.
#   원본은 유지보수가 중단되어 Docker API 1.25 클라이언트로 고정되어 있는데,
#   Docker Engine 29 부터 최소 지원 API 가 1.40 으로 올라가면서 아예 통신이
#   되지 않는다. 컨테이너가 이 오류로 재시작만 반복한다:
#     "client version 1.25 is too old. Minimum supported API version is 1.40"
#   원본에는 이 문제를 고칠 패치가 나오지 않는다.
#
#   nickfedor/watchtower 는 활발히 유지보수되는 포크이며, 설정 환경변수와
#   컨테이너 라벨(com.centurylinklabs.watchtower.enable)이 원본과 동일해서
#   이미지 이름만 바꾸면 된다.
#
# 태그를 고정하는 이유: latest 로 두면 포크가 갱신될 때 또 조용히 깨질 수 있다.
# 올릴 때는 이 값을 명시적으로 올린다.
variable "watchtower_image" {
  type    = string
  default = "nickfedor/watchtower:1.21.2"
}

# Watchtower 가 Docker Hub 를 확인하는 주기(초).
#
# ⚠️ 짧게 두면 Docker Hub rate limit 에 걸린다.
#   Watchtower 는 폴링마다 매니페스트를 조회하고 Docker Hub 는 이를 pull 로
#   계산한다. WEB 2 대가 각자 폴링하므로 요청량은 두 배다.
#     60 초  -> 시간당 120 회 (무료 계정 한도 초과)
#     300 초 -> 시간당 24 회  (안전)
#   push 후 최대 5 분 안에 반영된다. 더 빠르게 하려면 유료 플랜이 필요하다.
#
#   한도는 Docker 정책에 따라 바뀌므로 배포 전 현재 값을 확인할 것.
variable "watchtower_poll_interval" {
  type    = number
  default = 300
}

# Firebase 서비스 계정 키(JSON 전문).
#
# 이미지에 구워 넣지 않는 이유: Docker Hub 에 개인키가 박힌다. private
# 저장소라도 레지스트리 자격증명이 새면 키도 같이 샌다. 그래서 SSM 에
# 넣고 부팅 시 파일로 떨궈 컨테이너에 읽기 전용으로 마운트한다.
#
#   로컬 : export TF_VAR_firebase_credentials_json="$(cat firebase-service-account.json)"
#   CI   : GitHub Secrets -> env: TF_VAR_firebase_credentials_json: ${{ secrets.FIREBASE_KEY }}
#
# 기본값 "{}" 는 "키 없음" 을 뜻한다. SSM 파라미터는 빈 문자열을 허용하지
# 않아 자리표시자가 필요하다. 이 값이면 FirebaseConfig 가 IOException 을
# 잡아 warn 만 남기고 앱은 정상 기동한다(푸시 알림만 비활성).
variable "firebase_credentials_json" {
  type      = string
  sensitive = true
  default   = "{}"
}

variable "docdb_username" {
  type    = string
  default = "docdbadmin"
}

# DocumentDB 마스터 비밀번호. default 를 두지 않는 이유는 db_password 주석 참고.
#   로컬 : export TF_VAR_docdb_password='...'
#   CI   : GitHub Secrets -> env: TF_VAR_docdb_password: ${{ secrets.DOCDB_PASSWORD }}
#
# 제약: 8~100 자, / " @ 사용 불가 (DocumentDB).
variable "docdb_password" {
  type      = string
  sensitive = true
}

# EC2 호스트와 그 위의 컨테이너가 함께 쓸 타임존.
#
# 호스트는 timedatectl 로, 컨테이너는 TZ 환경변수와 /etc/localtime 마운트로
# 같은 값을 받는다(templates/*_user_data.sh.tftpl 참고). 한쪽만 바꾸면
# nginx access log / Spring Boot 로그 / journalctl 의 타임스탬프가 9 시간씩
# 어긋나 장애 시각을 맞춰 보기 어려워진다.
#
# ⚠️ 이건 "표시" 타임존일 뿐이다. DB 에 저장되는 값의 타임존은 별개 문제다.
#   Oracle 컬럼 타입과 앱의 시간대 처리가 따로 정해지며, 그쪽은 backend
#   레포의 application-prod.yml 소관이다.
#
# UTC 로 통일하고 싶으면 "UTC" 로 두면 된다. 인스턴스 교체가 필요한 값은
# 아니지만 user_data 가 바뀌므로 apply 시 EC2 4 대가 재생성된다
# (compute.tf 의 user_data_replace_on_change = true).
variable "timezone" {
  type    = string
  default = "Asia/Seoul"
}

# 배스천을 통해 WEB / WAS 에 SSH 로 붙을 때 쓸 키페어 "이름".
#
# 키페어 자체는 Terraform 이 만들지 않는다. 콘솔(또는 CLI)에서 미리 만들어 둔
# 것의 이름만 여기에 적는다. 이유는 두 가지다:
#   - tls_private_key 로 apply 때 생성하면 개인키 PEM 전문이 tfstate 에
#     평문으로 박힌다. 이 프로젝트는 backend 블록이 없어 state 가 로컬 파일로
#     남으므로 더 나쁘다.
#   - 배스천은 개발 기간에만 콘솔에서 띄웠다 지울 물건이라, 키페어까지
#     Terraform 이 쥐고 있으면 destroy 수명주기가 서로 얽힌다.
#
# ⚠️ 이 값을 바꾸면(빈 문자열 <-> 이름 포함) EC2 4 대가 전부 재생성된다.
#   key_name 은 aws_instance 의 ForceNew 속성이라 in-place 수정이 안 된다.
#   컨테이너가 다시 뜨고 프라이빗 IP 도 바뀌니 배포 타이밍을 잡고 적용할 것.
#
# ⚠️ 여기 적은 이름의 키페어가 실제로 존재하지 않으면 apply 가
#   InvalidKeyPair.NotFound 로 실패한다. 리전(var.aws_region)도 같아야 한다.
#
# 빈 문자열이면 키를 아예 붙이지 않는다(compute.tf 의 삼항 참고). 배스천을
# 걷어낸 뒤에는 다시 "" 로 되돌려 SSH 경로를 없애는 것을 기본으로 삼는다.
# 키 없이도 SSM Session Manager 로 붙을 수 있다(iam.tf 의 ssm_attach).
variable "ssh_key_name" {
  type    = string
  default = "kidhackapp-key"
}

# ============================================================================
# [모의해킹 실습] ELB confused-deputy MITM 랩 (mitm_lab.tf) 변수
#   토글 기반. 기본 OFF(미생성). ON 하려면 팀이 핸들러 zip / 노드 AMI 를 함께
#   제공해야 한다(각각 precondition 으로 강제). 랩 성격·체인·범위는 mitm_lab.tf
#   상단 주석 참고.
# ============================================================================

variable "enable_mitm_lab" {
  description = "ELB confused-deputy MITM 랩(§A Lambda/IAM + §B 수신노드/SG) 생성 토글. false 면 아무것도 생성하지 않음."
  type        = bool
  default     = false
}

variable "deputy_zip_path" {
  description = "kidhack-elb-deputy Lambda 핸들러 zip 경로(팀 제공). enable_mitm_lab=true 면 필수(mitm_lab.tf precondition)."
  type        = string
  default     = ""
}

variable "deputy_handler" {
  description = "Lambda 핸들러 진입점(런타임 언어에 맞출 것)."
  type        = string
  default     = "index.handler"
}

variable "deputy_runtime" {
  description = "Lambda 런타임."
  type        = string
  default     = "python3.12"
}

variable "mitm_node_ami" {
  description = "MITM 수신 노드 AMI(팀 제공 역프록시 이미지, 기존 플릿과 아키텍처 일치). enable_mitm_lab=true 면 필수(mitm_lab.tf precondition)."
  type        = string
  default     = ""
}

variable "mitm_node_instance_type" {
  description = "MITM 수신 노드 인스턴스 타입."
  type        = string
  default     = "t3.small"
}

# ============================================================================
# [모의해킹 실습] Docker AuthZ 플러그인 랩
#   토글 기반. 현재 기본 ON(테스트용) — 평상시/운영 전환 시엔 false 로 되돌릴 것.
#   ON 이면 WEB/WAS 4대 부팅 스크립트가 OPA AuthZ 플러그인을 설치하고
#   Docker 데몬(authorization-plugins)에 물린다.
#
#   왜 여기가 랩이 되나: 이 호스트에서 Docker 데몬 API 에 닿는 통로는 Watchtower 의
#   소켓 마운트(-v /var/run/docker.sock) 하나뿐이고(앱 컨테이너는 소켓을 안 문다),
#   "소켓 = 사실상 root" 다. AuthZ 플러그인은 그 데몬 API 호출을 Rego 정책으로
#   allow/deny 한다. 실습 대상은 이 소켓 노출과 그 위의 게이팅이다.
#
#   경계(mitm_lab 과 동일 철학): 인프라는 골격(버전 핀·플러그인 설치·daemon.json
#   배선·기본 거부(default deny) + Watchtower CI/CD 허용 베이스라인 정책)만 제공한다.
#   privileged/호스트 루트 마운트 차단은 이 베이스라인에 이미 들어 있으나, 플러그인
#   버전별 input 스키마(Method/Path/Body)·정책 경로 확정은 팀 몫이다 — 어긋나면 규칙이
#   조용히 fail-open 될 수 있다. 부팅 스크립트는 플러그인이 확실히 enabled 일 때만
#   daemon.json 을 건드려 락아웃을 피한다(templates/*_user_data.sh.tftpl 의 AuthZ 블록 주석 참고).
#
#   ⚠️ ON/OFF 를 바꾸면 user_data 가 바뀌어 EC2 4대가 재생성된다.
#   ⚠️ Docker 버전 핀(var.docker_version)은 이 토글과 무관하게 상시 적용된다.
# ============================================================================

variable "enable_docker_authz_lab" {
  description = "Docker AuthZ(OPA) 플러그인을 WEB/WAS 4대에 설치·배선하는 토글. false 면 부팅 스크립트가 AuthZ 블록을 아예 렌더링하지 않음."
  type        = bool
  default     = true
}

variable "opa_authz_plugin" {
  description = "설치할 OPA Docker authz 관리형 플러그인 참조(태그 포함). 플러그인 버전에 따라 정책 경로/마운트가 다르므로 팀이 확인할 것."
  type        = string
  default     = "openpolicyagent/opa-docker-authz-v2:0.9"
}
