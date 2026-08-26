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
  default = "saferookids-media-bucket-2026"
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
# 제약: 8~128 자, / " @ 와 공백 사용 불가 (RDS Oracle).
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