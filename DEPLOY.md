# 로컬 → 클라우드 배포 가이드

H.A.C.K 자녀보호앱(careguard)을 로컬 개발 환경에서 AWS로 올릴 때 무엇이 바뀌는지와,
실제 배포 절차를 정리한 문서입니다.

- **서비스 주소**: https://kidhackapp.com
- **리전**: ap-northeast-2 (서울)
- **인프라 코드**: `3. 개발/infra`

> **배포는 `git push` 로 끝납니다.** WEB·WAS 모두 GitHub Actions 가 이미지를 만들어
> Docker Hub 에 올리고, EC2 의 Watchtower 가 그걸 감지해 컨테이너를 교체합니다.
> 사람이 S3 에 산출물을 올리거나 인스턴스에 접속할 일이 없습니다.

---

## 1. 한눈에 보는 구조 변화

로컬에서는 프로세스 3개가 한 노트북 안에서 `localhost`로 통신합니다.
클라우드에서는 같은 역할이 AZ 2개에 이중화되어 흩어집니다.

| | 로컬 | 클라우드 |
|---|---|---|
| 프론트 | `vite dev` (:5173) | Nginx **컨테이너** (WEB EC2 ×2) |
| 백엔드 | `bootRun` (:8080) | Spring Boot **컨테이너** (WAS EC2 ×2) |
| RDB | H2 인메모리 | RDS Oracle SE2 (Multi-AZ) |
| NoSQL | 로컬 MongoDB | DocumentDB (인스턴스 2대) |
| 캐시 | 로컬 Redis | ElastiCache Redis (Multi-AZ) |
| 파일 | 로컬 디스크 | WAS 호스트 볼륨 (**아직 S3 아님**, 5장 참고) |
| 진입점 | 브라우저 → localhost | 사용자 → ALB(HTTPS) → Nginx → NLB → WAS |
| 배포 | — | git push → Actions → Docker Hub → Watchtower |

가장 중요한 변화 네 가지입니다.

1. **WAS가 2대**입니다. 요청이 어느 쪽으로 갈지 알 수 없으므로, 인스턴스의 로컬 상태에
   의존하는 코드는 전부 깨집니다. (세션은 Redis로 공유되지만 업로드 파일은 아직 아닙니다)
2. **DB 3종이 전부 TLS**입니다. 로컬은 평문이었습니다.
3. **H2가 사라집니다.** 실제 Oracle로 바뀌므로 SQL 방언 차이가 드러날 수 있습니다.
4. **배포 단위가 컨테이너 이미지**입니다. jar 나 `dist/` 를 직접 올리지 않습니다.

### 배포 파이프라인

```
개발자 push (main)
   │
   ├─ GitHub Actions ─ 테스트 ─ 빌드 ─ 이미지 push
   │                                      │
   │                       Docker Hub (private)
   │                       :latest       ← Watchtower 감시 대상
   │                       :sha-abc1234  ← 롤백용
   │                                      │
   └──────────────────────────────────────▼
                        EC2 (프라이빗 서브넷)
                        ├ watchtower ── 5분마다 :latest digest 확인
                        │                 변경 감지 → pull → 컨테이너 교체
                        └ 앱 컨테이너
```

**GitHub Actions 에는 AWS 자격증명이 없습니다.** Docker Hub 에 push 만 하고,
EC2 가 자기 IAM 역할로 자격증명을 꺼내 스스로 당겨옵니다.

> ⚠️ **Watchtower 는 "실행 중인 컨테이너가 쓰는 태그" 를 다시 pull 해서 digest 가
> 바뀌었는지만 봅니다.** 새 태그를 찾아다니지 않습니다. 그래서 `:latest` 라는 고정
> 태그를 매번 덮어써야 하고, EC2 의 컨테이너도 반드시 `:latest` 로 떠 있어야 합니다.
> `:sha-...` 로 띄우면 그 digest 는 절대 안 바뀌므로 영원히 갱신되지 않습니다.

---

