# ==========================================
# 9. DNS (Route 53) & TLS (ACM)
# ==========================================
#
# var.domain_name 이 비어 있으면 이 파일의 리소스는 하나도 생성되지 않고,
# ALB 는 HTTP 80 만 수신한다. 값이 있으면 인증서 발급 -> 검증 -> 443 리스너 ->
# Alias 레코드까지 한 번의 apply 로 구성된다.
#
# ------------------------------------------------------------------
# 사전 조건 (계정당 최초 1 회, Terraform 밖에서)
#
#   1) Route 53 호스팅 존이 존재할 것.
#      현재 계정에는 이미 있다: team1domain.store / Z0982309EXS2BF34ZT68
#   2) 그 존의 NS 4 개를 가비아 > 네임서버 설정에 등록할 것.
#      확인: aws route53 get-hosted-zone --id <ZONE_ID> \
#              --query "DelegationSet.NameServers"
#
# 이 두 가지만 맞으면 이후 destroy/apply 를 몇 번 반복하든
# 가비아를 다시 건드릴 일이 없다. 존을 resource 가 아니라 data 로 둔 이유다.
# ------------------------------------------------------------------

locals {
  dns_enabled = var.domain_name != "" ? 1 : 0

  # 인증서에 담을 도메인. 키가 plan 시점에 확정되어야 하므로
  # ACM 응답이 아니라 변수에서 만든다.
  cert_domains = var.domain_name != "" ? [
    var.domain_name,
    "www.${var.domain_name}",
  ] : []
}

# 호스팅 존은 Terraform 이 "만들지 않고 조회만" 한다. 이유가 중요하다.
#
# Route 53 은 존을 생성할 때마다 NS 4 개를 무작위로 새로 배정한다. 따라서
# 존을 resource 로 관리하면 destroy/apply 를 할 때마다 NS 가 바뀌고,
# 그때마다 가비아에서 네임서버를 손으로 다시 설정해야 한다.
# (실제로 이 프로젝트에서 그 일이 이미 한 번 발생했다)
#
# 존을 Terraform 밖에 두면 NS 가 영구 고정되어, 가비아 설정은 최초 1 회로 끝난다.
# 존 안의 레코드(ACM 검증, Alias)는 아래에서 Terraform 이 정상적으로 관리한다.
#
# 존이 없는 계정에서 처음 시작한다면 한 번만 만들어 두면 된다:
#   aws route53 create-hosted-zone --name team1domain.store \
#     --caller-reference $(date +%s)
data "aws_route53_zone" "main" {
  count        = local.dns_enabled
  name         = var.domain_name
  private_zone = false
}

# ACM 인증서. ALB 와 같은 리전(ap-northeast-2)에 있어야 한다.
resource "aws_acm_certificate" "cert" {
  count                     = local.dns_enabled
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  # 인증서 교체 시 443 리스너가 끊기지 않도록 새 것을 먼저 만든다.
  lifecycle {
    create_before_destroy = true
  }
}

# ACM 이 요구하는 검증용 CNAME 을 Route 53 에 자동 등록한다.
# 이 자동화가 "인증서 발급받아서 수동으로 443 전환" 을 없애는 핵심.
resource "aws_route53_record" "cert_validation" {
  for_each = toset(local.cert_domains)

  zone_id         = data.aws_route53_zone.main[0].zone_id
  allow_overwrite = true
  ttl             = 60

  name = one([
    for dvo in aws_acm_certificate.cert[0].domain_validation_options :
    dvo.resource_record_name if dvo.domain_name == each.key
  ])
  type = one([
    for dvo in aws_acm_certificate.cert[0].domain_validation_options :
    dvo.resource_record_type if dvo.domain_name == each.key
  ])
  records = [one([
    for dvo in aws_acm_certificate.cert[0].domain_validation_options :
    dvo.resource_record_value if dvo.domain_name == each.key
  ])]
}

# 발급이 끝날 때까지 apply 를 붙잡는다.
# 이 리소스 덕분에 443 리스너가 "인증서가 준비된 뒤에" 만들어지는 순서가
# 사람 개입 없이 보장된다.
resource "aws_acm_certificate_validation" "cert" {
  count                   = local.dns_enabled
  certificate_arn         = aws_acm_certificate.cert[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  timeouts {
    create = "60m"
  }
}

# 도메인 -> ALB.
# ALB 는 IP 가 고정이 아니라 A 레코드를 쓸 수 없고, 루트 도메인에는 CNAME 이
# 금지되어 있다. Route 53 의 Alias 레코드만이 둘 다를 해결한다.
# (가비아 DNS 를 그대로 썼다면 www 서브도메인만 가능했을 것)
resource "aws_route53_record" "alias" {
  for_each = toset(local.cert_domains)

  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = each.key
  type    = "A"

  alias {
    name                   = aws_lb.ext_alb.dns_name
    zone_id                = aws_lb.ext_alb.zone_id
    evaluate_target_health = true
  }
}