## 2. 백엔드: 무엇이 어떻게 바뀌는가

기본 `application.yml`은 **로컬 전용(H2 / localhost)으로 그대로 둡니다.** 로컬 개발과
CI 테스트가 외부 DB 없이 돌아야 하기 때문입니다(러너와 개발자 PC 는 프라이빗 서브넷의
RDS 에 애초에 접속할 수 없습니다). 운영은 **prod 프로파일**이 이 값을 덮어씁니다.

운영 설정은 두 군데로 나뉩니다. 기준은 **"이미지에 구워도 되는 값인가"** 하나입니다.

| | 어디에 있나 | 무엇이 들어가나 |
|---|---|---|
| **prod yml** | backend 레포 GitHub Secrets 의 `APPLICATION_PROD_YML`(base64). CD 가 빌드 직전에 `src/main/resources/application-prod.yml` 로 복원해 jar 에 넣음 | RDS 엔드포인트·계정명, Oracle 드라이버/다이얼렉트, `ddl-auto: validate`, H2 콘솔 off, Redis 엔드포인트+TLS, S3 버킷, `forward-headers-strategy` |
| **app.env** | WAS 부팅 시 SSM 에서 받아 `/opt/app/app.env` 생성 → 컨테이너에 `--env-file` | `SPRING_PROFILES_ACTIVE=prod`, `SERVER_PORT`, `SPRING_DATASOURCE_PASSWORD`, `SPRING_DATA_MONGODB_URI`, `JWT_SECRET`, `AWS_REGION` |

비밀번호를 이미지에 굽지 않는 이유는 **롤백**입니다. CD 는 `sha-` 태그를 남겨 두고 그
이미지로 되돌리므로, 비밀번호가 이미지에 있으면 나중에 교체해도 옛 태그 안에 예전
비밀번호가 영구히 남습니다. 그러면 Docker Hub 이미지를 pull 할 수 있는 사람이 곧 DB 에
붙을 수 있는 사람이 됩니다. 반대로 엔드포인트·계정명은 프라이빗 서브넷(`rds_sg` 가
`was_sg` 만 허용)이라 새어도 접속이 되지 않습니다.

> ⚠️ **환경변수가 yml 보다 우선순위가 높습니다.** `app.env` 에 `SPRING_DATASOURCE_URL`
> 같은 줄을 다시 넣으면 시크릿의 yml 이 아무 에러 없이 무시됩니다. 비밀이 아닌 값을
> 바꿀 일이 생기면 backend 레포의 시크릿을 고치세요.

> ⚠️ `SPRING_PROFILES_ACTIVE=prod` 가 빠지면 앱이 기본 프로파일로 떠서 **H2 인메모리로
> 동작**합니다. 기동은 "성공" 하므로 에러가 나지 않고, 재배포 때 데이터가 통째로
> 사라지는 형태로만 뒤늦게 드러납니다.

> ⚠️ `app.env` 는 systemd `EnvironmentFile` 이 아니라 docker `--env-file` 로 읽힙니다.
> **Docker 는 따옴표를 벗기지 않고 값의 일부로 취급합니다.** 값에 따옴표를 넣지 마세요.
> 변수 확장도 하지 않으므로 MongoDB URI 의 `&` 나 `$` 는 안전합니다.

### 스키마 최초 생성

prod yml 은 `ddl-auto: validate` 라 테이블이 없으면 기동에 실패합니다. 빈 DB 에 처음
배포할 때만 `app.env` 의 `#SPRING_JPA_HIBERNATE_DDL_AUTO=update` 주석을 풀어 한 번
띄우고, 테이블 생성을 확인한 뒤 다시 주석 처리해 재기동하세요. 켜 둔 채로 두면 운영
스키마에 자동 DDL 이 계속 나갑니다.

### 왜 이런 값들이 필요한가

**`retryWrites=false` (DocumentDB)**
DocumentDB는 재시도 가능 쓰기를 지원하지 않는데, MongoDB Java 드라이버 4.2+는 이걸
기본으로 켭니다. 빼면 쓰기마다 실패합니다. 가장 흔한 함정입니다.

**`replicaSet=rs0` (DocumentDB)**
DocumentDB의 레플리카셋 이름은 항상 `rs0` 고정입니다. 이걸 붙이면 드라이버가 토폴로지를
발견해 쓰기는 Writer로, 읽기는 `readPreference`대로 보냅니다. 페일오버도 자동 추종합니다.

**`spring.data.redis.ssl.enabled: true`** (prod yml)
ElastiCache에 전송 암호화가 켜져 있어 TLS로만 접속됩니다. 이 값이 없으면
포트가 열려 있어도 접속에 실패합니다. **SG 문제로 착각하기 쉬운 장애**입니다.

**`server.forward-headers-strategy: framework`** (prod yml)
ALB → Nginx → NLB → WAS로 프록시가 2단입니다. Spring Boot는 기본적으로
`X-Forwarded-Proto`를 무시하므로(`NONE`), 이 값이 없으면 리다이렉트가 `http://`로
생성되어 무한 리다이렉트가 발생합니다.

**DocumentDB 인증서 — 이제 이미지가 들고 있습니다**
DocumentDB는 Amazon RDS CA(프라이빗 CA)가 발급한 인증서를 씁니다. JDK 기본
`cacerts`에 없어서 그대로는 연결이 안 됩니다. 예전에는 부팅 스크립트가 만들었지만,
**지금은 `backend/Dockerfile` 이 이미지 빌드 시점에 만듭니다.** 컨테이너 안의 JDK를
기준으로 만들어야 하기 때문이고, 덕분에 로컬에서도 운영과 같은 트러스트스토어로
재현됩니다. `JAVA_TOOL_OPTIONS` 도 이미지 `ENV` 로 옮겨갔습니다.

> 반드시 **기본 `cacerts` 를 복사한 뒤** RDS CA 를 추가해야 합니다. 새로 만들면
> 퍼블릭 CA 가 사라져 **Redis TLS 가 깨집니다.**

### 비밀 값 관리

비밀 값은 전부 SSM Parameter Store(SecureString)에 있고, EC2가 부팅 시 IAM 역할로
복호화해 가져옵니다. `user_data`에 넣지 않은 이유는 인스턴스 메타데이터로
평문 노출되어 인스턴스 내 아무 프로세스나 읽을 수 있기 때문입니다.

| 파라미터 | 용도 | 값의 출처 |
|---|---|---|
| `/kidhackapp/rds/password` | Oracle 마스터 | `TF_VAR_db_password` |
| `/kidhackapp/docdb/password` | DocumentDB 마스터 | `TF_VAR_docdb_password` |
| `/kidhackapp/app/jwt-secret` | JWT 서명 키 | Terraform 자동 생성 (64자 난수) |
| `/kidhackapp/dockerhub/token` | WEB 이미지 pull | `TF_VAR_dockerhub_token` |
| `/kidhackapp/dockerhub/was-token` | WAS 이미지 pull | `TF_VAR_was_dockerhub_token` |
| `/kidhackapp/app/firebase-key` | FCM 서비스 계정 | `TF_VAR_firebase_credentials_json` (선택) |

Docker Hub 토큰이 두 개인 이유는 **WEB 과 WAS 의 이미지 계정이 다르기** 때문입니다
(`bulletbear` / `jotriever`). `docker login` 은 레지스트리당 한 계정만 유지되지만
WEB 과 WAS 는 서로 다른 EC2 라 충돌하지 않습니다.

값이 필요할 때는 이렇게 꺼냅니다.

```bash
aws ssm get-parameter --name /kidhackapp/rds/password --with-decryption \
  --query Parameter.Value --output text
```

---

## 3. 프론트엔드: 무엇이 어떻게 바뀌는가

| | 로컬 | 클라우드 |
|---|---|---|
| 실행 | `npm run dev` (:5173) | Nginx 컨테이너가 이미지 안의 `dist/` 서빙 |
| `VITE_USE_MOCK` | `true` (목 데이터) | `false` — **이미지 빌드 시 `--build-arg` 로 주입** |
| `VITE_API_BASE_URL` | (목 사용 시 무관) | **`/api`** — 동일 |

### ⚠️ Vite 환경변수는 빌드 시점에 박힙니다

`VITE_*` 값은 빌드할 때 코드에 치환되어 들어갑니다. **런타임에 바꿀 수 없습니다.**
컨테이너에 `-e VITE_USE_MOCK=false` 를 줘 봐야 아무 효과가 없습니다.
`web/.github/workflows/cd.yml` 의 `build-args` 가 유일한 주입 지점입니다.

### 🚨 목 데이터가 켜진 채 배포되는 사고

`src/shared/api/client.ts` 는 이렇게 판정합니다.

```ts
export const USE_MOCK = import.meta.env.VITE_USE_MOCK !== 'false';
```

**값이 없거나 오타가 나면 목 데이터가 켜집니다.** 화면은 멀쩡히 뜨고 숫자도 그럴듯해서
아무도 눈치채지 못합니다. 반드시 문자열 `false` 여야 합니다.

### `VITE_API_BASE_URL`을 `/api`로 두는 이유

별도 API 도메인을 쓰면 **CORS 설정이 추가로 필요합니다.** 같은 도메인에서 Nginx가
`/api/`를 내부 NLB로 프록시하므로 상대 경로를 쓰면 CORS가 아예 발생하지 않습니다.
`client.ts` 의 기본값도 `/api` 라 일치합니다.

백엔드 컨트롤러가 이미 `@RequestMapping("/api/...")`로 매핑되어 있고 `context-path`가
없으므로, Nginx는 경로를 **변형 없이 그대로** 전달합니다.

### NLB 주소는 런타임에 채웁니다

내부 NLB 주소는 Terraform 이 apply 할 때 정해지는데 이미지는 GitHub Actions 가
빌드하므로 그 값을 알 수 없습니다. 그래서 이미지에는 nginx 설정 **템플릿**
(`web/nginx/default.conf.template`)만 넣고, 컨테이너가 뜰 때 `envsubst` 로 채웁니다.
nginx 공식 이미지가 `/etc/nginx/templates/*.template` 를 자동 처리합니다.

> ⚠️ resolver 주소로 **링크로컬(`169.254.169.253`)을 쓰면 안 됩니다.** 호스트에서는
> 되지만 컨테이너의 브리지 네트워크에서는 라우팅되지 않습니다. VPC DNS 는
> "VPC 대역 + 2"(`192.168.0.2`)에서도 같은 서비스를 제공하고 이쪽은 일반 라우팅됩니다.
> Terraform 이 `cidrhost` 로 계산해 `DNS_RESOLVER` 로 넘깁니다.

### 권장: 로컬 dev에도 프록시 추가

현재 `vite.config.ts`에는 프록시가 없어서, 로컬에서 `VITE_USE_MOCK=false`로 실제
백엔드를 붙이면 CORS에 막힙니다. 아래를 추가하면 **로컬과 클라우드의 코드 경로가
같아집니다.**

```ts
// vite.config.ts
server: {
  port: 5173,
  open: false,
  proxy: {
    '/api': { target: 'http://localhost:8080', changeOrigin: true },
  },
},
```

---

## 4. 모바일

**모바일 앱은 서버에 배포되지 않습니다.** 인프라와 무관한 클라이언트입니다.
필요한 설정은 API 주소 하나뿐입니다.

```
https://kidhackapp.com
```

웹과 달리 **절대 URL**을 써야 합니다(같은 오리진이 아니므로). 네이티브 앱이라 CORS는
발생하지 않습니다.

- **Android 9(API 28) 이상은 평문 HTTP를 기본 차단**합니다. HTTPS 구성이 되어 있어야
  API 호출이 됩니다.
- ACM 인증서는 Amazon(퍼블릭 CA) 발급이라 Android·iOS 기본 신뢰 저장소에 이미
  있습니다. 앱에 인증서를 심는 작업이 필요 없습니다.

---

## 5. ⚠️ 아직 남은 코드 이슈

### 5-1. 파일 업로드 (임시 방편으로 막아둔 상태)

```yaml
file:
  upload-dir: uploads/community
  inquiry-upload-dir: uploads/inquiry
```

**컨테이너 파일시스템은 휘발성입니다.** 그대로 두면 Watchtower 가 배포할 때마다
업로드 파일이 전부 사라집니다. 예전(EC2 디스크 직접 사용)보다 나빠지는 부분입니다.

그래서 WAS 부팅 스크립트가 호스트 볼륨을 마운트합니다.

```
-v /opt/app/uploads:/app/uploads
```

이미지의 `WORKDIR` 이 `/app` 이라 상대경로 `uploads/community` 가
`/app/uploads/community` 로 해석되어 두 서비스가 한 마운트에 덮입니다.
컨테이너가 uid 10001 로 돌기 때문에 호스트 디렉터리도 `chown 10001:0` 되어 있습니다.

> **이건 배포로 파일이 사라지는 것만 막습니다.** WAS 가 2대라 WAS1 에 올린 파일을
> WAS2 가 서빙하지 못하는 문제는 그대로입니다. 정공법은 S3 전환이며
> 버킷·IAM(`s3:PutObject`/`GetObject`)·CORS 는 이미 준비되어 있습니다.

### 5-2. `ddl-auto: update` 확인

로컬 H2는 `MODE=Oracle`이었을 뿐 실제 Oracle이 아닙니다. Hibernate가 Oracle에
스키마를 자동 생성할 때 예약어·타입 매핑 차이로 실패할 수 있습니다.
**첫 배포 후 반드시 로그를 확인하세요.**

운영 전환 시에는 `ddl-auto: validate`로 바꾸고 스키마를 별도 관리하는 것이 안전합니다.

### 5-3. Actuator — 완료됨

`spring-boot-starter-actuator` 가 추가되었고 NLB 헬스체크가
`/actuator/health/readiness` 를 봅니다.

> **`/actuator/health` 가 아니라 readiness 인 이유:** 기본 `/actuator/health` 는
> DB·Mongo·Redis 상태를 **전부 집계**합니다. DocumentDB 가 페일오버로 몇 초 흔들리면
> WAS 2대가 **동시에** unhealthy 가 되어 살아 있는 타깃이 0 이 됩니다.
> 예전 TCP 체크보다 오히려 나빠집니다. readiness 그룹은 "앱이 요청을 받을 준비가
> 됐는가" 만 봅니다.

> 🚨 `management.endpoints.web.exposure.include: "*"` 를 추가하지 마세요.
> `SecurityConfig` 가 `anyRequest().permitAll()` 이라 `/actuator/env` 로
> **DB 비밀번호와 JWT 시크릿이 그대로 노출**됩니다.

---

## 6. 배포 절차

### 6-1. 사전 준비 (최초 1회)

**① Docker Hub 토큰 발급** — [app.docker.com](https://app.docker.com) → 아바타 →
Account settings → Personal access tokens → Generate new token.

계정별로 용도가 둘입니다.

| 용도 | 권한 | 들어가는 곳 |
|---|---|---|
| Actions 가 이미지 push | Read & Write | GitHub Secrets `DOCKERHUB_TOKEN` |
| EC2 가 이미지 pull | Read only | `TF_VAR_(was_)dockerhub_token` |

> ⚠️ **무료 플랜은 계정당 토큰이 1개**입니다(Pro 5개, Team 무제한). 또 스코프를 좁히는
> 기능 자체가 Pro 이상 전용이라 무료 계정의 토큰은 read/write/delete 를 다 가집니다.
> 권한을 나누려면 pull 전용 계정을 따로 만들어 저장소에 read-only collaborator 로
> 추가하는 방법이 비용 없이 가능합니다.

**② GitHub Secrets 등록** — backend·web 두 레포에 각각.

```bash
gh secret set DOCKERHUB_USERNAME --repo HACK-rookies32/backend
gh secret set DOCKERHUB_TOKEN    --repo HACK-rookies32/backend
gh secret set DOCKERHUB_USERNAME --repo HACK-rookies32/web
gh secret set DOCKERHUB_TOKEN    --repo HACK-rookies32/web
```

**③ Terraform 변수 주입** — `default` 가 없는 값들이라 안 주면 `plan` 이 멈춥니다.

```bash
export TF_VAR_db_password='...'                     # 8~30자, / " @ & ' 공백 불가
export TF_VAR_docdb_password='...'                  # 8~100자, / " @ 불가
export TF_VAR_dockerhub_token='dckr_pat_...'        # bulletbear (WEB), Read-only
export TF_VAR_was_dockerhub_token='dckr_pat_...'    # jotriever  (WAS), Read-only

# 선택 — 안 주면 푸시 알림만 비활성 상태로 정상 기동
export TF_VAR_firebase_credentials_json="$(cat firebase-service-account.json)"
```

PowerShell 이면 `$env:TF_VAR_db_password = '...'` 형식입니다.

> ⚠️ Oracle 비밀번호는 **8~30자**입니다. 다른 엔진(128자)보다 훨씬 짧고,
> `&` 와 작은따옴표까지 추가로 막습니다. 영숫자 + `! # $ % ^ * ( ) - _ = +` 범위로
> 20자 내외면 두 DB 모두 안전합니다.

### 6-2. 인프라 (최초 1회 또는 destroy 후)

```bash
cd "3. 개발/infra"
terraform init
terraform apply        # 30~40분 (RDS Oracle Multi-AZ가 대부분)
```

호스팅 존은 Terraform 밖에서 관리되므로(`data` 참조) destroy해도 남습니다.
`kidhackapp.com`은 Route 53에서 등록한 도메인이라 네임서버가 자동 연결되어 있습니다.
**등록기관에서 손으로 할 설정이 없습니다.**

### 6-3. 첫 배포

`main` 에 push 하면 끝입니다.

```bash
# backend / web 각 레포에서
git push origin main
```

Actions 가 테스트 → 빌드 → Docker Hub push 를 수행합니다.
**인프라를 먼저 올려두고 나중에 파이프라인을 돌려도 됩니다.** 이미지가 아직 없으면
컨테이너가 30초마다 재시도하고 있으므로, 이미지가 올라오는 순간 알아서 붙습니다.

### 6-4. 이후 배포

**`main` 에 머지하는 것이 곧 배포입니다.** 그 외에 할 일이 없습니다.
Watchtower 폴링 주기(기본 300초) 안에 컨테이너가 교체됩니다.

시연 때 5분이 길면 `var.watchtower_poll_interval` 을 60 으로 낮추고 apply 하세요.
다만 Docker Hub 는 매니페스트 조회를 pull 로 계산하고 인스턴스 4대가 각자 폴링하므로,
**무료 계정 한도에 걸릴 수 있습니다.**

### 6-5. 롤백

Watchtower 에는 롤백 기능이 없습니다. GitHub Actions 로 되돌립니다.

1. 해당 레포 → Actions → **CD** → Run workflow
2. `되돌릴 태그` 에 `sha-a1b2c3d` 입력 후 실행

`docker buildx imagetools create` 로 `:latest` 가 그 이미지를 다시 가리키게만 합니다.
**재빌드하지 않으므로 "그때 그 바이너리" 가 그대로 돌아옵니다.**
다음 폴링에서 Watchtower 가 적용합니다.

---

## 7. 검증

```bash
# 출력값
terraform output

# HTTPS / 리다이렉트
curl -I https://kidhackapp.com          # 200
curl -I http://kidhackapp.com           # 301 → https

# 타깃 헬스
aws elbv2 describe-target-health --target-group-arn \
  $(aws elbv2 describe-target-groups --names kidhackapp-was-tg \
    --query "TargetGroups[0].TargetGroupArn" --output text)
```

인스턴스 안에서는 SSM Session Manager 로 접속 후:

```bash
docker ps                          # 앱 컨테이너 + watchtower 두 개가 Up
docker logs kidhack --tail 100     # 백엔드 (WAS)
docker logs careguard-web --tail 50   # 프론트 (WEB)
docker logs watchtower --tail 50   # 폴링 로그. 401 이 보이면 토큰 문제
curl -s localhost:8080/actuator/health/readiness   # WAS
curl -sI localhost/healthz                          # WEB
```

**배포가 실제로 반영됐는지**는 태그 이름이 아니라 digest 로 확인합니다.
태그가 그대로여도 digest 가 안 바뀌었다면 Watchtower 는 아무것도 하지 않습니다.

```bash
docker inspect --format '{{index .RepoDigests 0}}' kidhack
```

| 상태 | 의미 |
|---|---|
| 컨테이너가 없고 `systemctl status` 가 재시도 중 | 이미지 미배포 또는 pull 실패 (정상적인 대기 상태일 수 있음) |
| WAS `unhealthy`, `/api` → 502 | 앱이 아직 기동 중이거나 기동 실패 → `docker logs kidhack` |
| 화면은 뜨는데 데이터가 전부 그럴듯한 가짜 | **목 데이터로 빌드된 이미지** (3장 참고) |
| 전부 `healthy` | 정상 |

---

## 8. 트러블슈팅

부팅 로그가 1차 단서입니다. SSM Session Manager로 접속 후:

```bash
sudo cat /var/log/user-data.log        # 부팅 스크립트 (docker login 실패 등)
sudo systemctl status kidhack          # WAS 컨테이너 기동 유닛
sudo systemctl status careguard-web    # WEB 컨테이너 기동 유닛
docker logs kidhack
docker logs watchtower
```

| 증상 | 원인 |
|---|---|
| EC2 는 running 인데 컨테이너가 없음 | `docker login` 실패 → `user-data.log` 확인. IAM 에 SSM 파라미터 권한 누락이 흔함 |
| `docker logs watchtower` 에 401 | Docker Hub 토큰 만료·오류. **조용히 실패**하므로 "배포가 안 먹는다" 로만 보임 |
| CI 는 성공했는데 배포가 안 됨 | 이미지 이름 불일치. 워크플로의 `IMAGE` 와 `var.dockerhub_image`/`var.was_image` 대조 |
| 배포해도 그대로 | 컨테이너가 `:latest` 가 아닌 태그로 떠 있음 → Watchtower 는 갱신하지 않음 |
| 업로드 파일이 배포마다 사라짐 | 볼륨 마운트 누락 (5-1) |
| Redis 연결 실패 (포트는 열림) | prod yml 의 `spring.data.redis.ssl.enabled` 누락 |
| DB 는 비었는데 앱은 멀쩡히 뜸 | `SPRING_PROFILES_ACTIVE=prod` 누락 → H2 인메모리로 동작 중 |
| 기동 시 스키마 검증 실패 | 빈 DB 첫 배포 — `SPRING_JPA_HIBERNATE_DDL_AUTO=update` 를 한 번만 켤 것 |
| `PKIX path building failed` | DocumentDB 트러스트스토어 구성 실패 → 이미지 빌드 단계 확인 |
| DocumentDB 쓰기 실패 | `retryWrites=false` 누락 |
| `ORA-12514` | Oracle SID 불일치 (`var.oracle_db_name`) |
| 무한 리다이렉트 | `SERVER_FORWARD_HEADERS_STRATEGY` 누락 |
| 새로고침 시 404 | Nginx `try_files` 폴백 문제 (SPA 라우팅) |
| `/api` 만 502, 화면은 정상 | WAS 가 안 떠 있거나 nginx 의 NLB 이름 해석 실패 → `DNS_RESOLVER` 확인 |
| 배포 중 잠깐 전체 502 | WAS 2대의 Watchtower 가 동시에 교체 (9장 참고) |

---

## 9. 이 배포 구조의 한계

발표와 시연에는 충분하지만, 알고 쓰셔야 하는 것들입니다.

| 항목 | 실제로 벌어지는 일 | 완화 |
|---|---|---|
| **무중단이 아님** | Watchtower 는 stop → remove → run. 교체 동안 그 인스턴스는 죽습니다 (Spring Boot 기동 20~40초) | 헬스체크로 죽은 타깃을 빨리 빼고, 아래 stagger 로 2대가 겹치지 않게 |
| **동시 교체 위험** | 2대가 같은 시각에 감지하면 살아 있는 타깃이 0 | 부팅 스크립트가 호스트명 해시로 0~119초 시작 지연(stagger)을 줍니다 |
| **배포 지연** | push 후 최대 폴링 주기(300초)만큼 대기 | 시연 때 60초로 낮춤 (rate limit 주의) |
| **롤백 자동화 없음** | 새 이미지가 기동에 실패해도 되돌리지 않고 계속 실패 상태로 둠 | 6-5 수동 롤백 |
| **NAT 비용** | 이미지 pull 이 전부 NAT 를 경유 (예전 S3 게이트웨이 엔드포인트와 달리) | 레이어 캐시로 앱 레이어만 받으므로 실사용은 크지 않음 |

`WATCHTOWER_ROLLING_RESTART` 는 **한 호스트 안의 여러 컨테이너**를 하나씩 재시작하는
옵션입니다. 호스트가 다른 2대에는 아무 효과가 없습니다.

---

## 10. 비용과 정리

**시간당 약 $1 (하루 $20~25)** 수준입니다. 비중이 큰 순서:

1. RDS Oracle SE2 Multi-AZ (라이선스 포함) — 압도적 1위
2. NAT Gateway 2대
3. DocumentDB 2대
4. EC2 4대 + ALB + NLB

**작업하지 않을 때는 destroy하세요.**

```bash
terraform destroy
```

- `keep_final_snapshot = false`(기본)이면 스냅샷 없이 빠르게 정리됩니다.
  최종 제출 시점에만 `true`로 바꾸세요.
- 호스팅 존은 남습니다 → 다시 `apply`하면 도메인이 그대로 살아납니다.
- **이미지는 Docker Hub 에 있으므로 destroy 와 무관합니다.** 다시 apply 하면
  EC2 가 알아서 pull 해 옵니다. 재빌드도, 재업로드도 필요 없습니다.
- S3 버킷은 `force_destroy = true` 라 내용까지 지워집니다. 지금은 사용자 업로드
  파일이 들어가기 전이라 문제없지만, S3 전환(5-1) 이후에는 버킷을 분리해야 합니다.

프로젝트를 완전히 종료할 때는 콘솔에서 Route 53 호스팅 존(월 $0.50)을 직접 삭제하세요.

---

## 11. 아직 남은 과제

| 항목 | 비고 |
|---|---|
| 파일 업로드 S3 전환 | 5-1. 볼륨 마운트로 급한 불만 껐고 WAS 2대 간 불일치는 그대로 |
| Auto Scaling Group | 비용 제약으로 의도적 미구현. EC2 장애 시 자가 복구 없음 |
| `tfstate` 원격 백엔드 | 현재 로컬 저장. 비밀 값이 평문으로 포함되고 팀원 간 공유가 안 됨 |
| WEB↔WAS 내부 구간 암호화 | VPC 내부 평문 (외부 구간은 HTTPS 완료) |
| `main` 브랜치 보호 | main push 가 곧 운영 배포인데 아직 누구나 직접 올릴 수 있음 |
| 배포 알림 | Watchtower 의 shoutrrr 연동으로 Slack/Discord 알림 가능 |